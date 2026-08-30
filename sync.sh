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
# 結束前先把本次的 D1 寫入用量記回去，再清掉暫存目錄。
# 中途 exit 1 的失敗路徑也會經過這裡，避免已經花掉的額度沒被記錄，
# 導致下次執行以為額度還很充裕而超額。save_daily_budget 本身是冪等的。
cleanup_on_exit() {
  local code=$?
  # 用 ${VAR:-} 取值：這個 trap 在設定變數與函式之前就已掛上，
  # 若是在初始化階段（例如缺少必要環境變數）就結束，這些名稱還不存在。
  if [[ "${GROUP_OPEN:-0}" == "1" ]]; then group_end; fi
  if [[ "${STATE_AVAILABLE:-0}" == "1" && "${D1_WRITES_ADDED:-0}" -gt 0 ]]; then
    save_daily_budget 2>/dev/null || true
  fi
  rm -rf "$TMP_DIR"
  return $code
}
trap cleanup_on_exit EXIT

: "${CF_ACCOUNT_ID:?請設定 CF_ACCOUNT_ID}"
: "${CF_API_TOKEN:?請設定 CF_API_TOKEN}"
: "${D1_DATABASE_ID:?請設定 D1_DATABASE_ID}"

CF_API="https://api.cloudflare.com/client/v4"
LIST_PREFIX="Block ads"
LIST_CHUNK_SIZE=1000
POLICY_NAME="Block ads"
# 分類快取的存活天數。過期的網域會重新向 Intel 查一次分類，並重新寫回 D1，
# 所以這個數字直接決定「重新查詢」與「重新寫入」的壓力有多大。
#
# 為什麼從 30 拉到 90：domain_category_cache 目前有約 462,000 列，而且幾乎都是在
# 很窄的時間區間內一次建好的，所以 30 天的 TTL 等於讓它們「集體同時過期」——
# 到期那天要重查重寫將近 46 萬列，以 D1_DAILY_WRITE_BUDGET 的 90,000 筆/天來算
# 要連續佔滿約五天的額度，期間其他寫入都得排隊。
# 廣告網域的分類極少變動（會變的通常是新網域，那本來就不在快取裡、走的是新增路徑），
# 30 天過度保守。拉到 90 天可以把換發壓力攤成三分之一，也把第一次集體到期往後推。
# 代價是「某網域被 Cloudflare 重新分類」這件事最多晚 90 天才會反映；這類變動很罕見，
# 真的遇到可以用 FORCE_SYNC=1 或直接清掉該列處理。
CACHE_TTL_DAYS=90
BULK_BATCH_SIZE=650        # 實測過上限約 700（更高會被 431 Request Header Fields Too Large 拒絕），650 留安全邊際
BATCH_SLEEP=0.05           # 每批次間隔；實測 200 個並行請求皆成功、無速率限制，可以壓低間隔
PARALLEL_WORKERS=15        # 平行處理的分類查詢工作數量；實測驗證過 200 並行皆成功，15 留大量安全邊際

# D1 免費版每日寫入額度是 100,000 筆（官方文件：https://developers.cloudflare.com/workers/platform/pricing/），
# 額度午夜 UTC 重置。這裡保守抓 90,000 當上限，留給 custom_whitelist/custom_blocklist/sync_history
# 這些其他表的寫入用量一些餘裕，避免精準卡在官方數字上反而不小心超額。
#
# 重要：這個計數器必須「跨執行累計」。舊版叫 D1_WRITES_THIS_RUN，每次執行歸零，
# 在一天只跑一次的排程下剛好等價於每日用量；但改成每小時跑之後，24 次執行會各自
# 以為自己有完整的 90,000 額度可用，最壞情況寫到 24 倍，遠超真實的每日上限。
# 現在改成啟動時從 d1_daily_writes 讀「今天（UTC）已用量」，結束時把本次增量寫回。
D1_DAILY_WRITE_BUDGET=90000
D1_DAY="$(date -u +%F)"      # UTC 日期字串，額度以此為界（跟 Cloudflare 的重置時點一致）
D1_WRITES_TODAY=0            # 今日已用量，啟動時從 D1 載入
D1_WRITES_ADDED=0            # 本次執行新增的寫入量，結束時累加回 D1
DEFERRED_CACHE_ROWS=0        # 本次因額度不足而沒能寫入的分類快取筆數
DEFERRED_BACKLOG=0           # 上次執行遺留、還沒補寫的分類快取筆數

# 設為 1 可略過 checksum 閘門強制完整同步（workflow_dispatch 手動觸發時可指定）
FORCE_SYNC="${FORCE_SYNC:-0}"
# 狀態表不可用時退回的模式：一定完整同步、不做差異上傳（永遠正確，只是比較慢）
STATE_AVAILABLE=1

# 前次狀態檔路徑（載入後由 state_get 讀取，用來取各來源的 ETag/Last-Modified）
PREV_STATE_FILE=""

SLOT_FETCH_PARALLEL=10   # 讀取現有清單成員時的平行度（224 份循序讀太慢）

# ── Cloudflare KV：分類快取的讀取側前置快取 ────────────────
# domain_category_cache 有 46 萬列，而且 checked_at 上沒有（也不該有）索引 ——
# TTL 內幾乎每一列都命中 WHERE 條件，選擇性接近 0，走索引只會更貴。
# 所以每次真正同步都是一次 46 萬列的全表掃描，光這一條就把 D1 每日讀取額度吃掉大半。
#
# 對策：把快取內容整份存成 KV 上的一個 gzip blob，讀取時抓這一個物件就好，
# D1 的每次同步讀取量從約 462,000 列降到只剩狀態表的數十列。
#
# 定位很重要：KV 只是「讀取側」快取，D1 仍然是權威來源，寫入路徑完全沒有改變。
# KV 讀取失敗、快照不存在、解壓失敗、格式不符 —— 任何一種情況都會退回讀 D1，
# 也就是退回這個改動之前的行為，所以最壞情況等於現狀，不會更差。
KV_NAMESPACE_ID="${KV_NAMESPACE_ID:-8b033b48486e45909750175222437f05}"  # adblock-category-cache
KV_CACHE_KEY="category-cache-v1"
KV_MAX_BYTES=$((25 * 1024 * 1024))   # KV 單一值的硬上限
KV_WARN_BYTES=$((20 * 1024 * 1024))  # 逼近上限時先示警，別等到寫入被拒才發現
# namespace id 沒設就整個停用，行為完全等同這個改動之前
if [[ -n "$KV_NAMESPACE_ID" ]]; then KV_ENABLED=1; else KV_ENABLED=0; fi
# 設為 1 可略過 KV 快照、強制從 D1 重讀並重建快照（快照壞掉時的復原手段）
REBUILD_CACHE_BLOB="${REBUILD_CACHE_BLOB:-0}"

CACHE_SOURCE="none"      # 本次分類快取實際的來源：kv / d1 / none
CACHE_BLOB_ROWS=0        # 寫回 KV 的快照列數
CACHE_BLOB_BYTES=0       # 寫回 KV 的快照壓縮後位元組數

# 清單上傳進度統計（由 sync_slots 填寫，供結尾摘要使用）
UPLOAD_STAT_UPLOADED=0
UPLOAD_STAT_SKIPPED=0
UPLOAD_STAT_FAILED=0
UPLOAD_STAT_TOTAL=0

log() { echo "[$(date '+%H:%M:%S')] $*" >&2; }
warn() { echo "[$(date '+%H:%M:%S')] ⚠ $*" >&2; }

# GitHub Actions 的可收折區塊（跟 Set up job / Run actions/checkout 一樣可以收合）。
#
# 標記必須跟 log/warn 走同一個輸出串流，否則會錯位：stderr 不緩衝、stdout 被導向
# 管線時是區塊緩衝，兩者分開寫的話 ::group:: 會跟它要包住的內容分家。log 又不能改
# 寫 stdout —— 那會污染 load_whitelist 這類用 $(...) 取回傳值的函式。
# 所以標記一律寫 stderr，並在 workflow 用 `./sync.sh 2>&1` 合併成單一串流。
#
# Actions 不支援巢狀 group，因此 group_begin 會先關掉前一個，呼叫端不必自己配對。
GROUP_OPEN=0
group_begin() {
  group_end
  case "${GITHUB_ACTIONS:-}" in
    "") echo "── $* ──" >&2 ;;
    *)  echo "::group::$*" >&2 ;;
  esac
  GROUP_OPEN=1
}
group_end() {
  [[ $GROUP_OPEN -eq 1 ]] || return 0
  case "${GITHUB_ACTIONS:-}" in
    "") : ;;
    *)  echo "::endgroup::" >&2 ;;
  esac
  GROUP_OPEN=0
}

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

