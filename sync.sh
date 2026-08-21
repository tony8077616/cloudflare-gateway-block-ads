#!/bin/bash
# ============================================================
# 雲端擋廣告架構 - 核心同步腳本（Shell 版本）
#
# 流程：
#   1. 抓取 sources.conf 定義的所有來源，解析、合併去重
#   2. 從 D1 讀取白名單，扣除
#   3. 從 D1 讀取分類快取，未快取/過期的批次查 Cloudflare Intel API
#   4. 扣掉「已被 Cloudflare 原生 Ads 分類涵蓋」的網域
#   5. 加上 D1 自訂封鎖清單（強制納入）
#   6. 切成 1000 筆一組，上傳到 Cloudflare Gateway Lists
#   7. 更新 Policy、寫入同步紀錄到 D1
#
# 設計原則：單一來源/單一批次操作失敗不中斷整個流程（best effort）。
# ============================================================

set -uo pipefail
# 注意：刻意不用 -e，因為很多地方要靠指令回傳值自己判斷、印警告後繼續，
# 用 -e 反而會讓 best-effort 的設計失效。

WORKDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCES_FILE="$WORKDIR/sources.conf"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

: "${CF_ACCOUNT_ID:?請設定 CF_ACCOUNT_ID}"
: "${CF_API_TOKEN:?請設定 CF_API_TOKEN}"
: "${D1_DATABASE_ID:?請設定 D1_DATABASE_ID}"

CF_API="https://api.cloudflare.com/client/v4"
LIST_PREFIX="Block ads"
LIST_CHUNK_SIZE=1000
POLICY_NAME="Block ads"
CACHE_TTL_DAYS=30
BULK_BATCH_SIZE=500

log() { echo "[$(date '+%H:%M:%S')] $*" >&2; }
warn() { echo "[$(date '+%H:%M:%S')] ⚠ $*" >&2; }

cf_curl() {
  # $1 = method, $2 = path (含 query string), $3 = body（可省略）
  local method="$1" path="$2" body="${3:-}"
  if [[ -n "$body" ]]; then
    curl -sS -X "$method" "$CF_API$path" \
      -H "Authorization: Bearer $CF_API_TOKEN" \
      -H "Content-Type: application/json" \
      --data "$body"
  else
    curl -sS -X "$method" "$CF_API$path" \
      -H "Authorization: Bearer $CF_API_TOKEN"
  fi
}

d1_query() {
  # $1 = sql, $2 = params json array（可省略）
  local sql="$1" params="${2:-[]}"
  local body
  body=$(jq -n --arg sql "$sql" --argjson params "$params" '{sql: $sql, params: $params}')
  cf_curl POST "/accounts/$CF_ACCOUNT_ID/d1/database/$D1_DATABASE_ID/query" "$body"
}

# ── 1. 網域格式驗證 ──────────────────────────────────────
DOMAIN_REGEX='^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)+$'

# ── 2. 各格式解析函式（吃 stdin，吐出網域清單到 stdout）───

parse_domains() {
  grep -vE '^[[:space:]]*(#|!|$)' \
    | sed -E 's/^\*\.//' \
    | tr 'A-Z' 'a-z' \
    | grep -E "$DOMAIN_REGEX"
}

parse_adblock() {
  grep -E '^\|\|[a-zA-Z0-9.*_-]+\^' \
    | grep -v '^@@' \
    | grep -v '##\|#@#\|#?#' \
    | grep -v '\$domain=' \
    | sed -E 's/^\|\|([a-zA-Z0-9.*_-]+)\^.*/\1/' \
    | sed -E 's/^\*\.//' \
    | tr 'A-Z' 'a-z' \
    | grep -E "$DOMAIN_REGEX"
}

parse_hosts() {
  grep -E '^(0\.0\.0\.0|127\.0\.0\.1|::1|::)[[:space:]]+' \
    | awk '{print $2}' \
    | tr 'A-Z' 'a-z' \
    | grep -E "$DOMAIN_REGEX"
}

# ── 3. 抓取 + 合併所有來源 ────────────────────────────────

