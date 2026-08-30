#!/bin/bash
# ============================================================
# 白名單 / 自訂封鎖清單管理小工具（Shell 版本）
#
# 用法：
#   ./manage.sh whitelist add example.com "誤擋了常用服務"
#   ./manage.sh whitelist remove example.com
#   ./manage.sh whitelist list
#
#   ./manage.sh block add ads.example-manga-app.com "手動追加的廣告網域"
#   ./manage.sh block remove ads.example-manga-app.com
#   ./manage.sh block list
#
#   ./manage.sh find ads.example.com     # 這個網域為什麼會/不會被擋？
#
# 設計原則：單一筆操作失敗只印出錯誤訊息，不會讓程式整個崩潰（best effort）。
# ============================================================

set -uo pipefail

: "${CF_ACCOUNT_ID:?請先 export CF_ACCOUNT_ID}"
: "${CF_API_TOKEN:?請先 export CF_API_TOKEN}"
: "${D1_DATABASE_ID:?請先 export D1_DATABASE_ID}"

CF_API="https://api.cloudflare.com/client/v4"
DOMAIN_REGEX='^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)+$'

# find 子指令用得到的設定（跟 sync.sh 保持一致）
LIST_PREFIX="Block ads"
LIST_CHUNK_SIZE=1000
# 掃描 Gateway 清單時的平行度。實測結論：提高平行度沒有用，Gateway API 會節流。
#   12 條 → 224 份掃完約 55 秒（每請求約 2.9 秒）
#   20 條 → 224 份掃完約 56 秒（每請求約 5.0 秒，延遲同比例上升，總時間抵消）
# 瓶頸在伺服器端，不在這裡，所以維持 12 就好，不要再往上調。
FIND_PARALLEL=12
# 這裡是 ${VAR-default} 不是 ${VAR:-default}：少一個冒號，語意差很多。
# 加冒號的版本連「設成空字串」都會套用預設值，那樣就沒有辦法停用 KV 了。
# 這一行必須跟 sync.sh 的同名設定保持一致，否則兩支工具對同一個環境變數的反應會不同。
#
# 這個預設值是本 repo 自己的 namespace。**如果你是 fork 過去用的，要換成你自己的**：
# 沿用別人的 namespace id 配上你自己的 token，find 的分類那一項每次都會 404，
# 只會印「讀不到 KV 快照，略過這一項」—— 不會出錯，但那一項就永遠查不到東西。
KV_NAMESPACE_ID="${KV_NAMESPACE_ID-8b033b48486e45909750175222437f05}"
KV_CACHE_KEY="category-cache-v1"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

d1_query() {
  local sql="$1" params="${2:-[]}"
  local body
  body=$(jq -n --arg sql "$sql" --argjson params "$params" '{sql: $sql, params: $params}')
  curl -sS -X POST "$CF_API/accounts/$CF_ACCOUNT_ID/d1/database/$D1_DATABASE_ID/query" \
    -H "Authorization: Bearer $CF_API_TOKEN" -H "Content-Type: application/json" \
    --data "$body"
}

table_for() {
  case "$1" in
    whitelist) echo "custom_whitelist" ;;
    block) echo "custom_blocklist" ;;
    *) echo "" ;;
  esac
}

cmd_add() {
  local table_key="$1" domain="$2" reason="${3:-}"
  domain=$(echo "$domain" | xargs | tr 'A-Z' 'a-z')

  if ! echo "$domain" | grep -qE "$DOMAIN_REGEX"; then
    echo "❌ '$domain' 看起來不是合法的網域格式，沒有寫入。請確認拼字（例如是否誤帶了 http:// 或路徑）"
    return
  fi

  local table
  table=$(table_for "$table_key")
  local resp
  resp=$(d1_query \
    "INSERT INTO $table (domain, reason, added_at) VALUES (?, ?, ?) ON CONFLICT(domain) DO UPDATE SET reason=excluded.reason" \
    "$(jq -n --arg d "$domain" --arg r "$reason" --arg t "$(date +%s)" '[$d, $r, $t]')")

  if [[ "$(echo "$resp" | jq -r '.success')" == "true" ]]; then
    echo "✅ 已加入 $table_key：$domain"
    echo "   提醒：下次排程同步（或手動觸發 workflow）後才會實際生效"
  else
    echo "❌ 寫入失敗：$(echo "$resp" | jq -c '.errors')"
  fi
}