d1_batch() {
  # $1 = statements 的 JSON array（[{sql, params?}, ...]），走 batch API 一次送多筆，
  # 比逐筆送快很多，也少掉大量往返延遲。
  local batch_json="$1" body
  body=$(jq -n --argjson batch "$batch_json" '{batch: $batch}')
  cf_curl POST "/accounts/$CF_ACCOUNT_ID/d1/database/$D1_DATABASE_ID/query" "$body"
}

d1_ok() {
  # 讀 stdin，判斷 D1 回應是否成功
  local resp; resp="$(cat)"
  is_valid_json <<< "$resp" && [[ "$(jq -r '.success' <<< "$resp")" == "true" ]]
}

# ── 0. 狀態表（本次新增）─────────────────────────────────
# 用 IF NOT EXISTS 自建，讓腳本自帶 migration：不需要額外的手動建表步驟，
# 資料庫被重建時也能自動恢復。DDL 對已存在的表是 no-op，成本可忽略。
#
#   sync_state       key-value，存各來源解析後輸出的 checksum、白名單/自訂封鎖清單
#                    的 checksum，以及積欠未寫入的分類快取筆數
#   d1_daily_writes  每日（UTC）D1 寫入用量，讓額度控管跨執行累計
#
# 註：曾經有一張 list_chunk_state 存每份清單的 checksum，用來判斷哪幾份要重傳。
# 改用穩定槽位模型後，每次同步都直接向 Cloudflare 讀回實際成員，那才是權威來源，
# 同時涵蓋差異偵測與中斷續傳，這張表就沒有存在意義了，這裡順手清掉。

ensure_schema() {
  local batch
  batch=$(jq -n '[
    {sql: "CREATE TABLE IF NOT EXISTS sync_state (key TEXT PRIMARY KEY, value TEXT NOT NULL, updated_at INTEGER NOT NULL)"},
    {sql: "CREATE TABLE IF NOT EXISTS d1_daily_writes (day TEXT PRIMARY KEY, writes INTEGER NOT NULL, updated_at INTEGER NOT NULL)"},
    {sql: "DROP TABLE IF EXISTS list_chunk_state"}
  ]')
  if d1_batch "$batch" | d1_ok; then
    return 0
  fi
  warn "建立/確認狀態表失敗，本次退回無狀態模式：會完整同步且不做差異上傳（結果仍然正確，只是比較慢）"
  STATE_AVAILABLE=0
  return 1
}

load_sync_state() {
  # 輸出每行「key<TAB>value」
  [[ $STATE_AVAILABLE -eq 1 ]] || return 0
  local resp
  resp=$(d1_query "SELECT key, value FROM sync_state")
  if ! d1_ok <<< "$resp"; then
    warn "讀取 sync_state 失敗，本次視為無先前狀態（會完整同步）"
    return 0
  fi
  jq -r '.result[0].results[]? | "\(.key)\t\(.value)"' <<< "$resp"
}

save_sync_state() {
  # $1 = 檔案，每行「key<TAB>value」
  [[ $STATE_AVAILABLE -eq 1 ]] || return 0
  local state_file="$1"
  [[ -s "$state_file" ]] || return 0
  local batch rows
  batch=$(jq -R -s -c --arg now "$(date +%s)" '
    split("\n") | map(select(length > 0) | split("\t")) | map({
      sql: "INSERT INTO sync_state (key, value, updated_at) VALUES (?, ?, ?) ON CONFLICT(key) DO UPDATE SET value=excluded.value, updated_at=excluded.updated_at",
      params: [.[0], .[1], $now]
    })' "$state_file")
  rows=$(jq 'length' <<< "$batch")
  if d1_batch "$batch" | d1_ok; then
    D1_WRITES_ADDED=$((D1_WRITES_ADDED + rows))
  else
    warn "寫入 sync_state 失敗（下次執行會因為讀不到 checksum 而完整同步，結果仍正確）"
  fi
}

load_daily_budget() {
  [[ $STATE_AVAILABLE -eq 1 ]] || return 0
  local resp
  resp=$(d1_query "SELECT writes FROM d1_daily_writes WHERE day = ?" "$(jq -n --arg d "$D1_DAY" '[$d]')")
  if ! d1_ok <<< "$resp"; then
    # 讀不到就保守假設已用掉一半額度，寧可少寫一點快取，也不要不小心超額
    warn "讀取今日 D1 額度用量失敗，保守視為已用掉半數額度"
    D1_WRITES_TODAY=$((D1_DAILY_WRITE_BUDGET / 2))
    return
  fi
  D1_WRITES_TODAY=$(jq -r '.result[0].results[0].writes // 0' <<< "$resp")
  log "今日（$D1_DAY UTC）D1 已用寫入量：$D1_WRITES_TODAY / $D1_DAILY_WRITE_BUDGET"
}

save_daily_budget() {
  # 冪等：寫回成功就把增量歸零，重複呼叫不會重複累加。
  # 這讓它可以同時掛在正常結束路徑和 EXIT trap 上，中途 exit 1 也不會漏記用量。
  [[ $STATE_AVAILABLE -eq 1 ]] || return 0
  [[ $D1_WRITES_ADDED -gt 0 ]] || return 0
  # 用 writes = writes + ? 而不是直接覆寫，避免同時間有另一個 run 也在累加時互相蓋掉
  if d1_query \
      "INSERT INTO d1_daily_writes (day, writes, updated_at) VALUES (?, ?, ?) ON CONFLICT(day) DO UPDATE SET writes = writes + excluded.writes, updated_at = excluded.updated_at" \
      "$(jq -n --arg d "$D1_DAY" --arg w "$D1_WRITES_ADDED" --arg t "$(date +%s)" '[$d, $w, $t]')" \
      | d1_ok; then
    D1_WRITES_TODAY=$((D1_WRITES_TODAY + D1_WRITES_ADDED))
    D1_WRITES_ADDED=0
  else
    warn "回寫今日 D1 額度用量失敗（下次執行會低估已用量）"
  fi
}

d1_budget_left() {
  echo $(( D1_DAILY_WRITE_BUDGET - D1_WRITES_TODAY - D1_WRITES_ADDED ))
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
  # 關鍵修正（發現於實際誤判排查）：
  # 1. 開頭比對規則收嚴為 `^||domain^` 後面必須「立刻結束」或「只跟著 $修飾詞」，
  #    不能再有路徑內容（例如 ^*/xxx.js、^/path 這種）。舊版只檢查開頭符合就整個
  #    網域當作要擋，會把「只擋特定檔名/路徑」的規則誤判成「整個網域都要擋」。
  # 2. domain= 排除條件從「只抓 $domain= 開頭」改成「$ 或逗號後面接 domain=」都算，
  #    因為 AdBlock 修飾詞是逗號分隔列表，domain= 常常不是第一個修飾詞
  #    （例如 $media,redirect=noop.mp3,domain=xxx.com 這種會被舊版漏掉）。
  # 3. 只排除 domain= 不夠：AdBlock 修飾詞裡凡是 name=value 形式的，不是「限定套用範圍」
  #    （domain= to= from= denyallow= ipaddress= method=）就是「改寫請求/回應內容」
  #    （removeparam= redirect= redirect-rule= csp= replace= removeheader= urltransform=），
  #    沒有任何一個代表「整個網域要在 DNS 層封鎖」。例如 ublock-privacy 的
  #    `||youtube.com^$removeparam=pp` 只是要拿掉網址上的 pp 追蹤參數，舊版卻把
  #    youtube.com 整站當成廣告網域上傳，導致 YouTube 全站在 Gateway 被擋。
  #    因此改成「修飾詞裡只要出現 = 就整條丟棄」。$badfilter 是「停用另一條規則」，
  #    語意跟封鎖相反，一併排除。$popup / $third-party / $all / $doc 這類真正的
  #    封鎖修飾詞不含 =，不受影響。
  grep -E '^\|\|[a-zA-Z0-9.*_-]+\^(\$[a-zA-Z0-9_,.=~|-]*)?$' \
    | grep -v '^@@' \
    | grep -v '##\|#@#\|#?#' \
    | grep -vE '\$[a-zA-Z0-9_,.=~|-]*=' \
    | grep -vE '(\$|,)badfilter(,|$)' \
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

state_get() {
  # $1 = key，從已載入的前次狀態檔取值（檔案不存在時回傳空字串）
  [[ -n "${PREV_STATE_FILE:-}" && -s "${PREV_STATE_FILE:-}" ]] || return 0
  awk -F'\t' -v k="$1" '$1==k{print $2; exit}' "$PREV_STATE_FILE"
}

header_value() {
  # $1 = 標頭檔, $2 = 標頭名稱。跟隨轉址時會有多組標頭，取最後一組（即最終回應）的值。
  grep -i "^$2:" "$1" 2>/dev/null | tail -1 | sed -E "s/^[^:]+:[[:space:]]*//" | tr -d '\r'
}

curl_source() {
  # $1 name, $2 url, $3 是否帶條件式標頭（1/0）
  # 內容寫入 raw_<name>.txt、標頭寫入 hdr_<name>.txt，HTTP 狀態碼輸出到 stdout
  local name="$1" url="$2" conditional="$3"
  local -a hdrs=()
  if [[ "$conditional" == "1" ]]; then
    local et lm
    et=$(state_get "etag:$name")
    lm=$(state_get "lastmod:$name")
    [[ -n "$et" ]] && hdrs+=(-H "If-None-Match: $et")
    [[ -n "$lm" ]] && hdrs+=(-H "If-Modified-Since: $lm")
  fi
  curl -sSL --retry 3 --retry-all-errors --max-time 60 \
    -A "cloudflare-gateway-block-ads-sync/1.0" \
    "${hdrs[@]}" \
    -D "$TMP_DIR/hdr_$name.txt" -o "$TMP_DIR/raw_$name.txt" \
    -w '%{http_code}' "$url" 2>/dev/null
}

parse_source_into() {
  # $1 name, $2 format；解析 raw_<name>.txt → parsed_<name>.txt，並寫出 sum_<name>.txt
  local name="$1" format="$2"
  local raw_file="$TMP_DIR/raw_$name.txt" parsed_file="$TMP_DIR/parsed_$name.txt"
  case "$format" in
    domains) parse_domains < "$raw_file" > "$parsed_file" ;;
    adblock) parse_adblock < "$raw_file" > "$parsed_file" ;;
    hosts)   parse_hosts   < "$raw_file" > "$parsed_file" ;;
    *) return 1 ;;
  esac
  sha256sum < "$parsed_file" | awk '{print $1}' > "$TMP_DIR/sum_$name.txt"
}

