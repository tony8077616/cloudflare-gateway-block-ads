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
BULK_BATCH_SIZE=650        # 實測過上限約 700（更高會被 431 Request Header Fields Too Large 拒絕），650 留安全邊際
BATCH_SLEEP=0.05           # 每批次間隔；實測 200 個並行請求皆成功、無速率限制，可以壓低間隔
PARALLEL_WORKERS=15        # 平行處理的分類查詢工作數量；實測驗證過 200 並行皆成功，15 留大量安全邊際

# D1 免費版每日寫入額度是 100,000 筆（官方文件：https://developers.cloudflare.com/workers/platform/pricing/），
# 額度午夜 UTC 重置。這裡保守抓 90,000 當上限，留給 custom_whitelist/custom_blocklist/sync_history
# 這些其他表的寫入用量一些餘裕，避免精準卡在官方數字上反而不小心超額。
D1_DAILY_WRITE_BUDGET=90000
D1_WRITES_THIS_RUN=0   # 全域計數器，追蹤這次執行已經寫入 D1 的筆數

log() { echo "[$(date '+%H:%M:%S')] $*" >&2; }
warn() { echo "[$(date '+%H:%M:%S')] ⚠ $*" >&2; }

is_valid_json() {
  # 讀 stdin，回傳是否為合法 JSON（用來在丟給 jq 做實際解析前先擋掉非 JSON 回應，
  # 避免印出一堆 jq parse error 雜訊）
  jq -e . >/dev/null 2>&1
}

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