cmd_remove() {
  local table_key="$1" domain="$2"
  domain=$(echo "$domain" | xargs | tr 'A-Z' 'a-z')
  local table
  table=$(table_for "$table_key")
  local resp
  resp=$(d1_query "DELETE FROM $table WHERE domain = ?" "$(jq -n --arg d "$domain" '[$d]')")

  if [[ "$(echo "$resp" | jq -r '.success')" == "true" ]]; then
    echo "✅ 已從 $table_key 移除：$domain"
  else
    echo "❌ 移除失敗：$(echo "$resp" | jq -c '.errors')"
  fi
}

cmd_list() {
  local table_key="$1"
  local table
  table=$(table_for "$table_key")
  local resp
  resp=$(d1_query "SELECT domain, reason, added_at FROM $table ORDER BY added_at DESC")

  if [[ "$(echo "$resp" | jq -r '.success')" != "true" ]]; then
    echo "❌ 查詢失敗：$(echo "$resp" | jq -c '.errors')"
    return
  fi

  local count
  count=$(echo "$resp" | jq '.result[0].results | length')
  if [[ "$count" -eq 0 ]]; then
    echo "（$table_key 目前是空的）"
    return
  fi

  echo "$resp" | jq -r '.result[0].results[] | "  \(.domain)\t\(.reason // "")"' | column -t -s $'\t'
  echo "共 $count 筆"
}

cf_get() {
  curl -sS "$CF_API$1" -H "Authorization: Bearer $CF_API_TOKEN"
}

_domain_and_parents() {
  # 輸出這個網域本身，以及它所有「至少兩個標籤」的父網域，由長到短。
  # 這一步不能省：Gateway 的 DOMAIN 清單命中父網域時，會連同所有子網域一起擋，
  # 所以只查網域本體，會查不出真正的封鎖原因。
  local d="$1" rest
  while [[ "$d" == *.* ]]; do
    echo "$d"
    rest="${d#*.}"
    [[ "$rest" == *.* ]] || break   # 只剩 TLD 就停，不要拿 com/net 去比對
    d="$rest"
  done
}

_domain_proper_suffixes() {
  # 輸出這個網域「去掉至少一個標籤」之後的所有後綴，一路到裸 TLD。
  # 專供白名單後綴比對使用 —— 必須跟 sync.sh 的走法完全一致，細節見上方說明。
  local rest="$1"
  while [[ "$rest" == *.* ]]; do
    rest="${rest#*.}"
    echo "$rest"
  done
}

_find_check_whitelist() {
  # $1 = 目標網域, $2 = 父網域候選檔。命中就印出命中的那筆白名單條目。
  # 語意必須跟 sync.sh 一致：預設是精確比對，只有 *.suffix 寫法才吃後綴。
  local domain="$1" resp
  resp=$(d1_query "SELECT domain FROM custom_whitelist")
  [[ "$(echo "$resp" | jq -r '.success')" == "true" ]] || { echo "ERROR"; return; }

  # 刻意不用呼叫端傳進來的父網域檔：那一份含網域本體、又停在兩個標籤，
  # 兩點都跟 sync.sh 的後綴比對語意不合。這裡自己算一份忠實的。
  local sfile="$TMP_DIR/suffixes.txt"
  _domain_proper_suffixes "$domain" > "$sfile"

  echo "$resp" | jq -r '.result[0].results[]?.domain // empty' \
    | awk -v target="$domain" -v pfile="$sfile" '
        BEGIN { while ((getline p < pfile) > 0) parent[p] = 1 }
        {
          if ($0 == target) { print $0 " （精確比對）"; found = 1; exit }
          if (substr($0, 1, 2) == "*.") {
            suffix = substr($0, 3)
            if (suffix in parent) { print $0 " （後綴比對，命中 " suffix "）"; found = 1; exit }
          }
        }'
}

_find_check_blocklist() {
  local domain="$1" resp
  resp=$(d1_query "SELECT domain, reason FROM custom_blocklist WHERE domain = ?" \
    "$(jq -n --arg d "$domain" '[$d]')")
  [[ "$(echo "$resp" | jq -r '.success')" == "true" ]] || { echo "ERROR"; return; }
  echo "$resp" | jq -r '.result[0].results[]? | "\(.domain)\t\(.reason // "")"'
}