fetch_and_merge_sources() {
  local merged_file="$TMP_DIR/merged.txt"
  : > "$merged_file"

  while IFS='|' read -r name url format; do
    # 跳過空行與註解
    [[ -z "$name" || "$name" =~ ^[[:space:]]*# ]] && continue
    name="$(echo "$name" | xargs)"
    url="$(echo "$url" | xargs)"
    format="$(echo "$format" | xargs)"

    log "抓取來源：$name ($format) ← $url"
    local raw_file="$TMP_DIR/raw_$name.txt"
    if ! curl -sSfL --retry 3 --retry-all-errors --max-time 60 \
        -A "cloudflare-gateway-block-ads-sync/1.0" \
        "$url" -o "$raw_file"; then
      warn "[$name] 抓取失敗，略過此來源"
      continue
    fi

    local parsed_file="$TMP_DIR/parsed_$name.txt"
    case "$format" in
      domains) parse_domains < "$raw_file" > "$parsed_file" ;;
      adblock) parse_adblock < "$raw_file" > "$parsed_file" ;;
      hosts)   parse_hosts   < "$raw_file" > "$parsed_file" ;;
      *) warn "[$name] 未知格式 '$format'，略過"; continue ;;
    esac

    local count
    count=$(wc -l < "$parsed_file" | xargs)
    log "[$name] 解析出 $count 筆網域"
    cat "$parsed_file" >> "$merged_file"
  done < "$SOURCES_FILE"

  sort -u "$merged_file"
}

# ── 4. D1：白名單 / 自訂封鎖清單 ──────────────────────────

load_whitelist() {
  local resp
  resp=$(d1_query "SELECT domain FROM custom_whitelist")
  if [[ "$(echo "$resp" | jq -r '.success')" != "true" ]]; then
    warn "讀取白名單失敗，本次視為空白名單（best effort，不中斷流程）"
    return
  fi
  echo "$resp" | jq -r '.result[0].results[]?.domain // empty'
}

load_custom_blocklist() {
  local resp
  resp=$(d1_query "SELECT domain FROM custom_blocklist")
  if [[ "$(echo "$resp" | jq -r '.success')" != "true" ]]; then
    warn "讀取自訂封鎖清單失敗，本次視為空清單（best effort，不中斷流程）"
    return
  fi
  echo "$resp" | jq -r '.result[0].results[]?.domain // empty'
}

# ── 5. D1：分類快取 ───────────────────────────────────────

load_category_cache() {
  # 輸出：每行「domain is_ads_category」，只取未過期的快取
  local cutoff
  cutoff=$(( $(date +%s) - CACHE_TTL_DAYS * 86400 ))
  local resp
  resp=$(d1_query "SELECT domain, is_ads_category FROM domain_category_cache WHERE checked_at >= ?" "[\"$cutoff\"]")
  if [[ "$(echo "$resp" | jq -r '.success')" != "true" ]]; then
    warn "讀取分類快取失敗，本次視為無快取，將重新查詢全部網域"
    return
  fi
  echo "$resp" | jq -r '.result[0].results[]? | "\(.domain) \(.is_ads_category)"'
}