fetch_and_merge_sources() {
  # 副作用（供 checksum 閘門使用）：
  #   $TMP_DIR/sum_<name>.txt        該來源解析後輸出的 sha256
  #   $TMP_DIR/failed_sources.txt    每行一個抓取/解析失敗的來源名
  #   $TMP_DIR/notmodified.txt       回應 304 的來源（name<TAB>format），內容尚未下載
  #   $TMP_DIR/newmeta.txt           name<TAB>etag<TAB>lastmod，供下次條件式請求使用
  #
  # checksum 刻意算在「解析後的網域輸出」而不是下載到的原始檔上。原因是幾乎每個
  # 上游清單都帶會變動的檔頭，例如：
  #   easylist        ! Version: 202608300930   ← 內含時間戳，每次重建就變
  #   ublock-privacy  ! Last modified: ... / ! Diff-Path: ../patches/2026.8.30.393.patch
  #   AdGuard-DNS     ! Version: 1.0.77.58
  # 規則一條都沒改、檔頭照樣變，對原始位元組算 checksum 會導致每小時都判定為
  # 「有變動」，閘門形同虛設。解析後的輸出已經濾掉所有 ! 註解，才真正反映規則異動。
  : > "$TMP_DIR/failed_sources.txt"
  : > "$TMP_DIR/notmodified.txt"
  : > "$TMP_DIR/newmeta.txt"
  : > "$TMP_DIR/source_list.txt"

  local total_sources n=0
  total_sources=$(grep -cvE '^[[:space:]]*(#|$)' "$SOURCES_FILE" | xargs)
  local n_304=0 n_200=0
  while IFS='|' read -r name url format; do
    # 跳過空行與註解
    [[ -z "$name" || "$name" =~ ^[[:space:]]*# ]] && continue
    name="$(echo "$name" | xargs)"
    url="$(echo "$url" | xargs)"
    format="$(echo "$format" | xargs)"
    printf '%s\t%s\t%s\n' "$name" "$url" "$format" >> "$TMP_DIR/source_list.txt"
    n=$((n + 1))

    local code
    code=$(curl_source "$name" "$url" 1)

    case "$code" in
      304)
        # 內容未變，伺服器沒回傳 body。沿用前次 checksum，內容等到確定要完整同步才補抓。
        local prev_sum
        prev_sum=$(state_get "src:$name")
        if [[ -z "$prev_sum" ]]; then
          # 理論上不會發生（有 ETag 就該有 checksum）；保險起見改成無條件重抓
          warn "[$n/$total_sources] $name 回應 304 但沒有前次 checksum，改用無條件請求重抓"
          code=$(curl_source "$name" "$url" 0)
        else
          echo "$prev_sum" > "$TMP_DIR/sum_$name.txt"
          printf '%s\t%s\n' "$name" "$format" >> "$TMP_DIR/notmodified.txt"
          n_304=$((n_304 + 1))
          log "[$n/$total_sources] $name 304 未修改，沿用前次 checksum（未下載內容）"
          continue
        fi
        ;;
    esac

    # 上面的 304 分支可能已經改寫過 code（重抓），所以這裡重新判斷一次
    case "$code" in
      200) : ;;
      *)
        warn "[$n/$total_sources] $name 抓取失敗（HTTP $code），略過此來源"
        echo "$name" >> "$TMP_DIR/failed_sources.txt"
        continue
        ;;
    esac

    if ! parse_source_into "$name" "$format"; then
      warn "[$n/$total_sources] $name 未知格式 '$format'，略過"
      echo "$name" >> "$TMP_DIR/failed_sources.txt"
      continue
    fi

    # 記下這次的驗證標頭，下次就能用條件式請求省下整包下載
    printf '%s\t%s\t%s\n' "$name" \
      "$(header_value "$TMP_DIR/hdr_$name.txt" 'ETag')" \
      "$(header_value "$TMP_DIR/hdr_$name.txt" 'Last-Modified')" >> "$TMP_DIR/newmeta.txt"

    n_200=$((n_200 + 1))
    log "[$n/$total_sources] $name 解析出 $(wc -l < "$TMP_DIR/parsed_$name.txt" | xargs) 筆網域（checksum $(cut -c1-12 < "$TMP_DIR/sum_$name.txt")）"
  done < "$SOURCES_FILE"

  log "來源抓取完成：$n_200 個有更新、$n_304 個回應 304 未修改、$(wc -l < "$TMP_DIR/failed_sources.txt" | xargs) 個失敗"
}

materialize_sources() {
  # 確定要完整同步時才呼叫：把先前回應 304、因此沒有下載內容的來源改用無條件請求補抓。
  # 閘門階段之所以不抓，是因為大多數執行最後都會略過，那些下載就是純浪費。
  [[ -s "$TMP_DIR/notmodified.txt" ]] || return 0
  local name format url code
  while IFS=$'\t' read -r name format; do
    [[ -n "$name" ]] || continue
    url=$(awk -F'\t' -v n="$name" '$1==n{print $2; exit}' "$TMP_DIR/source_list.txt")
    log "補抓 304 來源的內容：$name"
    code=$(curl_source "$name" "$url" 0)
    if [[ "$code" != "200" ]] || ! parse_source_into "$name" "$format"; then
      warn "[$name] 補抓失敗（HTTP $code），本次合併會缺少這個來源的網域"
      echo "$name" >> "$TMP_DIR/failed_sources.txt"
      rm -f "$TMP_DIR/sum_$name.txt"
      continue
    fi
    printf '%s\t%s\t%s\n' "$name" \
      "$(header_value "$TMP_DIR/hdr_$name.txt" 'ETag')" \
      "$(header_value "$TMP_DIR/hdr_$name.txt" 'Last-Modified')" >> "$TMP_DIR/newmeta.txt"
  done < "$TMP_DIR/notmodified.txt"
}