_kv_fetch_cache() {
  # $1 = 解壓後的輸出檔。抓取與解壓分成獨立函式，方便單獨測試解析邏輯。
  local tsv="$1" gz="$TMP_DIR/kv.gz" code

  # 停用時直接短路，不要發請求。少了這道，空的 namespace 會組出
  # .../namespaces//values/... 這種畸形 URL，照樣送出一次注定失敗的往返。
  [[ -n "$KV_NAMESPACE_ID" ]] || return 1

  code=$(curl -sS -o "$gz" -w '%{http_code}' \
    -H "Authorization: Bearer $CF_API_TOKEN" \
    "$CF_API/accounts/$CF_ACCOUNT_ID/storage/kv/namespaces/$KV_NAMESPACE_ID/values/$KV_CACHE_KEY" \
    2>/dev/null || echo 000)
  [[ "$code" == "200" ]] || return 1
  gunzip -c "$gz" > "$tsv" 2>/dev/null || return 1
  [[ -s "$tsv" ]]
}

_find_check_category_cache() {
  # 從 KV 快照查分類結果。走 KV 而不是 D1，所以這個指令對 D1 的讀取成本是零。
  local domain="$1" parents="$2"
  local tsv="$TMP_DIR/kv.tsv"

  if ! _kv_fetch_cache "$tsv"; then
    echo "UNAVAILABLE"
    return
  fi

  # 先印本體的結果，再印任何 is_ads=1 的父網域（父網域被原生分類擋到也會影響實際行為）
  awk -F'\t' -v target="$domain" -v pfile="$parents" '
    BEGIN { while ((getline p < pfile) > 0) if (p != target) parent[p] = 1 }
    $1 == target { printf "SELF\t%s\t%s\n", $2, $3 }
    ($1 in parent) && $2 == 1 { printf "PARENT\t%s\t%s\n", $1, $3 }
  ' "$tsv"
}

_find_scan_gateway_lists() {
  # $1 = 父網域候選檔。平行拉回所有 Block ads 清單的成員，找出命中的是哪一份。
  # 全程只打 Gateway API，不碰 D1。
  local parents="$1"
  local ids="$TMP_DIR/list_ids.txt" hits="$TMP_DIR/hits.txt"
  : > "$hits"

  cf_get "/accounts/$CF_ACCOUNT_ID/gateway/lists" \
    | jq -r --arg prefix "$LIST_PREFIX" \
        '.result[]? | select(.name | startswith($prefix)) | "\(.id)\t\(.name)"' \
    | sort -t$'\t' -k2,2 > "$ids"

  local total
  total=$(grep -c . "$ids" 2>/dev/null || true); total=${total:-0}
  if [[ "$total" -eq 0 ]]; then
    echo "NOLISTS"
    return
  fi
  echo "   掃描 $total 份 Gateway 清單中…" >&2

  local running=0 id name
  while IFS=$'\t' read -r id name; do
    {
      cf_get "/accounts/$CF_ACCOUNT_ID/gateway/lists/$id/items?per_page=$LIST_CHUNK_SIZE" \
        | jq -r '.result[]?.value // empty' \
        | grep -Fxf "$parents" 2>/dev/null \
        | while read -r hit; do printf '%s\t%s\n' "$name" "$hit" >> "$hits"; done
    } &
    running=$((running + 1))
    if [[ $running -ge $FIND_PARALLEL ]]; then
      wait -n 2>/dev/null || wait
      running=$((running - 1))
    fi
  done < "$ids"
  wait

  sort -u "$hits"
}

