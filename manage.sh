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
# 設計原則：單一筆操作失敗只印出錯誤訊息，不會讓程式整個崩潰（best effort）。
# ============================================================

set -uo pipefail

: "${CF_ACCOUNT_ID:?請先 export CF_ACCOUNT_ID}"
: "${CF_API_TOKEN:?請先 export CF_API_TOKEN}"
: "${D1_DATABASE_ID:?請先 export D1_DATABASE_ID}"

CF_API="https://api.cloudflare.com/client/v4"
DOMAIN_REGEX='^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)+$'

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