collect_source_checksums() {
  # 把各來源的 sum_<name>.txt 收攏成一份「name<TAB>checksum」供閘門比對
  : > "$TMP_DIR/source_checksums.txt"
  local name
  while IFS=$'\t' read -r name _ _; do
    [[ -n "$name" && -s "$TMP_DIR/sum_$name.txt" ]] || continue
    printf '%s\t%s\n' "$name" "$(cat "$TMP_DIR/sum_$name.txt")" >> "$TMP_DIR/source_checksums.txt"
  done < "$TMP_DIR/source_list.txt"
}

build_merged() {
  # 把所有已解析的來源合併去重
  cat "$TMP_DIR"/parsed_*.txt 2>/dev/null | sort -u
}

emit_meta_state() {
  # 由 newmeta.txt 產出 sync_state 需要的 etag:/lastmod: 項目。
  # 回應 304 的來源不會出現在 newmeta.txt —— 它們在 D1 裡的既有值會原封不動保留，
  # 因為 save_sync_state 是 upsert，只會動到有給的 key。
  [[ -s "$TMP_DIR/newmeta.txt" ]] || return 0
  awk -F'\t' '{
    if (length($2)) print "etag:" $1 "\t" $2
    if (length($3)) print "lastmod:" $1 "\t" $3
  }' "$TMP_DIR/newmeta.txt"
}

checksum_of_lines() {
  # 讀 stdin，排序去重後算 sha256。用在白名單/自訂封鎖清單上，
  # 讓「同樣的內容但查詢回傳順序不同」不會被誤判成有變動。
  sort -u | sha256sum | awk '{print $1}'
}

decide_should_sync() {
  # 比對本次算出的 checksum 與 sync_state 中的前次值，決定要不要繼續完整同步。
  # 回傳 0 = 要同步；1 = 可以略過。
  # $1 = 前次狀態檔（key<TAB>value）, $2 = 白名單 checksum, $3 = 自訂封鎖清單 checksum
  # 輸出（stdout）：一行變動原因摘要，供記錄用
  local prev_file="$1" wl_sum="$2" bl_sum="$3"

  if [[ "$FORCE_SYNC" == "1" ]]; then
    echo "FORCE_SYNC=1，略過閘門強制同步"
    return 0
  fi
  if [[ $STATE_AVAILABLE -ne 1 ]]; then
    echo "狀態表不可用，退回完整同步"
    return 0
  fi
  if [[ ! -s "$prev_file" ]]; then
    echo "沒有先前的 checksum 紀錄（首次啟用閘門）"
    return 0
  fi

  # 抓取失敗的來源不列入比對：它這次沒有新的 checksum，若當成「有變動」會導致
  # 上游暫時掛掉時反而觸發同步，把缺了該來源的清單推上去。維持略過才是安全的
  # 那一邊 —— Gateway 上會保留前一次完整的清單。
  local changed
  # 三個輸入檔依序是：前次狀態（key 已含 src: 前綴）、本次抓取失敗的來源、本次 checksum
  changed=$(awk -F'\t' '
    NR==FNR            { prev[$1] = $2; next }
    FILENAME == ARGV[2] { failed[$1] = 1; next }
    {
      if ($1 in failed) next
      key = "src:" $1
      if (!(key in prev))  { print "新增來源 " $1; next }
      if (prev[key] != $2) { print "來源內容變動 " $1 }
    }
  ' "$prev_file" "$TMP_DIR/failed_sources.txt" "$TMP_DIR/source_checksums.txt")

  local prev_wl prev_bl
  prev_wl=$(awk -F'\t' '$1=="whitelist"{print $2}' "$prev_file")
  prev_bl=$(awk -F'\t' '$1=="blocklist"{print $2}' "$prev_file")
  [[ "$prev_wl" != "$wl_sum" ]] && changed="${changed}${changed:+$'\n'}白名單有變動"
  [[ "$prev_bl" != "$bl_sum" ]] && changed="${changed}${changed:+$'\n'}自訂封鎖清單有變動"

  if [[ $DEFERRED_BACKLOG -gt 0 && $(d1_budget_left) -gt 0 ]]; then
    changed="${changed}${changed:+$'\n'}有 $DEFERRED_BACKLOG 筆積欠的分類快取待補寫"
  fi

  if [[ -n "$changed" ]]; then
    echo "$changed" | paste -sd'；' -
    return 0
  fi
  return 1
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

kv_get_to_file() {
  # $1 = key, $2 = 輸出檔。HTTP 狀態碼印到 stdout（連不上時 curl 會給 000）。
  local key="$1" out="$2"
  curl -sS -o "$out" -w '%{http_code}' \
    -H "Authorization: Bearer $CF_API_TOKEN" \
    "$CF_API/accounts/$CF_ACCOUNT_ID/storage/kv/namespaces/$KV_NAMESPACE_ID/values/$key" \
    2>/dev/null || echo "000"
}

kv_put_from_file() {
  # $1 = key, $2 = 輸入檔。回應 JSON 印到 stdout。
  # 用 --data-binary 送原始位元組；不要用 -F，那會把整包 multipart 當成值存進去。
  local key="$1" in="$2"
  curl -sS -X PUT \
    -H "Authorization: Bearer $CF_API_TOKEN" \
    -H "Content-Type: application/octet-stream" \
    --data-binary "@$in" \
    "$CF_API/accounts/$CF_ACCOUNT_ID/storage/kv/namespaces/$KV_NAMESPACE_ID/values/$key"
}

_load_cache_from_kv() {
  # $1 = cutoff。成功時把「domain\tis_ads\tchecked_at」寫進 $TMP_DIR/cache_full.tsv 並回傳 0。
  local cutoff="$1"
  local gz="$TMP_DIR/kv_cache.gz" raw="$TMP_DIR/kv_cache.tsv" code

  code=$(kv_get_to_file "$KV_CACHE_KEY" "$gz")
  case "$code" in
    200) ;;
    404)
      log "KV 上還沒有分類快取快照（第一次啟用），本次改讀 D1，結束前會建立快照"
      return 1 ;;
    *)
      warn "KV 讀取分類快取失敗（HTTP $code），退回讀 D1"
      return 1 ;;
  esac

  # gunzip 在內容被截斷或根本不是 gzip 時會失敗，等於免費得到一次完整性檢查
  if ! gunzip -c "$gz" > "$raw" 2>/dev/null; then
    warn "KV 快照解壓失敗（可能是上次寫入不完整），退回讀 D1，結束前會重建快照"
    return 1
  fi
  if [[ ! -s "$raw" ]]; then
    warn "KV 快照是空的，退回讀 D1，結束前會重建快照"
    return 1
  fi

  # 格式檢查與 TTL 過濾一次做完。發現任何一行不符三欄格式就整份不採信 ——
  # 快照是衍生資料，寧可退回 D1 重建，也不要拿半信半疑的內容去決定要不要擋一個網域。
  if ! awk -F'\t' -v cutoff="$cutoff" '
         NF != 3 || $3 !~ /^[0-9]+$/ { bad = 1; exit }
         $3 >= cutoff { print }
         END { if (bad) exit 3 }
       ' "$raw" > "$TMP_DIR/cache_full.tsv"; then
    warn "KV 快照格式不符預期，退回讀 D1，結束前會重建快照"
    return 1
  fi

  log "分類快取來源：KV 快照（$(wc -c < "$gz" | xargs) bytes 壓縮，未過期 $(wc -l < "$TMP_DIR/cache_full.tsv" | xargs) 筆），本次不讀 D1 快取表"
  return 0
}