save_category_cache_batch() {
  # $1 = 檔案，每行「domain is_ads categories_json」
  local batch_file="$1"
  [[ -s "$batch_file" ]] || return 0

  local now batch_json
  now=$(date +%s)
  batch_json=$(awk -v now="$now" '
    { domain=$1; is_ads=$2; $1=""; $2=""; cats=$0; sub(/^  */, "", cats);
      printf "%s\t%s\t%s\t%s\n", domain, is_ads, cats, now }
  ' "$batch_file" | jq -R -s -c --arg now "$now" '
    split("\n") | map(select(length > 0) | split("\t")) | map({
      sql: "INSERT INTO domain_category_cache (domain, is_ads_category, categories, checked_at) VALUES (?, ?, ?, ?) ON CONFLICT(domain) DO UPDATE SET is_ads_category=excluded.is_ads_category, categories=excluded.categories, checked_at=excluded.checked_at",
      params: [.[0], .[1], .[2], $now]
    })
  ')

  local body resp
  body=$(jq -n --argjson batch "$batch_json" '{batch: $batch}')
  resp=$(curl -sS -X POST "$CF_API/accounts/$CF_ACCOUNT_ID/d1/database/$D1_DATABASE_ID/query" \
    -H "Authorization: Bearer $CF_API_TOKEN" -H "Content-Type: application/json" \
    --data "$body")
  if [[ "$(echo "$resp" | jq -r '.success')" != "true" ]]; then
    warn "寫入分類快取批次失敗（不影響本次結果，只影響下次快取命中率）"
  fi
}

# ── 6. Cloudflare 原生分類批次查詢 ────────────────────────

check_native_categories() {
  # $1 = 待查詢網域清單檔案
  # 輸出：每行「domain is_ads」，同時把結果寫回 D1 快取
  local to_check_file="$1"
  local total
  total=$(wc -l < "$to_check_file" | xargs)
  [[ "$total" -eq 0 ]] && return 0

  local out_file="$TMP_DIR/native_check_results.txt"
  local cache_batch_file="$TMP_DIR/cache_batch.txt"
  : > "$out_file"
  : > "$cache_batch_file"

  local i=0
  while [[ $i -lt $total ]]; do
    local batch_file="$TMP_DIR/batch_$i.txt"
    sed -n "$((i+1)),$((i+BULK_BATCH_SIZE))p" "$to_check_file" > "$batch_file"

    local query=""
    while IFS= read -r d; do
      query="${query}&domain=$d"
    done < "$batch_file"
    query="${query#&}"

    local resp
    resp=$(curl -sS --max-time 30 "$CF_API/accounts/$CF_ACCOUNT_ID/intel/domain/bulk?$query" \
      -H "Authorization: Bearer $CF_API_TOKEN")

    if [[ "$(echo "$resp" | jq -r '.success // false')" != "true" ]]; then
      warn "第 $i~$((i+BULK_BATCH_SIZE)) 批分類查詢失敗，這批網域本次視為『未被原生分類涵蓋』（保守處理，寧可多上傳也不要漏擋）"
      awk '{print $1, 0}' "$batch_file" >> "$out_file"
    else
      echo "$resp" | jq -r '.result[]? |
        [.domain, (if ([.content_categories[]?.name] | any(. == "Advertisements" or . == "Trackers/Analytics")) then 1 else 0 end),
         ([.content_categories[]?.name] | tostring)] | @tsv' \
        | while IFS=$'\t' read -r domain is_ads cats; do
            echo "$domain $is_ads" >> "$out_file"
            echo -e "$domain\t$is_ads\t$cats" >> "$cache_batch_file"
          done
    fi

    log "分類查詢進度：$(( i + BULK_BATCH_SIZE > total ? total : i + BULK_BATCH_SIZE ))/$total"
    i=$((i + BULK_BATCH_SIZE))
    sleep 0.2
  done

  save_category_cache_batch "$cache_batch_file"
  cat "$out_file"
}

# ── 7. Cloudflare Gateway 清單上傳 ────────────────────────

get_existing_lists() {
  cf_curl GET "/accounts/$CF_ACCOUNT_ID/gateway/lists" \
    | jq -r --arg prefix "$LIST_PREFIX" '.result[] | select(.name | startswith($prefix)) | "\(.id) \(.name)"'
}

upload_lists() {
  # $1 = 最終網域清單檔案（已排序去重）
  local final_file="$1"
  local total
  total=$(wc -l < "$final_file" | xargs)

  # 讀取現有清單，用編號對應
  declare -A existing_by_index
  while read -r id name; do
    local idx
    idx=$(echo "$name" | grep -oE '[0-9]+$' | sed 's/^0*//')
    [[ -n "$idx" ]] && existing_by_index[$idx]="$id"
  done < <(get_existing_lists)

  local list_ids_file="$TMP_DIR/list_ids.txt"
  : > "$list_ids_file"

  local chunk_num=1
  local start=1
  while [[ $start -le $total ]]; do
    local chunk_file="$TMP_DIR/chunk_$chunk_num.txt"
    sed -n "${start},$((start + LIST_CHUNK_SIZE - 1))p" "$final_file" > "$chunk_file"

    local name
    name=$(printf "%s - %03d" "$LIST_PREFIX" "$chunk_num")
    local items_json
    items_json=$(jq -R -s -c 'split("\n") | map(select(length > 0)) | map({value: .})' "$chunk_file")
    local body
    body=$(jq -n --arg name "$name" --argjson items "$items_json" '{name: $name, type: "DOMAIN", items: $items}')

    local resp list_id
    if [[ -n "${existing_by_index[$chunk_num]:-}" ]]; then
      list_id="${existing_by_index[$chunk_num]}"
      resp=$(cf_curl PUT "/accounts/$CF_ACCOUNT_ID/gateway/lists/$list_id" "$body")
    else
      resp=$(cf_curl POST "/accounts/$CF_ACCOUNT_ID/gateway/lists" "$body")
      list_id=$(echo "$resp" | jq -r '.result.id')
    fi

    if [[ "$(echo "$resp" | jq -r '.success')" != "true" ]]; then
      echo "❌ 清單 $name 上傳失敗：$(echo "$resp" | jq -c '.errors')" >&2
      return 1
    fi

    echo "$list_id" >> "$list_ids_file"
    local chunk_count
    chunk_count=$(wc -l < "$chunk_file" | xargs)
    log "清單 $name 已上傳（$chunk_count 筆）"

    start=$((start + LIST_CHUNK_SIZE))
    chunk_num=$((chunk_num + 1))
  done

  # 刪除多餘的舊清單
  local last_chunk=$((chunk_num - 1))
  for idx in "${!existing_by_index[@]}"; do
    if [[ $idx -gt $last_chunk ]]; then
      local old_id="${existing_by_index[$idx]}"
      if cf_curl DELETE "/accounts/$CF_ACCOUNT_ID/gateway/lists/$old_id" > /dev/null; then
        log "刪除多餘舊清單：編號 $idx"
      else
        warn "刪除舊清單（編號 $idx）失敗（不影響本次上傳結果，之後手動清理即可）"
      fi
    fi
  done

  cat "$list_ids_file"
}

ensure_policy() {
  # $1 = list_ids 檔案
  local list_ids_file="$1"
  local traffic=""
  while read -r lid; do
    [[ -n "$traffic" ]] && traffic="$traffic or "
    traffic="${traffic}any(dns.domains[*] in \$$lid)"
  done < "$list_ids_file"

  local existing_id
  existing_id=$(cf_curl GET "/accounts/$CF_ACCOUNT_ID/gateway/rules" \
    | jq -r --arg name "$POLICY_NAME" '.result[] | select(.name == $name) | .id' | head -1)

  local body
  body=$(jq -n --arg name "$POLICY_NAME" --arg traffic "$traffic" \
    '{name: $name, action: "block", enabled: true, filters: ["dns"], traffic: $traffic}')

  local resp
  if [[ -n "$existing_id" ]]; then
    resp=$(cf_curl PUT "/accounts/$CF_ACCOUNT_ID/gateway/rules/$existing_id" "$body")
  else
    resp=$(cf_curl POST "/accounts/$CF_ACCOUNT_ID/gateway/rules" "$body")
  fi

  if [[ "$(echo "$resp" | jq -r '.success')" != "true" ]]; then
    echo "❌ Policy 更新失敗：$(echo "$resp" | jq -c '.errors')" >&2
    return 1
  fi
  local list_count
  list_count=$(wc -l < "$list_ids_file" | xargs)
  log "Policy 「$POLICY_NAME」已更新，引用 $list_count 個清單"
}

record_sync_history() {
  # $1 status, $2 notes, $3..$6 統計數字
  local status="$1" notes="$2" total_merged="$3" total_uploaded="$4" excluded_by_native="$5" whitelisted="$6"
  d1_query \
    "INSERT INTO sync_history (run_at, total_merged, total_uploaded, total_excluded_by_native_category, total_whitelisted, status, notes) VALUES (?, ?, ?, ?, ?, ?, ?)" \
    "[\"$(date +%s)\", \"$total_merged\", \"$total_uploaded\", \"$excluded_by_native\", \"$whitelisted\", \"$status\", $(jq -Rn --arg n "$notes" '$n')]" \
    > /dev/null || warn "寫入同步歷史紀錄失敗（不影響本次同步結果本身）"
}

# ── 主流程 ───────────────────────────────────────────────

main() {
  log "開始同步"

  local merged_file="$TMP_DIR/merged_domains.txt"
  fetch_and_merge_sources > "$merged_file"
  local total_merged
  total_merged=$(wc -l < "$merged_file" | xargs)
  log "合併去重後總計：$total_merged 筆網域"

  # 扣除白名單
  local whitelist_file="$TMP_DIR/whitelist.txt"
  load_whitelist > "$whitelist_file"
  local after_whitelist_file="$TMP_DIR/after_whitelist.txt"
  comm -23 "$merged_file" <(sort "$whitelist_file") > "$after_whitelist_file"
  local whitelisted_count
  whitelisted_count=$(( total_merged - $(wc -l < "$after_whitelist_file" | xargs) ))
  log "扣除白名單 $whitelisted_count 筆"

  # 原生分類比對
  local cache_file="$TMP_DIR/cache.txt"
  load_category_cache > "$cache_file"
  local cached_domains_file="$TMP_DIR/cached_domains.txt"
  awk '{print $1}' "$cache_file" > "$cached_domains_file"

  local to_check_file="$TMP_DIR/to_check.txt"
  comm -23 "$after_whitelist_file" <(sort "$cached_domains_file") > "$to_check_file"
  local to_check_count
  to_check_count=$(wc -l < "$to_check_file" | xargs)
  log "分類快取命中 $(wc -l < "$cache_file" | xargs) 筆，需要重新查詢 $to_check_count 筆"

  local fresh_results_file="$TMP_DIR/fresh_results.txt"
  if [[ $to_check_count -gt 0 ]]; then
    check_native_categories "$to_check_file" > "$fresh_results_file"
  else
    : > "$fresh_results_file"
  fi

  cat "$cache_file" "$fresh_results_file" > "$TMP_DIR/all_categories.txt"

  # 扣掉已被原生分類涵蓋的網域（is_ads == 1）
  local ads_domains_file="$TMP_DIR/native_ads_domains.txt"
  awk '$2 == 1 {print $1}' "$TMP_DIR/all_categories.txt" | sort -u > "$ads_domains_file"

  local after_native_file="$TMP_DIR/after_native.txt"
  comm -23 "$after_whitelist_file" "$ads_domains_file" > "$after_native_file"
  local excluded_by_native
  excluded_by_native=$(( $(wc -l < "$after_whitelist_file" | xargs) - $(wc -l < "$after_native_file" | xargs) ))
  log "扣除已被 Cloudflare 原生 Ads 分類涵蓋的 $excluded_by_native 筆"

  # 加上自訂封鎖清單
  local custom_block_file="$TMP_DIR/custom_block.txt"
  load_custom_blocklist > "$custom_block_file"
  local final_file="$TMP_DIR/final.txt"
  cat "$after_native_file" "$custom_block_file" | sort -u > "$final_file"
  local total_uploaded
  total_uploaded=$(wc -l < "$final_file" | xargs)
  log "最終總計：$total_uploaded 筆"

  if [[ $total_uploaded -eq 0 ]]; then
    echo "❌ 最終清單是空的，可能所有來源都抓取失敗，中止本次上傳避免清空 Gateway 清單" >&2
    record_sync_history "failed" "final list empty, aborted" "$total_merged" "0" "$excluded_by_native" "$whitelisted_count"
    exit 1
  fi

  local list_ids_file="$TMP_DIR/final_list_ids.txt"
  if ! upload_lists "$final_file" > "$list_ids_file"; then
    record_sync_history "failed" "upload_lists failed" "$total_merged" "$total_uploaded" "$excluded_by_native" "$whitelisted_count"
    exit 1
  fi

  if ! ensure_policy "$list_ids_file"; then
    record_sync_history "failed" "ensure_policy failed" "$total_merged" "$total_uploaded" "$excluded_by_native" "$whitelisted_count"
    exit 1
  fi

  record_sync_history "success" "" "$total_merged" "$total_uploaded" "$excluded_by_native" "$whitelisted_count"
  log "同步完成：合併 $total_merged / 白名單扣除 $whitelisted_count / 原生分類扣除 $excluded_by_native / 最終上傳 $total_uploaded"
}

main "$@"