cmd_find() {
  local domain="$1"
  domain=$(echo "$domain" | xargs | tr 'A-Z' 'a-z')

  if ! echo "$domain" | grep -qE "$DOMAIN_REGEX"; then
    echo "❌ '$domain' 看起來不是合法的網域格式（注意不要帶 http:// 或路徑）"
    return 1
  fi

  local parents="$TMP_DIR/parents.txt"
  _domain_and_parents "$domain" > "$parents"

  echo "── 診斷 $domain ──"
  # 注意：paste -sd 的參數是「輪流使用的分隔符清單」，給 ', ' 會變成逗號與空白交替出現。
  # 要固定用同一個分隔符，就只能給一個字元，再自行補空白。
  echo "比對範圍：$(paste -sd, - < "$parents" | sed 's/,/, /g')"
  echo "（Gateway 的 DOMAIN 清單命中父網域時會連子網域一起擋，所以父網域也要一起查）"
  echo

  # 1. 白名單
  local wl blocked_reason="" verdict_parts=()
  # 第二個參數保留是為了呼叫形式一致；白名單比對自己算後綴集合，見該函式說明
  wl=$(_find_check_whitelist "$domain" "$parents")
  if [[ "$wl" == "ERROR" ]]; then
    echo "1. 白名單　　　　　　⚠ 查詢失敗"
  elif [[ -n "$wl" ]]; then
    echo "1. 白名單　　　　　　✅ 命中：$wl"
    echo "   → 這個網域會被排除在上傳清單之外。"
  else
    echo "1. 白名單　　　　　　未命中"
  fi

  # 2. 自訂封鎖清單
  local bl
  bl=$(_find_check_blocklist "$domain")
  if [[ "$bl" == "ERROR" ]]; then
    echo "2. 自訂封鎖清單　　　⚠ 查詢失敗"
  elif [[ -n "$bl" ]]; then
    echo "2. 自訂封鎖清單　　　✅ 命中：$(echo "$bl" | cut -f1)　理由：$(echo "$bl" | cut -f2)"
    echo "   → 不論來源清單有沒有收錄，都會被強制加進上傳清單。"
    verdict_parts+=("自訂封鎖清單")
  else
    echo "2. 自訂封鎖清單　　　未命中"
  fi

  # 3. Cloudflare 原生分類（讀 KV 快照，不碰 D1）
  local cat_out self_line parent_lines
  PARENT_CAT_HIT=0
  cat_out=$(_find_check_category_cache "$domain" "$parents")
  if [[ "$cat_out" == "UNAVAILABLE" ]]; then
    echo "3. Cloudflare 原生分類　⚠ 讀不到 KV 快照，略過這一項"
  else
    self_line=$(echo "$cat_out" | awk -F'\t' '$1 == "SELF" {print; exit}')
    parent_lines=$(echo "$cat_out" | awk -F'\t' '$1 == "PARENT"')
    if [[ -z "$self_line" ]]; then
      echo "3. Cloudflare 原生分類　快取中沒有這個網域（代表它沒出現在任何來源清單裡）"
    elif [[ "$(echo "$self_line" | cut -f2)" == "1" ]]; then
      echo "3. Cloudflare 原生分類　✅ 命中（查於 $(date -d "@$(echo "$self_line" | cut -f3)" '+%Y-%m-%d' 2>/dev/null || echo '?')）"
      echo "   → 已被 Cloudflare 內建的 Ads 分類涵蓋，因此「刻意不上傳」到 Gateway 清單，"
      echo "     但實際上仍然會被擋。這就是為什麼掃不到清單不代表沒被擋。"
      verdict_parts+=("Cloudflare 原生 Ads 分類")
    else
      echo "3. Cloudflare 原生分類　未涵蓋（查於 $(date -d "@$(echo "$self_line" | cut -f3)" '+%Y-%m-%d' 2>/dev/null || echo '?')）"
    fi
    if [[ -n "$parent_lines" ]]; then
      echo "   另外，這些父網域有被原生分類涵蓋："
      echo "$parent_lines" | awk -F'\t' '{print "     - " $2}'
      echo "   （僅供參考：是否連帶涵蓋子網域取決於 Cloudflare 對該分類的套用範圍，"
      echo "     這裡無法斷定，需要實際發一次 DNS 查詢確認）"
      PARENT_CAT_HIT=1
    fi
  fi

  # 4. Gateway 清單
  local hits
  hits=$(_find_scan_gateway_lists "$parents")
  if [[ "$hits" == "NOLISTS" ]]; then
    echo "4. Gateway 清單　　　⚠ 帳戶上找不到任何「$LIST_PREFIX」開頭的清單"
  elif [[ -n "$hits" ]]; then
    echo "4. Gateway 清單　　　✅ 命中："
    echo "$hits" | while IFS=$'\t' read -r lname hit; do
      if [[ "$hit" == "$domain" ]]; then
        echo "     $lname　←　$hit"
      else
        echo "     $lname　←　$hit（父網域，連同子網域一起擋）"
      fi
    done
    verdict_parts+=("Gateway 清單")
  else
    echo "4. Gateway 清單　　　不在任何一份清單中"
  fi

  echo
  if [[ -n "$wl" && "$wl" != "ERROR" ]]; then
    echo "結論：不會被擋 —— 白名單優先於所有封鎖來源。"
  elif [[ ${#verdict_parts[@]} -gt 0 ]]; then
    echo "結論：會被擋 —— 來源：$(printf '%s、' "${verdict_parts[@]}" | sed 's/、$//')"
  elif [[ "$PARENT_CAT_HIT" == "1" ]]; then
    echo "結論：無法斷定 —— 四項都沒有直接命中，但上面列出的父網域有被原生分類涵蓋。"
    echo "      實際是否被擋取決於該分類是否連帶套用到子網域，請發一次 DNS 查詢確認。"
  else
    echo "結論：不會被擋 —— 四項都沒有命中。"
    echo "      如果你預期它該被擋，先確認 sync_history 最後一次同步時間是否晚於你的異動時間。"
  fi
}

cmd_failures() {
  # 查看清單上傳失敗的診斷紀錄（upload_failures 表），供檢討改善用
  local limit="${1:-20}"
  local resp
  resp=$(d1_query "SELECT run_at, list_name, http_status, domain_count_affected, error_detail FROM upload_failures ORDER BY run_at DESC LIMIT ?" "$(jq -n --arg l "$limit" '[$l]')")

  if [[ "$(echo "$resp" | jq -r '.success')" != "true" ]]; then
    echo "❌ 查詢失敗：$(echo "$resp" | jq -c '.errors')"
    return
  fi

  local count
  count=$(echo "$resp" | jq '.result[0].results | length')
  if [[ "$count" -eq 0 ]]; then
    echo "（目前沒有失敗紀錄）"
    return
  fi

  echo "$resp" | jq -r '.result[0].results[] | "── \(.run_at | todate) ──\n清單：\(.list_name)　HTTP 狀態：\(.http_status)　受影響網域數：\(.domain_count_affected)\n錯誤內容：\(.error_detail)\n"'
  echo "共 $count 筆（顯示最新 $limit 筆）"

  echo ""
  echo "=== 依清單編號統計失敗次數（找出是否有特定清單反覆失敗）==="
  echo "$resp" | jq -r '.result[0].results[] | .list_name' | sort | uniq -c | sort -rn
}

usage() {
  cat << 'EOF'
用法：
  ./manage.sh whitelist add <domain> [reason]
  ./manage.sh whitelist remove <domain>
  ./manage.sh whitelist list

  ./manage.sh block add <domain> [reason]
  ./manage.sh block remove <domain>
  ./manage.sh block list

  ./manage.sh failures [limit]     # 查看清單上傳失敗的診斷紀錄，預設顯示最新 20 筆

  ./manage.sh find <domain>        # 診斷某個網域為什麼會/不會被擋
                                   # 會一併檢查白名單、自訂封鎖清單、Cloudflare 原生分類、
                                   # 以及所有 Gateway 清單（含父網域命中）
EOF
}

main() {
  if [[ $# -lt 1 ]]; then
    usage
    exit 1
  fi

  if [[ "$1" == "failures" ]]; then
    cmd_failures "${2:-20}"
    return
  fi

  if [[ "$1" == "find" ]]; then
    if [[ $# -lt 2 ]]; then
      echo "❌ 用法：manage.sh find <domain>"
      exit 1
    fi
    cmd_find "$2"
    return
  fi

  if [[ $# -lt 2 ]]; then
    usage
    exit 1
  fi

  local table_key="$1" action="$2"
  if [[ -z "$(table_for "$table_key")" ]]; then
    echo "❌ 未知類型 '$table_key'，只能是 whitelist 或 block"
    exit 1
  fi

  case "$action" in
    add)
      if [[ $# -lt 3 ]]; then
        echo "❌ 用法：manage.sh <whitelist|block> add <domain> [reason]"
        exit 1
      fi
      cmd_add "$table_key" "$3" "${4:-}"
      ;;
    remove)
      if [[ $# -lt 3 ]]; then
        echo "❌ 用法：manage.sh <whitelist|block> remove <domain>"
        exit 1
      fi
      cmd_remove "$table_key" "$3"
      ;;
    list)
      cmd_list "$table_key"
      ;;
    *)
      echo "❌ 未知操作 '$action'，只能是 add / remove / list"
      exit 1
      ;;
  esac
}

main "$@"