cf_curl_with_status() {
  # 跟 cf_curl 一樣，但額外用 __HTTP_STATUS__ 分隔符號在輸出最後帶上 HTTP 狀態碼，
  # 供需要記錄失敗診斷資訊的呼叫點使用（不影響 cf_curl 本身，避免動到其他呼叫點）。
  local method="$1" path="$2" body="${3:-}"
  if [[ -n "$body" ]]; then
    curl -sS -X "$method" "$CF_API$path" \
      -H "Authorization: Bearer $CF_API_TOKEN" \
      -H "Content-Type: application/json" \
      --data "$body" \
      -w "__HTTP_STATUS__%{http_code}"
  else
    curl -sS -X "$method" "$CF_API$path" \
      -H "Authorization: Bearer $CF_API_TOKEN" \
      -w "__HTTP_STATUS__%{http_code}"
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
# IPv4 位址的每個區段剛好也符合上面那組網域格式規則（純數字也算合法 label），
# 會被誤判成合法網域混進清單，但 Cloudflare Gateway 的 DOMAIN 類型清單不接受 IP，
# 一批裡只要有一筆是 IP 就會讓整批 1000 筆一起被拒絕。這裡額外排除掉。
IPV4_REGEX='^([0-9]{1,3}\.){3}[0-9]{1,3}$'

# ── 2. 各格式解析函式（吃 stdin，吐出網域清單到 stdout）───

parse_domains() {
  grep -vE '^[[:space:]]*(#|!|$)' \
    | sed -E 's/^\*\.//' \
    | tr 'A-Z' 'a-z' \
    | grep -E "$DOMAIN_REGEX" \
    | grep -vE "$IPV4_REGEX"
}

parse_adblock() {
  grep -E '^\|\|[a-zA-Z0-9.*_-]+\^' \
    | grep -v '^@@' \
    | grep -v '##\|#@#\|#?#' \
    | grep -v '\$domain=' \
    | sed -E 's/^\|\|([a-zA-Z0-9.*_-]+)\^.*/\1/' \
    | sed -E 's/^\*\.//' \
    | tr 'A-Z' 'a-z' \
    | grep -E "$DOMAIN_REGEX" \
    | grep -vE "$IPV4_REGEX"
}

parse_hosts() {
  grep -E '^(0\.0\.0\.0|127\.0\.0\.1|::1|::)[[:space:]]+' \
    | awk '{print $2}' \
    | tr 'A-Z' 'a-z' \
    | grep -E "$DOMAIN_REGEX" \
    | grep -vE "$IPV4_REGEX"
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
  if ! is_valid_json <<< "$resp" || [[ "$(jq -r '.success' <<< "$resp")" != "true" ]]; then
    warn "讀取白名單失敗，本次視為空白名單（best effort，不中斷流程）"
    return
  fi
  jq -r '.result[0].results[]?.domain // empty' <<< "$resp"
}

load_custom_blocklist() {
  local resp
  resp=$(d1_query "SELECT domain FROM custom_blocklist")
  if ! is_valid_json <<< "$resp" || [[ "$(jq -r '.success' <<< "$resp")" != "true" ]]; then
    warn "讀取自訂封鎖清單失敗，本次視為空清單（best effort，不中斷流程）"
    return
  fi
  jq -r '.result[0].results[]?.domain // empty' <<< "$resp"
}

# ── 5. D1：分類快取 ───────────────────────────────────────

load_category_cache() {
  # 輸出：每行「domain is_ads_category」，只取未過期的快取
  local cutoff resp
  cutoff=$(( $(date +%s) - CACHE_TTL_DAYS * 86400 ))
  resp=$(d1_query "SELECT domain, is_ads_category FROM domain_category_cache WHERE checked_at >= ?" \
    "$(jq -n --arg c "$cutoff" '[$c]')")
  if ! is_valid_json <<< "$resp" || [[ "$(jq -r '.success' <<< "$resp")" != "true" ]]; then
    warn "讀取分類快取失敗，本次視為無快取，將重新查詢全部網域"
    return
  fi
  jq -r '.result[0].results[]? | "\(.domain) \(.is_ads_category)"' <<< "$resp"
}

save_category_cache_batch() {
  # $1 = 檔案，每行「domain\tis_ads\tcategories_json」
  # 分批寫入，避免單次 D1 batch request 塞入過多資料列導致失敗/逾時。
  # 同時檢查每日寫入額度（D1 免費版 100,000 筆/天），這次執行累計寫入量
  # 一旦達到 D1_DAILY_WRITE_BUDGET，就停止繼續寫入快取（不影響本次同步的封鎖清單結果，
  # 只是這批網域的分類結果沒能快取下來，下次同步會重新查詢）。
  local batch_file="$1"
  [[ -s "$batch_file" ]] || return 0

  local now write_chunk_size=200
  now=$(date +%s)

  local total_lines
  total_lines=$(wc -l < "$batch_file" | xargs)
  local start=1
  while [[ $start -le $total_lines ]]; do
    if [[ $D1_WRITES_THIS_RUN -ge $D1_DAILY_WRITE_BUDGET ]]; then
      local remaining=$((total_lines - start + 1))
      warn "本次執行 D1 寫入量已達每日額度上限（$D1_DAILY_WRITE_BUDGET 筆），停止繼續寫入分類快取，剩餘 $remaining 筆網域的分類結果這次不會被快取（不影響封鎖清單本身，只是下次同步這些網域要重新查詢分類）"
      break
    fi

    local sub_chunk_file="$TMP_DIR/cache_write_chunk.txt"
    sed -n "${start},$((start + write_chunk_size - 1))p" "$batch_file" > "$sub_chunk_file"
    local this_chunk_size
    this_chunk_size=$(wc -l < "$sub_chunk_file" | xargs)

    # 如果這一批會讓累計寫入量超過額度，只取額度剩餘的部分
    if [[ $((D1_WRITES_THIS_RUN + this_chunk_size)) -gt $D1_DAILY_WRITE_BUDGET ]]; then
      local allowed=$((D1_DAILY_WRITE_BUDGET - D1_WRITES_THIS_RUN))
      head -n "$allowed" "$sub_chunk_file" > "${sub_chunk_file}.trimmed"
      mv "${sub_chunk_file}.trimmed" "$sub_chunk_file"
      this_chunk_size=$allowed
    fi

    local batch_json
    batch_json=$(jq -R -s -c --arg now "$now" '
      split("\n") | map(select(length > 0) | split("\t")) | map({
        sql: "INSERT INTO domain_category_cache (domain, is_ads_category, categories, checked_at) VALUES (?, ?, ?, ?) ON CONFLICT(domain) DO UPDATE SET is_ads_category=excluded.is_ads_category, categories=excluded.categories, checked_at=excluded.checked_at",
        params: [.[0], .[1], .[2], $now]
      })
    ' "$sub_chunk_file")

    local body resp
    body=$(jq -n --argjson batch "$batch_json" '{batch: $batch}')
    resp=$(curl -sS --max-time 30 -X POST "$CF_API/accounts/$CF_ACCOUNT_ID/d1/database/$D1_DATABASE_ID/query" \
      -H "Authorization: Bearer $CF_API_TOKEN" -H "Content-Type: application/json" \
      --data "$body")
    if [[ "$(echo "$resp" | jq -r '.success // false')" != "true" ]]; then
      warn "寫入分類快取第 $start~$((start + write_chunk_size)) 批失敗，略過（不影響本次結果，只影響下次快取命中率）"
    else
      D1_WRITES_THIS_RUN=$((D1_WRITES_THIS_RUN + this_chunk_size))
    fi

    start=$((start + write_chunk_size))
  done
}

# ── 6. Cloudflare 原生分類批次查詢（平行處理）──────────────

_check_categories_worker() {
  # $1 = 這個 worker 要處理的網域清單檔案
  # $2 = 輸出檔案（domain is_ads）
  # $3 = 快取寫入用檔案（domain\tis_ads\tcategories）
  # $4 = worker 編號（僅用於 log 訊息辨識）
  local chunk_file="$1" out_file="$2" cache_batch_file="$3" worker_id="$4"
  local total
  total=$(wc -l < "$chunk_file" | xargs)
  : > "$out_file"
  : > "$cache_batch_file"

  local i=0
  while [[ $i -lt $total ]]; do
    local batch_file="${chunk_file}.batch_$i"
    sed -n "$((i+1)),$((i+BULK_BATCH_SIZE))p" "$chunk_file" > "$batch_file"

    local query=""
    while IFS= read -r d; do
      query="${query}&domain=$d"
    done < "$batch_file"
    query="${query#&}"

    local resp
    resp=$(curl -sS --max-time 30 "$CF_API/accounts/$CF_ACCOUNT_ID/intel/domain/bulk?$query" \
      -H "Authorization: Bearer $CF_API_TOKEN")

    if ! is_valid_json <<< "$resp"; then
      warn "[worker $worker_id] 第 $i~$((i+BULK_BATCH_SIZE)) 批分類查詢回應不是合法 JSON（可能是暫時性網路問題或速率限制），這批網域本次視為『未被原生分類涵蓋』（保守處理，寧可多上傳也不要漏擋）"
      awk '{print $1, 0}' "$batch_file" >> "$out_file"
    elif [[ "$(jq -r '.success // false' <<< "$resp")" != "true" ]]; then
      warn "[worker $worker_id] 第 $i~$((i+BULK_BATCH_SIZE)) 批分類查詢失敗，這批網域本次視為『未被原生分類涵蓋』（保守處理，寧可多上傳也不要漏擋）"
      awk '{print $1, 0}' "$batch_file" >> "$out_file"
    else
      jq -r '.result[]? |
        [.domain, (if ([.content_categories[]?.name] | any(. == "Advertisements" or . == "Trackers/Analytics")) then 1 else 0 end),
         ([.content_categories[]?.name] | tostring)] | @tsv' <<< "$resp" \
        | while IFS=$'\t' read -r domain is_ads cats; do
            echo "$domain $is_ads" >> "$out_file"
            echo -e "$domain\t$is_ads\t$cats" >> "$cache_batch_file"
          done
    fi

    rm -f "$batch_file"
    log "[worker $worker_id] 分類查詢進度：$(( i + BULK_BATCH_SIZE > total ? total : i + BULK_BATCH_SIZE ))/$total"
    i=$((i + BULK_BATCH_SIZE))
    sleep "$BATCH_SLEEP"
  done
}

check_native_categories() {
  # $1 = 待查詢網域清單檔案
  # 輸出：每行「domain is_ads」，同時把結果寫回 D1 快取
  # 設計：切成 PARALLEL_WORKERS 份，平行處理，大幅縮短總時間
  #（單一 worker 內部仍是循序批次查詢，用 BATCH_SLEEP 控制節奏，
  #  多個 worker 加總後的請求速率仍在 Cloudflare 速率限制內）
  local to_check_file="$1"
  local total
  total=$(wc -l < "$to_check_file" | xargs)
  [[ "$total" -eq 0 ]] && return 0

  local split_dir="$TMP_DIR/split"
  mkdir -p "$split_dir"
  local lines_per_worker=$(( (total + PARALLEL_WORKERS - 1) / PARALLEL_WORKERS ))
  split -l "$lines_per_worker" -d -a 2 "$to_check_file" "$split_dir/chunk_"

  local pids=()
  local worker_id=0
  for chunk_file in "$split_dir"/chunk_*; do
    [[ -f "$chunk_file" ]] || continue
    local out_file="${chunk_file}.out"
    local cache_file="${chunk_file}.cache"
    _check_categories_worker "$chunk_file" "$out_file" "$cache_file" "$worker_id" &
    pids+=($!)
    worker_id=$((worker_id + 1))
  done

  log "已啟動 ${#pids[@]} 個平行查詢工作，共 $total 筆網域待查"

  local failed_workers=0
  for pid in "${pids[@]}"; do
    wait "$pid" || failed_workers=$((failed_workers + 1))
  done
  [[ $failed_workers -gt 0 ]] && warn "有 $failed_workers 個平行查詢工作發生非預期錯誤（個別批次失敗已在各自流程內做保守處理，不影響整體繼續執行）"

  # 合併所有 worker 的輸出
  cat "$split_dir"/chunk_*.out 2>/dev/null

  local merged_cache="$TMP_DIR/cache_batch_merged.txt"
  cat "$split_dir"/chunk_*.cache 2>/dev/null > "$merged_cache"
  save_category_cache_batch "$merged_cache"
  report_category_breakdown "$merged_cache"
}

report_category_breakdown() {
  # $1 = 快取檔案（domain\tis_ads\tcategories_json），輸出診斷統計到 stderr
  # 目的：讓每次執行都能看到「有沒有分類」「分類分布」，
  # 不用像這次一樣事後手動下 SQL 才能查。
  local cache_file="$1"
  [[ -s "$cache_file" ]] || return 0

  local total empty_count
  total=$(wc -l < "$cache_file" | xargs)
  empty_count=$(awk -F'\t' '$3 == "[]"' "$cache_file" | wc -l | xargs)

  log "── 分類統計診斷 ──"
  log "本次查詢網域總數：$total"
  log "完全沒有 Cloudflare 分類：$empty_count（$(( empty_count * 100 / (total > 0 ? total : 1) ))%）"
  log "有分類：$((total - empty_count))（$(( (total - empty_count) * 100 / (total > 0 ? total : 1) ))%）"

  local top_cats
  top_cats=$(awk -F'\t' '$3 != "[]" {print $3}' "$cache_file" \
    | jq -rs 'flatten | reduce .[] as $c ({}; .[$c] += 1) | to_entries | sort_by(-.value) | .[0:10] | .[] | "\(.key): \(.value)"' 2>/dev/null)

  if [[ -n "$top_cats" ]]; then
    log "分類分布前 10 名："
    while IFS= read -r line; do
      log "  $line"
    done <<< "$top_cats"
  fi
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

    # 單一清單上傳加上重試機制（最多 3 次，指數退避），
    # 避免 150+ 次連續呼叫中偶發的暫時性網路/API 波動就讓整個上傳流程中止。
    local resp resp_raw http_status list_id attempt upload_ok=0
    for attempt in 1 2 3; do
      local list_id_for_this_attempt=""
      if [[ -n "${existing_by_index[$chunk_num]:-}" ]]; then
        list_id_for_this_attempt="${existing_by_index[$chunk_num]}"
        resp_raw=$(cf_curl_with_status PUT "/accounts/$CF_ACCOUNT_ID/gateway/lists/$list_id_for_this_attempt" "$body")
      else
        resp_raw=$(cf_curl_with_status POST "/accounts/$CF_ACCOUNT_ID/gateway/lists" "$body")
      fi
      resp="${resp_raw%__HTTP_STATUS__*}"
      http_status="${resp_raw##*__HTTP_STATUS__}"

      if is_valid_json <<< "$resp" && [[ "$(jq -r '.success' <<< "$resp")" == "true" ]]; then
        list_id="${list_id_for_this_attempt:-$(jq -r '.result.id' <<< "$resp")}"
        upload_ok=1
        break
      fi

      warn "清單 $name 第 $attempt 次上傳失敗（HTTP $http_status）$([[ $attempt -lt 3 ]] && echo "，$((attempt * 2)) 秒後重試" || echo "，已達重試上限")"
      [[ $attempt -lt 3 ]] && sleep $((attempt * 2))
    done

    if [[ $upload_ok -ne 1 ]]; then
      local affected_count
      affected_count=$(wc -l < "$chunk_file" | xargs)
      warn "清單 $name 重試 3 次後仍然失敗，這批 $affected_count 筆網域這次同步不會被涵蓋（不中止整個流程，繼續處理下一批；下次同步會再次嘗試）"

      # 把完整失敗診斷寫進 D1，供日後檢討改善（例如判斷是不是特定內容、特定時段容易失敗）
      local error_detail_json
      error_detail_json=$(jq -n --arg r "$resp" '$r[0:2000]')  # 截斷避免內容過長
      d1_query \
        "INSERT INTO upload_failures (run_at, list_name, http_status, error_detail, domain_count_affected, attempt_count) VALUES (?, ?, ?, ?, ?, ?)" \
        "$(jq -n --arg t "$(date +%s)" --arg n "$name" --arg s "$http_status" --arg e "$resp" --arg c "$affected_count" \
           '[$t, $n, $s, ($e[0:2000]), $c, "3"]')" \
        > /dev/null || warn "寫入上傳失敗診斷紀錄本身也失敗了（不影響本次同步結果）"

      start=$((start + LIST_CHUNK_SIZE))
      chunk_num=$((chunk_num + 1))
      continue
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

  if ! is_valid_json <<< "$resp" || [[ "$(jq -r '.success' <<< "$resp")" != "true" ]]; then
    echo "❌ Policy 更新失敗：$resp" >&2
    return 1
  fi
  local list_count
  list_count=$(wc -l < "$list_ids_file" | xargs)
  log "Policy 「$POLICY_NAME」已更新，引用 $list_count 個清單"
}

record_sync_history() {
  # $1 status, $2 notes, $3..$6 統計數字
  local status="$1" notes="$2" total_merged="$3" total_uploaded="$4" excluded_by_native="$5" whitelisted="$6"
  local params
  params=$(jq -n \
    --arg run_at "$(date +%s)" \
    --arg total_merged "$total_merged" \
    --arg total_uploaded "$total_uploaded" \
    --arg excluded_by_native "$excluded_by_native" \
    --arg whitelisted "$whitelisted" \
    --arg status "$status" \
    --arg notes "$notes" \
    '[$run_at, $total_merged, $total_uploaded, $excluded_by_native, $whitelisted, $status, $notes]')
  d1_query \
    "INSERT INTO sync_history (run_at, total_merged, total_uploaded, total_excluded_by_native_category, total_whitelisted, status, notes) VALUES (?, ?, ?, ?, ?, ?, ?)" \
    "$params" \
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
  upload_lists "$final_file" > "$list_ids_file"

  local uploaded_list_count
  uploaded_list_count=$(wc -l < "$list_ids_file" | xargs)
  if [[ $uploaded_list_count -eq 0 ]]; then
    echo "❌ 所有清單上傳全部失敗，中止更新 Policy（避免把它指向空清單）" >&2
    record_sync_history "failed" "all list uploads failed" "$total_merged" "$total_uploaded" "$excluded_by_native" "$whitelisted_count"
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