_load_cache_from_d1() {
  # $1 = cutoff。這是全表掃描（約 46 萬列），只在 KV 不可用時才會走到。
  local cutoff="$1" resp
  resp=$(d1_query "SELECT domain, is_ads_category, checked_at FROM domain_category_cache WHERE checked_at >= ?" \
    "$(jq -n --arg c "$cutoff" '[$c]')")
  if ! is_valid_json <<< "$resp" || [[ "$(jq -r '.success' <<< "$resp")" != "true" ]]; then
    warn "讀取分類快取失敗，本次視為無快取，將重新查詢全部網域"
    : > "$TMP_DIR/cache_full.tsv"
    return 1
  fi
  jq -r '.result[0].results[]? | "\(.domain)\t\(.is_ads_category)\t\(.checked_at)"' <<< "$resp" \
    > "$TMP_DIR/cache_full.tsv"
  log "分類快取來源：D1 全表掃描（$(wc -l < "$TMP_DIR/cache_full.tsv" | xargs) 筆）"
  return 0
}

load_category_cache() {
  # 輸出到 stdout：每行「domain is_ads_category」（空白分隔，維持下游既有的欄位語意）。
  # 副作用：把含 checked_at 的完整三欄內容留在 $TMP_DIR/cache_full.tsv，供結束前重建 KV 快照用。
  local cutoff
  cutoff=$(( $(date +%s) - CACHE_TTL_DAYS * 86400 ))
  : > "$TMP_DIR/cache_full.tsv"

  if [[ "$KV_ENABLED" == "1" && "$REBUILD_CACHE_BLOB" != "1" ]] && _load_cache_from_kv "$cutoff"; then
    CACHE_SOURCE="kv"
  else
    if [[ "$REBUILD_CACHE_BLOB" == "1" ]]; then
      log "REBUILD_CACHE_BLOB=1：略過 KV 快照，直接從 D1 重讀並重建"
    fi
    if _load_cache_from_d1 "$cutoff"; then CACHE_SOURCE="d1"; else CACHE_SOURCE="none"; fi
  fi

  awk -F'\t' '{print $1, $2}' "$TMP_DIR/cache_full.tsv"
}

save_category_cache_blob() {
  # $1 = 本次新查到的結果檔（domain\tis_ads\tcategories_json），可以是空的或不存在。
  # 把「這次載入後仍有效的快取 + 本次新查到的」合併成新快照寫回 KV。
  [[ "$KV_ENABLED" == "1" ]] || return 0

  local fresh="${1:-}" now blob="$TMP_DIR/cache_blob.tsv" gz="$TMP_DIR/cache_blob.tsv.gz"
  local fresh_rows=0
  [[ -s "$fresh" ]] && fresh_rows=$(wc -l < "$fresh" | xargs)

  # 沒有新資料、而且這次本來就是讀 KV 讀成功的，快照內容不會有實質變化，
  # 就不要白白多寫一次 KV。反過來說只要是從 D1 讀的（第一次啟用或快照壞掉），
  # 一定要寫回去，否則下次還是得再掃一次全表。
  if [[ "$CACHE_SOURCE" == "kv" && "$fresh_rows" -eq 0 ]]; then
    log "分類快取無新增，KV 快照維持不變"
    return 0
  fi
  if [[ "$CACHE_SOURCE" == "none" ]]; then
    warn "本次沒有可信的快取來源，不覆寫 KV 快照（避免用殘缺內容蓋掉好的快照）"
    return 0
  fi

  now=$(date +%s)
  # 新查到的放前面、既有的放後面，再用 awk 取每個網域第一次出現的那筆 ——
  # 這樣同一個網域若同時出現在兩邊，會以本次剛查到的結果為準。
  {
    [[ "$fresh_rows" -gt 0 ]] && awk -F'\t' -v now="$now" 'NF >= 2 {print $1 "\t" $2 "\t" now}' "$fresh"
    cat "$TMP_DIR/cache_full.tsv"
  } | awk -F'\t' '!seen[$1]++' | sort -t"$(printf '\t')" -k1,1 > "$blob"

  CACHE_BLOB_ROWS=$(wc -l < "$blob" | xargs)
  gzip -c "$blob" > "$gz"
  CACHE_BLOB_BYTES=$(wc -c < "$gz" | xargs)

  if [[ "$CACHE_BLOB_BYTES" -ge "$KV_MAX_BYTES" ]]; then
    warn "分類快取快照壓縮後 $CACHE_BLOB_BYTES bytes，已超過 KV 單值上限 $KV_MAX_BYTES，放棄寫入（下次同步會退回讀 D1）"
    return 0
  fi
  if [[ "$CACHE_BLOB_BYTES" -ge "$KV_WARN_BYTES" ]]; then
    warn "分類快取快照壓縮後 $CACHE_BLOB_BYTES bytes，正在逼近 KV 單值上限 $KV_MAX_BYTES，該考慮縮短 CACHE_TTL_DAYS 或改用 R2"
  fi

  local resp
  resp=$(kv_put_from_file "$KV_CACHE_KEY" "$gz")
  if is_valid_json <<< "$resp" && [[ "$(jq -r '.success' <<< "$resp")" == "true" ]]; then
    log "KV 快照已更新：$CACHE_BLOB_ROWS 筆（新增 $fresh_rows），壓縮後 $CACHE_BLOB_BYTES bytes"
  else
    warn "KV 快照寫入失敗，下次同步會退回讀 D1 全表（不影響本次結果）"
    CACHE_BLOB_ROWS=0
    CACHE_BLOB_BYTES=0
  fi
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
    local budget_left
    budget_left=$(d1_budget_left)
    if [[ $budget_left -le 0 ]]; then
      local remaining=$((total_lines - start + 1))
      DEFERRED_CACHE_ROWS=$((DEFERRED_CACHE_ROWS + remaining))
      warn "今日（$D1_DAY UTC）D1 寫入量已達上限（$D1_DAILY_WRITE_BUDGET 筆），停止寫入分類快取。剩餘 $remaining 筆延後到明天：額度在 UTC 午夜重置，之後第一次執行會自動重查並補寫。封鎖清單本身不受影響，本次仍照常上傳。"
      break
    fi

    local sub_chunk_file="$TMP_DIR/cache_write_chunk.txt"
    sed -n "${start},$((start + write_chunk_size - 1))p" "$batch_file" > "$sub_chunk_file"
    local this_chunk_size
    this_chunk_size=$(wc -l < "$sub_chunk_file" | xargs)

    # 如果這一批會超出剩餘額度，只取額度容得下的部分，其餘計入延後
    if [[ $this_chunk_size -gt $budget_left ]]; then
      head -n "$budget_left" "$sub_chunk_file" > "${sub_chunk_file}.trimmed"
      mv "${sub_chunk_file}.trimmed" "$sub_chunk_file"
      DEFERRED_CACHE_ROWS=$((DEFERRED_CACHE_ROWS + this_chunk_size - budget_left))
      this_chunk_size=$budget_left
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
    case "$(echo "$resp" | jq -r '.success // false')" in
      true)
        D1_WRITES_ADDED=$((D1_WRITES_ADDED + this_chunk_size))
        ;;
      *)
        warn "寫入分類快取第 $start~$((start + write_chunk_size)) 批失敗，略過（不影響本次結果，只影響下次快取命中率）"
        DEFERRED_CACHE_ROWS=$((DEFERRED_CACHE_ROWS + this_chunk_size))
        ;;
    esac

    local written=$(( start + this_chunk_size - 1 ))
    [[ $written -gt $total_lines ]] && written=$total_lines
    log "  寫入分類快取進度 $written/$total_lines（今日 D1 用量 $((D1_WRITES_TODAY + D1_WRITES_ADDED))/$D1_DAILY_WRITE_BUDGET）"

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

    # 先把回應歸成單一分類再用 case 分派（取代原本的 if-elif-else 鏈）
    local resp_kind
    if ! is_valid_json <<< "$resp"; then
      resp_kind="invalid_json"
    else
      case "$(jq -r '.success // false' <<< "$resp")" in
        true) resp_kind="ok" ;;
        *)    resp_kind="failed" ;;
      esac
    fi

    case "$resp_kind" in
      invalid_json)
        warn "[worker $worker_id] 第 $i~$((i+BULK_BATCH_SIZE)) 批分類查詢回應不是合法 JSON（可能是暫時性網路問題或速率限制），這批網域本次視為『未被原生分類涵蓋』（保守處理，寧可多上傳也不要漏擋）"
        awk '{print $1, 0}' "$batch_file" >> "$out_file"
        ;;
      failed)
        warn "[worker $worker_id] 第 $i~$((i+BULK_BATCH_SIZE)) 批分類查詢失敗，這批網域本次視為『未被原生分類涵蓋』（保守處理，寧可多上傳也不要漏擋）"
        awk '{print $1, 0}' "$batch_file" >> "$out_file"
        ;;
      ok)
        jq -r '.result[]? |
        [.domain, (if ([.content_categories[]?.name] | any(. == "Advertisements" or . == "Trackers/Analytics")) then 1 else 0 end),
         ([.content_categories[]?.name] | tostring)] | @tsv' <<< "$resp" \
          | while IFS=$'\t' read -r domain is_ads cats; do
              echo "$domain $is_ads" >> "$out_file"
              echo -e "$domain\t$is_ads\t$cats" >> "$cache_batch_file"
            done
        ;;
    esac

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

# ── 穩定槽位（stable slot）清單模型 ─────────────────────
# 舊模型是「排序後每 1000 筆連續切片」，缺點是只要有一個網域增減，它之後的每一份
# 清單內容都會位移一格，於是全部被判定為需要重傳。實測移除一個位於第 ~144,000 位
# 的網域，就讓第 145~224 份全部重傳。
#
# 新模型把每份清單當成一個「槽位」：
#   - 移除網域 → 只從它所在的那一份拿掉，該份留下空缺，其他份完全不動
#   - 新增網域 → 優先填進編號最小、還有空缺的槽位，填滿了才開新的
# 於是「移除一個網域」只會重傳一份清單。
#
# 成員資料直接向 Cloudflare 讀取，不另外存一份：它是權威來源、能自我修復
# （有人手動改過清單也會被看見），而且同時涵蓋了中斷續傳 —— 上次沒傳完的狀態，
# 這裡讀到的就是未完成的實況，這次自然會把差額補上。
# 代價是清單內容會逐漸失去字母序，對封鎖行為沒有影響。

fetch_slot_membership() {
  # 讀回每份既有清單目前的成員 → $TMP_DIR/slot/<idx>.txt（已排序）
  # 同時輸出 $TMP_DIR/slot_ids.txt（idx<TAB>list_id）
  mkdir -p "$TMP_DIR/slot"
  : > "$TMP_DIR/slot_ids.txt"

  local id name idx
  while read -r id name; do
    idx=$(echo "$name" | grep -oE '[0-9]+$' | sed 's/^0*//')
    [[ -n "$idx" ]] && printf '%s\t%s\n' "$idx" "$id" >> "$TMP_DIR/slot_ids.txt"
  done < <(get_existing_lists)

  local total
  total=$(wc -l < "$TMP_DIR/slot_ids.txt" | xargs)
  if [[ $total -eq 0 ]]; then
    log "Gateway 上還沒有任何清單，全部視為新建"
    return 0
  fi

  log "讀取現有清單成員：共 $total 份"
  local running=0 done_n=0
  while IFS=$'\t' read -r idx id; do
    {
      # 每份清單上限就是 LIST_CHUNK_SIZE 筆，一頁取完，不需要分頁
      cf_curl GET "/accounts/$CF_ACCOUNT_ID/gateway/lists/$id/items?per_page=$LIST_CHUNK_SIZE" \
        | jq -r '.result[]?.value // empty' | sort -u > "$TMP_DIR/slot/$idx.txt"
    } &
    running=$((running + 1))
    if [[ $running -ge $SLOT_FETCH_PARALLEL ]]; then
      wait -n 2>/dev/null || wait
      running=$((running - 1))
      done_n=$((done_n + 1))
      if [[ $((done_n % 40)) -eq 0 ]]; then log "  讀取進度 $done_n/$total"; fi
    fi
  done < "$TMP_DIR/slot_ids.txt"
  wait
  log "  讀取進度 $total/$total（完成）"
}

plan_slot_changes() {
  # $1 = 目標網域清單（已排序去重）
  # 產生 $TMP_DIR/newslot/<idx>.txt、changed_slots.txt、empty_slots.txt、slot_indices.txt
  local desired="$1"
  mkdir -p "$TMP_DIR/newslot"
  : > "$TMP_DIR/changed_slots.txt"
  : > "$TMP_DIR/empty_slots.txt"

  local idx_list="$TMP_DIR/slot_indices.txt"
  cut -f1 "$TMP_DIR/slot_ids.txt" 2>/dev/null | sort -n > "$idx_list"

  local current_all="$TMP_DIR/current_all.txt"
  cat "$TMP_DIR/slot"/*.txt 2>/dev/null | sort -u > "$current_all"

  local to_remove="$TMP_DIR/to_remove.txt" to_add="$TMP_DIR/to_add.txt"
  comm -23 "$current_all" "$desired" > "$to_remove"
  comm -13 "$current_all" "$desired" > "$to_add"
  log "與 Gateway 現況比對：需移除 $(wc -l < "$to_remove" | xargs) 筆、需新增 $(wc -l < "$to_add" | xargs) 筆"

  # 第一步：各槽位先拿掉要移除的網域，空出來的位置留著不動其他槽位
  local idx
  while read -r idx; do
    [[ -n "$idx" ]] || continue
    comm -23 "$TMP_DIR/slot/$idx.txt" "$to_remove" > "$TMP_DIR/newslot/$idx.txt"
  done < "$idx_list"

  # 第二步：新增的網域優先遞補編號最小、還有空缺的槽位
  local remaining="$TMP_DIR/remaining_add.txt"
  cp "$to_add" "$remaining"
  local filled_slots=0
  while read -r idx; do
    [[ -s "$remaining" ]] || break
    [[ -n "$idx" ]] || continue
    local cnt free
    cnt=$(wc -l < "$TMP_DIR/newslot/$idx.txt" | xargs)
    free=$((LIST_CHUNK_SIZE - cnt))
    [[ $free -gt 0 ]] || continue
    head -n "$free" "$remaining" >> "$TMP_DIR/newslot/$idx.txt"
    sort -u -o "$TMP_DIR/newslot/$idx.txt" "$TMP_DIR/newslot/$idx.txt"
    tail -n +"$((free + 1))" "$remaining" > "$remaining.tmp" && mv "$remaining.tmp" "$remaining"
    filled_slots=$((filled_slots + 1))
  done < "$idx_list"
  if [[ $filled_slots -gt 0 ]]; then log "  有 $filled_slots 份清單的空缺被新網域遞補"; fi

  # 第三步：還有剩的才開新槽位
  local next_idx new_slots=0 last_idx
  last_idx=$(tail -1 "$idx_list" 2>/dev/null)
  next_idx=$(( ${last_idx:-0} + 1 ))
  while [[ -s "$remaining" ]]; do
    head -n "$LIST_CHUNK_SIZE" "$remaining" | sort -u > "$TMP_DIR/newslot/$next_idx.txt"
    echo "$next_idx" >> "$idx_list"
    tail -n +"$((LIST_CHUNK_SIZE + 1))" "$remaining" > "$remaining.tmp" && mv "$remaining.tmp" "$remaining"
    next_idx=$((next_idx + 1))
    new_slots=$((new_slots + 1))
  done
  if [[ $new_slots -gt 0 ]]; then log "  新增了 $new_slots 份清單容納放不下的網域"; fi

  # 第四步：標記真正有變動的槽位，以及變成空的槽位
  while read -r idx; do
    [[ -n "$idx" ]] || continue
    local newf="$TMP_DIR/newslot/$idx.txt" oldf="$TMP_DIR/slot/$idx.txt"
    if [[ ! -s "$newf" ]]; then
      echo "$idx" >> "$TMP_DIR/empty_slots.txt"
      continue
    fi
    if [[ ! -f "$oldf" ]] || ! cmp -s "$newf" "$oldf"; then
      echo "$idx" >> "$TMP_DIR/changed_slots.txt"
    fi
  done < "$idx_list"
}

sync_slots() {
  # 只上傳內容真的變了的槽位；輸出所有有效清單的 id 供 Policy 引用
  local idx_list="$TMP_DIR/slot_indices.txt"
  local total changed
  total=$(grep -c . "$idx_list" 2>/dev/null || echo 0)
  changed=$(grep -c . "$TMP_DIR/changed_slots.txt" 2>/dev/null || echo 0)
  UPLOAD_STAT_TOTAL=$total
  log "清單總數 $total 份，其中 $changed 份需要上傳"

  declare -A slot_id
  local idx id
  while IFS=$'\t' read -r idx id; do slot_id[$idx]="$id"; done < "$TMP_DIR/slot_ids.txt"

  local list_ids_file="$TMP_DIR/list_ids.txt"
  : > "$list_ids_file"
  local n=0 n_up=0 n_skip=0 n_fail=0

  while read -r idx; do
    [[ -n "$idx" ]] || continue
    n=$((n + 1))
    local existing_id="${slot_id[$idx]:-}"

    # 這一份沒有變動就不重傳，直接沿用既有 id
    if ! grep -qx "$idx" "$TMP_DIR/changed_slots.txt" 2>/dev/null; then
      if [[ -n "$existing_id" ]]; then echo "$existing_id" >> "$list_ids_file"; fi
      n_skip=$((n_skip + 1))
      continue
    fi

    local name items_json body chunk_file
    chunk_file="$TMP_DIR/newslot/$idx.txt"
    name=$(printf "%s - %03d" "$LIST_PREFIX" "$idx")
    items_json=$(jq -R -s -c 'split("\n") | map(select(length > 0)) | map({value: .})' "$chunk_file")
    body=$(jq -n --arg name "$name" --argjson items "$items_json" '{name: $name, type: "DOMAIN", items: $items}')

    local resp resp_raw http_status list_id attempt upload_ok=0
    for attempt in 1 2 3; do
      case "$existing_id" in
        "") resp_raw=$(cf_curl_with_status POST "/accounts/$CF_ACCOUNT_ID/gateway/lists" "$body") ;;
        *)  resp_raw=$(cf_curl_with_status PUT "/accounts/$CF_ACCOUNT_ID/gateway/lists/$existing_id" "$body") ;;
      esac
      resp="${resp_raw%__HTTP_STATUS__*}"
      http_status="${resp_raw##*__HTTP_STATUS__}"

      if is_valid_json <<< "$resp" && [[ "$(jq -r '.success' <<< "$resp")" == "true" ]]; then
        list_id="${existing_id:-$(jq -r '.result.id' <<< "$resp")}"
        upload_ok=1
        break
      fi
      warn "清單 $name 第 $attempt 次上傳失敗（HTTP $http_status）"
      if [[ $attempt -lt 3 ]]; then sleep $((attempt * 2)); fi
    done

    local affected
    affected=$(wc -l < "$chunk_file" | xargs)
    case "$upload_ok" in
      1)
        echo "$list_id" >> "$list_ids_file"
        n_up=$((n_up + 1))
        log "[$n/$total] $name 已上傳（$affected 筆）"
        ;;
      *)
        n_fail=$((n_fail + 1))
        # 上傳失敗但清單本來就存在的話，Gateway 上仍是上一次的內容。讓 Policy 繼續
        # 引用它，比整份拿掉（等於那些網域全部解除封鎖）安全得多。下次執行會再從
        # Cloudflare 讀到實況，自動判定需要重傳。
        case "$existing_id" in
          "") warn "[$n/$total] $name 上傳失敗，且是新清單沒有舊版可用，這 $affected 筆本次不會被涵蓋" ;;
          *)  echo "$existing_id" >> "$list_ids_file"
              warn "[$n/$total] $name 上傳失敗，保留 Gateway 上的舊內容並繼續引用（下次自動重傳這 $affected 筆）" ;;
        esac
        ;;
    esac
  done < "$idx_list"

  # 變成空的槽位就刪掉，編號留著日後重用
  local eidx eid
  while read -r eidx; do
    [[ -n "$eidx" ]] || continue
    eid="${slot_id[$eidx]:-}"
    [[ -n "$eid" ]] || continue
    if cf_curl DELETE "/accounts/$CF_ACCOUNT_ID/gateway/lists/$eid" > /dev/null; then
      log "清單編號 $eidx 已無任何網域，刪除（編號保留給日後重用）"
    else
      warn "刪除空清單（編號 $eidx）失敗（不影響本次結果）"
    fi
  done < "$TMP_DIR/empty_slots.txt"

  UPLOAD_STAT_UPLOADED=$n_up
  UPLOAD_STAT_SKIPPED=$n_skip
  UPLOAD_STAT_FAILED=$n_fail
  log "上傳統計：新上傳 $n_up 份／內容未變略過 $n_skip 份／失敗 $n_fail 份（共 $total 份）"

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
  if d1_query \
      "INSERT INTO sync_history (run_at, total_merged, total_uploaded, total_excluded_by_native_category, total_whitelisted, status, notes) VALUES (?, ?, ?, ?, ?, ?, ?)" \
      "$params" | d1_ok; then
    D1_WRITES_ADDED=$((D1_WRITES_ADDED + 1))
  else
    warn "寫入同步歷史紀錄失敗（不影響本次同步結果本身）"
  fi
}

write_step_summary() {
  # 把結果寫成 GitHub Actions 的 Job Summary（Actions 頁面上直接看得到的表格），
  # 不在 Actions 環境下執行時（例如本機手動跑）就靜靜跳過。
  # $1 status, $2 total_merged, $3 total_uploaded, $4 原因說明
  [[ -n "${GITHUB_STEP_SUMMARY:-}" ]] || return 0
  local status="$1" merged="$2" uploaded="$3" reason="$4"
  {
    echo "## 擋廣告清單同步結果"
    echo
    if [[ "$status" == "skipped" ]]; then
      echo "⏭️ **本次略過** — ${reason:-訂閱來源與白名單皆無變動}"
      echo
      echo "| 項目 | 數值 |"
      echo "|---|---|"
      echo "| 來源合併後網域數 | $merged |"
      echo "| 對 Cloudflare 的變更 | 無 |"
    else
      echo "✅ **同步完成** — $reason"
      echo
      echo "| 項目 | 數值 |"
      echo "|---|---|"
      echo "| 來源合併後網域數 | $merged |"
      echo "| 最終上傳網域數 | $uploaded |"
      echo "| 清單進度 | 上傳 $UPLOAD_STAT_UPLOADED／未變略過 $UPLOAD_STAT_SKIPPED／失敗 $UPLOAD_STAT_FAILED，共 $UPLOAD_STAT_TOTAL 份 |"
      echo "| 今日 D1 寫入用量 | $((D1_WRITES_TODAY + D1_WRITES_ADDED)) / $D1_DAILY_WRITE_BUDGET |"
      case "$CACHE_SOURCE" in
        kv) echo "| 分類快取來源 | KV 快照（未讀 D1 快取表）|" ;;
        d1) echo "| 分類快取來源 | ⚠️ D1 全表掃描（KV 快照不可用，已重建）|" ;;
        *)  echo "| 分類快取來源 | ⚠️ 無（讀取失敗，本次全部重查）|" ;;
      esac
      if [[ $CACHE_BLOB_BYTES -gt 0 ]]; then
        echo "| KV 快照 | $CACHE_BLOB_ROWS 筆／$((CACHE_BLOB_BYTES / 1024)) KiB |"
      fi
      if [[ $DEFERRED_CACHE_ROWS -gt 0 ]]; then
        echo "| 延後補寫的分類快取 | $DEFERRED_CACHE_ROWS 筆（UTC 午夜額度重置後自動補上） |"
      fi
    fi
    if [[ -s "$TMP_DIR/failed_sources.txt" ]]; then
      echo
      echo "⚠️ 這些訂閱來源本次抓取失敗，已沿用前次狀態："
      sed 's/^/- /' "$TMP_DIR/failed_sources.txt"
    fi
  } >> "$GITHUB_STEP_SUMMARY"
}

# ── 主流程 ───────────────────────────────────────────────

main() {
  log "開始同步"
  ensure_schema
  load_daily_budget

  # ── 閘門（需求 1、2）────────────────────────────────────
  # 先載入前次狀態（裡面有各來源的 ETag/Last-Modified），才能發條件式請求。
  PREV_STATE_FILE="$TMP_DIR/prev_state.txt"
  load_sync_state > "$PREV_STATE_FILE"
  DEFERRED_BACKLOG=$(awk -F'\t' '$1=="deferred_cache_rows"{print $2}' "$PREV_STATE_FILE")
  DEFERRED_BACKLOG=${DEFERRED_BACKLOG:-0}
  [[ $DEFERRED_BACKLOG -gt 0 ]] && log "上次遺留 $DEFERRED_BACKLOG 筆分類快取尚未補寫"

  # 抓取只用到上游 HTTP，不碰 Cloudflare；真正昂貴的是後面的分類查詢與清單上傳。
  # 帶 If-None-Match/If-Modified-Since，內容沒變的來源會回 304 而不傳 body。
  group_begin "抓取訂閱來源（條件式請求）"
  fetch_and_merge_sources
  collect_source_checksums
  group_end

  local whitelist_file="$TMP_DIR/whitelist.txt"
  load_whitelist > "$whitelist_file"
  local custom_block_file="$TMP_DIR/custom_block.txt"
  load_custom_blocklist > "$custom_block_file"

  # 白名單/自訂封鎖清單也納入閘門判斷。否則會出現這種狀況：使用者把某個誤擋的網域
  # 加進白名單，但上游來源剛好沒變動，同步就永遠不會觸發，白名單形同沒生效。
  local wl_sum bl_sum
  wl_sum=$(checksum_of_lines < "$whitelist_file")
  bl_sum=$(checksum_of_lines < "$custom_block_file")

  local sync_reason=""
  if sync_reason=$(decide_should_sync "$PREV_STATE_FILE" "$wl_sum" "$bl_sum"); then
    log "偵測到變動，執行完整同步 → $sync_reason"
  else
    log "所有訂閱來源、白名單與自訂封鎖清單的 checksum 都與上次相同，略過本次同步（完全沒有對 Cloudflare 做任何變更）"
    # 刻意不寫 sync_history：每小時塞一筆 skipped 會讓歷史表被雜訊淹沒
    # （一天 24 筆，查最近 N 筆時全是略過紀錄）。只更新一個時間戳記錄「有在檢查」，
    # sync_history 維持只保留真正執行過同步的紀錄。
    # 但驗證標頭一定要存：有些來源只是改了檔頭（解析後輸出不變），這次拿到新的
    # ETag 卻不存的話，下次又會整包下載一次。
    { printf 'last_check_at\t%s\n' "$(date +%s)"; emit_meta_state; } > "$TMP_DIR/check_state.txt"
    save_sync_state "$TMP_DIR/check_state.txt"
    save_daily_budget
    write_step_summary "skipped" "$(wc -l < "$TMP_DIR/source_list.txt" | xargs)" "0" "訂閱來源與白名單皆無變動，未進行同步"
    return 0
  fi

  # 確定要同步了，把先前回應 304 而沒下載內容的來源補抓回來
  materialize_sources
  collect_source_checksums
  local merged_file="$TMP_DIR/merged_domains.txt"
  build_merged > "$merged_file"
  local total_merged
  total_merged=$(wc -l < "$merged_file" | xargs)
  log "合併去重後總計：$total_merged 筆網域"

  if [[ $total_merged -eq 0 ]]; then
    echo "❌ 所有來源都沒有可用內容，中止本次同步避免清空 Gateway 清單" >&2
    record_sync_history "failed" "no source content" "0" "0" "0" "0"
    exit 1
  fi

  # 扣除白名單
  local after_whitelist_file="$TMP_DIR/after_whitelist.txt"
  # 白名單支援兩種寫法：
  #   example.com    → 精確比對，只放行這一筆（子網域仍照擋，例如 ads.youtube.com）
  #   *.example.com  → 後綴比對，放行其所有子網域（給會輪替的 CDN 主機名用，例如
  #                    r2.sn-xxxx.googlevideo.com 這類無法逐筆列舉的影片節點）
  awk 'NR==FNR {
         if (substr($0, 1, 2) == "*.") { suffix_wl[substr($0, 3)] = 1 }
         else if (length($0)) { exact_wl[$0] = 1 }
         next
       }
       {
         if ($0 in exact_wl) next
         rest = $0
         while ((dot = index(rest, ".")) > 0) {
           rest = substr(rest, dot + 1)
           if (rest in suffix_wl) next
         }
         print
       }' "$whitelist_file" "$merged_file" > "$after_whitelist_file"
  local whitelisted_count
  whitelisted_count=$(( total_merged - $(wc -l < "$after_whitelist_file" | xargs) ))
  log "扣除白名單 $whitelisted_count 筆"

  # 原生分類比對
  group_begin "Cloudflare 原生分類比對"
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

  # 把「仍有效的舊快取 + 本次新查到的」寫回 KV，下次同步就不必再掃 D1 全表。
  # 放在這裡而不是更早，是因為要等 check_native_categories 把新結果落地之後才有得合併。
  save_category_cache_blob "$TMP_DIR/cache_batch_merged.txt"

  # 扣掉已被原生分類涵蓋的網域（is_ads == 1）
  local ads_domains_file="$TMP_DIR/native_ads_domains.txt"
  awk '$2 == 1 {print $1}' "$TMP_DIR/all_categories.txt" | sort -u > "$ads_domains_file"

  local after_native_file="$TMP_DIR/after_native.txt"
  comm -23 "$after_whitelist_file" "$ads_domains_file" > "$after_native_file"
  local excluded_by_native
  excluded_by_native=$(( $(wc -l < "$after_whitelist_file" | xargs) - $(wc -l < "$after_native_file" | xargs) ))
  log "扣除已被 Cloudflare 原生 Ads 分類涵蓋的 $excluded_by_native 筆"
  group_end

  # 加上自訂封鎖清單（已在閘門階段載入，這裡直接沿用）
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

  # 穩定槽位：先讀回 Gateway 上每份清單目前的成員，算出「哪幾份真的要改」，
  # 只重傳那幾份。移除一個網域只會動到它所在的那一份。
  group_begin "同步 Gateway 清單"
  fetch_slot_membership
  plan_slot_changes "$final_file"
  local list_ids_file="$TMP_DIR/final_list_ids.txt"
  sync_slots > "$list_ids_file"
  group_end

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

  # 同步成功才把本次的 checksum 寫回。若中途失敗就不寫，下次執行自然會重跑，
  # 不會出現「狀態說已同步、實際上沒完成」的落差。
  local new_state_file="$TMP_DIR/new_state.txt"
  awk -F'\t' '{print "src:" $1 "\t" $2}' "$TMP_DIR/source_checksums.txt" > "$new_state_file"
  # 抓取失敗的來源沿用前次 checksum，避免下次把它誤判成「內容變動」
  if [[ -s "$TMP_DIR/failed_sources.txt" ]]; then
    awk -F'\t' 'NR==FNR { failed["src:" $1]=1; next } ($1 in failed) { print }' \
      "$TMP_DIR/failed_sources.txt" "$PREV_STATE_FILE" >> "$new_state_file"
  fi
  emit_meta_state >> "$new_state_file"
  printf 'whitelist\t%s\n' "$wl_sum" >> "$new_state_file"
  printf 'blocklist\t%s\n' "$bl_sum" >> "$new_state_file"
  printf 'deferred_cache_rows\t%s\n' "$DEFERRED_CACHE_ROWS" >> "$new_state_file"
  printf 'last_check_at\t%s\n' "$(date +%s)" >> "$new_state_file"
  save_sync_state "$new_state_file"
  save_daily_budget

  local notes=""
  [[ $DEFERRED_CACHE_ROWS -gt 0 ]] && notes="deferred_cache_rows=$DEFERRED_CACHE_ROWS"
  [[ ${UPLOAD_STAT_FAILED:-0} -gt 0 ]] && notes="${notes}${notes:+; }failed_lists=${UPLOAD_STAT_FAILED}"
  record_sync_history "success" "$notes" "$total_merged" "$total_uploaded" "$excluded_by_native" "$whitelisted_count"
  log "同步完成：合併 $total_merged / 白名單扣除 $whitelisted_count / 原生分類扣除 $excluded_by_native / 最終上傳 $total_uploaded"
  write_step_summary "success" "$total_merged" "$total_uploaded" "$sync_reason"
}

main "$@"
