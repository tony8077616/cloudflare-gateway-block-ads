#!/usr/bin/env bash
# 「某一份清單的成員讀不到」與「那份清單真的是空的」必須被分開處理的測試。
#
# 為什麼需要這支測試：讀回每份清單成員的那一行原本是
#
#     cf_curl GET ".../gateway/lists/$id/items?per_page=$LIST_CHUNK_SIZE" \
#       | jq -r '.result[]?.value // empty' | sort -u > "$TMP_DIR/slot/$idx.txt"
#
# 三個問題疊在一起：
#   1. 完全沒有檢查回應
#   2. jq 的 `?` 把壞回應吞成「沒有輸出」，離開狀態仍然是 0
#   3. 整段跑在 `{ ... } &` 背景子行程裡，離開狀態連被檢查的機會都沒有
#
# 而重導向會**先把檔案建出來**。於是一次暫時性失敗 → 一份零筆的槽位檔 →
# 下游把那 1000 筆當成不存在，重新分配到別的槽位，再把讀錯的那一份當成
# 「變成空的」**送出 DELETE**。
#
# 跟白名單（#14）和清單列舉（#15）是同一個形狀：後端讀取失敗被靜默重新詮釋成
# 「這個東西是空的」，然後帶著錯誤語意繼續寫入 —— 只是這一次的終點是刪除。
#
# 最重要的案例是**案例 1：合法的零筆仍須成功**，不是那些失敗案例。一個「讀不到
# 就一律中止」的天真實作會通過每一個失敗案例，卻讓「剛好有一份空清單刪除失敗」
# 這種無關緊要的狀況卡住整次同步。
#
# 做法：從 sync.sh **抽出正在跑的函式**（不是抄一份平行實作），把 cf_curl 與
# sleep 換成替身。全程離線，不起伺服器、不需要憑證。
#
# 用法：bash test/slot-member-read.test.sh [repo 根目錄]
set -uo pipefail

ROOT="${1:-$(dirname "$0")/..}"
SYNC="$ROOT/sync.sh"
[[ -f "$SYNC" ]] || { echo "找不到 $SYNC" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "需要 jq 才能跑這支測試" >&2; exit 2; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# ── 抽取 ──────────────────────────────────────────────────
# 先把 CR 去掉再交給 awk：工作目錄裡的 sync.sh 在 Windows 上是 CRLF，
# 而各家 awk 對 CR 的處理不一致（MSYS 的會吃掉、Linux 的不會）。
tr -d '\r' < "$SYNC" > "$WORK/sync_lf.sh"

extract_fn() {
  awk -v fn="$1" '
    $0 == fn "() {"     { inside = 1 }
    inside              { print }
    inside && $0 == "}" { exit }
  ' "$WORK/sync_lf.sh"
}

: > "$WORK/extracted.sh"
for fn in is_valid_json get_existing_lists _fetch_one_slot fetch_slot_membership; do
  extract_fn "$fn" > "$WORK/fn_$fn.sh"
  [[ -s "$WORK/fn_$fn.sh" ]] || { echo "❌ 抽取失敗：找不到函式 $fn（可能已被改名）" >&2; exit 2; }
  [[ "$(tail -n 1 "$WORK/fn_$fn.sh")" == "}" ]] \
    || { echo "❌ 抽取失敗：$fn 的最後一行不是收尾大括號" >&2; exit 2; }
  cat "$WORK/fn_$fn.sh" >> "$WORK/extracted.sh"
  echo >> "$WORK/extracted.sh"
done

# 確認抽到的真的是我們要驗的那段邏輯。守衛被拿掉時，這裡要先大聲失敗，
# 而不是讓下面每個「應該失敗」的斷言默默通過。
# 標記一律帶變數名：`.result | type == "array"` 在 sync.sh 裡有**三個副本**
# （get_existing_lists 用 $resp、ensure_policy 用 $rules_resp、_fetch_one_slot 也用 $resp），
# 不帶變數名的字串比對擋不住「拿掉其中一個、另一個仍然匹配」。
for marker in \
  "jq -e '.result | type == \"array\"' <<< \"\$resp\"" \
  'result_info.total_count' \
  'rm -f "\$raw" "\$out"' \
  'printf .*"\$reason" > "\$reason_file"' \
  'find "\$fail_dir" -type f'
do
  grep -qE "$marker" "$WORK/extracted.sh" || {
    echo "❌ 抽取自我驗證失敗：抽出來的程式裡找不到「$marker」" >&2
    echo "   守衛可能被改掉了，這支測試會因此驗不到東西。" >&2
    exit 2
  }
done

# _fetch_one_slot 必須真的被 fetch_slot_membership 呼叫，而不是留在那裡沒人用。
grep -q '_fetch_one_slot "\$idx" "\$id"' "$WORK/fn_fetch_slot_membership.sh" || {
  echo "❌ 抽取自我驗證失敗：fetch_slot_membership 沒有呼叫 _fetch_one_slot" >&2
  exit 2
}

# ── 執行器 ────────────────────────────────────────────────
cat > "$WORK/runner.sh" <<'RUNNEREOF'
#!/usr/bin/env bash
# $1 = 函式檔, $2 = 情境目錄, 其餘 = 要呼叫的函式與參數
# 印出「狀態」；送出的請求記在 $2/calls.log，sleep 記在 $2/sleeps.log
set -uo pipefail
HARNESS="$1"; SC="$2"; shift 2
CALLS="$SC/calls.log"
: > "$CALLS"
: > "$SC/sleeps.log"

TMP_DIR="$SC/tmp"; mkdir -p "$TMP_DIR/slot"
CF_ACCOUNT_ID="acct"
LIST_PREFIX="Block ads"
LIST_CHUNK_SIZE=1000
SLOT_FETCH_PARALLEL=4
STATE_AVAILABLE="${STATE_AVAILABLE:-1}"
PREV_STATE_FILE="${PREV_STATE_FILE:-$SC/prev_state.txt}"
[[ -f "$PREV_STATE_FILE" ]] || : > "$PREV_STATE_FILE"

log()  { :; }
warn() { printf '%s\n' "$*" >> "$SC/warns.log"; }

# 計數走檔案，不走變數：這些呼叫大多發生在命令替換或背景子行程裡，
# 變數遞增會隨著子行程一起消失（這支測試自己就踩過這個坑）。
sleep() { printf '%s\n' "${1:-}" >> "$SC/sleeps.log"; }

# cf_curl 的替身。items 端點依「這是第幾次呼叫這個 id」回傳對應的檔案，
# 好驗重試：items_<id>.1.json、items_<id>.2.json…，找不到就用 items_<id>.json。
cf_curl() {
  local method="$1" path="$2" id n f
  printf '%s %s\n' "$method" "$path" >> "$CALLS"
  case "$path" in
    */gateway/lists)
      cat "$SC/lists.json"
      ;;
    */gateway/lists/*/items*)
      id="${path#*/gateway/lists/}"; id="${id%%/items*}"
      n=$(grep -c "/gateway/lists/$id/items" "$CALLS" 2>/dev/null) || n=1
      f="$SC/items_$id.$n.json"
      [[ -f "$f" ]] || f="$SC/items_$id.json"
      [[ -f "$f" ]] || f="$SC/items_default.json"
      cat "$f"
      ;;
    *)
      printf '{"success":true,"result":{}}'
      ;;
  esac
}

# shellcheck disable=SC1090
source "$HARNESS"

"$@"
printf '%s\n' "$?"
RUNNEREOF

scenario() {
  local d="$WORK/sc_$1"
  rm -rf "$d"; mkdir -p "$d"
  printf '{"success":true,"result":[]}' > "$d/lists.json"
  printf '{"success":true,"result":[]}' > "$d/items_default.json"
  echo "$d"
}

run() { bash "$WORK/runner.sh" "${2:-$WORK/extracted.sh}" "$1" "${@:3}"; }

items_json() {
  # $1.. = 網域
  printf '%s\n' "$@" | jq -R -s -c 'split("\n") | map(select(length > 0)) | {success: true, result: map({value: .})}'
}

lists_json() {
  # $1 = 份數
  jq -nc --argjson n "$1" '
    {success: true,
     result: [range(1; $n + 1) | {id: ("id" + (. | tostring)),
                                 name: ("Block ads - " + (. | tostring | ("00" + .)[-3:]))}]}'
}

PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); echo "  ✅ $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  ❌ $1"; }

check_status() {
  # $1 = 名稱, $2 = 期望狀態, $3 = 實得狀態
  if [[ "$3" == "$2" ]]; then ok "$1"; else bad "$1（期望狀態 $2，實得 $3）"; fi
}

slot_lines() {
  # $1 = 情境目錄, $2 = 槽位編號 → 行數；檔案不存在印 "NOFILE"
  local f="$1/tmp/slot/$2.txt"
  if [[ ! -f "$f" ]]; then printf 'NOFILE\n'; return; fi
  if [[ -s "$f" ]]; then wc -l < "$f" | tr -d ' '; else printf '0\n'; fi
}

echo "_fetch_one_slot：合法的零筆 vs 讀不到"

# ── 案例 1：合法的零筆仍須成功（頭號反事實） ──────────────
# 一份真的空了的清單（例如上一次刪除失敗）不可以讓整次同步中止。
SC="$(scenario legit_empty)"
printf '{"success":true,"result":[]}' > "$SC/items_id7.json"
st=$(run "$SC" "" _fetch_one_slot 7 id7 "$SC/r7")
check_status "合法的零筆 → 成功" 0 "$st"
if [[ "$(slot_lines "$SC" 7)" == "0" ]]; then
  ok "合法的零筆 → 留下一個零行的槽位檔（下游才知道它真的是空的）"
else
  bad "合法的零筆沒有留下零行的槽位檔（實得 $(slot_lines "$SC" 7)）"
fi

# ── 案例 2：正常內容 ──────────────────────────────────────
SC="$(scenario normal)"
items_json b.example a.example c.example > "$SC/items_id7.json"
st=$(run "$SC" "" _fetch_one_slot 7 id7 "$SC/r7")
check_status "正常 3 筆 → 成功" 0 "$st"
if [[ "$(slot_lines "$SC" 7)" == "3" ]]; then ok "正常 3 筆 → 槽位檔有 3 行"; else bad "正常 3 筆的行數不對（實得 $(slot_lines "$SC" 7)）"; fi
if [[ "$(head -1 "$SC/tmp/slot/7.txt")" == "a.example" ]]; then ok "槽位檔已排序"; else bad "槽位檔沒有排序"; fi

# ── 案例 3：回應裡有重複值仍須成功 ────────────────────────
# 筆數比對必須在 sort -u **之前**做，否則去重會讓合法回應被誤判成截斷。
SC="$(scenario dupes)"
items_json a.example a.example b.example > "$SC/items_id7.json"
st=$(run "$SC" "" _fetch_one_slot 7 id7 "$SC/r7")
check_status "回應含重複值 → 仍須成功（筆數比對在去重之前）" 0 "$st"
if [[ "$(slot_lines "$SC" 7)" == "2" ]]; then ok "重複值已去重（3 筆 → 2 行）"; else bad "去重結果不對（實得 $(slot_lines "$SC" 7)）"; fi

# ── 案例 4～7：各種讀不到 ─────────────────────────────────
fail_case() {
  # $1 = 名稱, $2 = 回應內容
  local name="$1" body="$2" sc st
  sc="$(scenario "f_$(echo "$name" | tr -cd 'a-z0-9')")"
  printf '%s' "$body" > "$sc/items_id7.json"
  st=$(run "$sc" "" _fetch_one_slot 7 id7 "$sc/r7")
  if [[ "$st" != "0" ]]; then ok "$name → 非零狀態"; else bad "$name → 竟然回傳 0"; fi
  if [[ "$(slot_lines "$sc" 7)" == "NOFILE" ]]; then
    ok "$name → 沒有留下槽位檔（不會被當成空槽位）"
  else
    bad "$name → 留下了槽位檔（$(slot_lines "$sc" 7) 行），會被當成空槽位"
  fi
}

fail_case "success 是 false"   '{"success":false,"errors":[{"code":10000}],"result":null}'
fail_case "HTML 錯誤頁"        '<html><head><title>500</title></head></html>'
fail_case "result 是空物件"    '{"success":true,"result":{}}'
fail_case "result 是 null"     '{"success":true,"result":null}'

# `result` 是 {} 這一項特別重要：jq 迭代空物件會回傳 0 且不輸出任何東西，
# 安安靜靜地變成「這份清單是空的」。null 至少還會讓 jq 以 5 結束。

# ── 案例 8：value 是 null 的元素會被 // empty 吞掉 ────────
SC="$(scenario nullvalue)"
printf '{"success":true,"result":[{"value":"a.example"},{"value":null},{"value":"b.example"}]}' > "$SC/items_id7.json"
st=$(run "$SC" "" _fetch_one_slot 7 id7 "$SC/r7")
check_status "有元素的 value 是 null（3 筆進、2 行出）→ 非零狀態" 1 "$st"

# ── 案例 9～10：截斷守衛 ──────────────────────────────────
SC="$(scenario truncated)"
printf '{"success":true,"result":[{"value":"a.example"}],"result_info":{"total_count":900}}' > "$SC/items_id7.json"
st=$(run "$SC" "" _fetch_one_slot 7 id7 "$SC/r7")
check_status "這一頁 1 筆但 Cloudflare 說共 900 筆 → 非零狀態" 1 "$st"

SC="$(scenario not_truncated)"
printf '{"success":true,"result":[{"value":"a.example"}],"result_info":{"total_count":1}}' > "$SC/items_id7.json"
st=$(run "$SC" "" _fetch_one_slot 7 id7 "$SC/r7")
check_status "total_count 與實際筆數相符 → 成功" 0 "$st"

# ── 案例 11：暫時性失敗，重試之後成功 ────────────────────
SC="$(scenario retry_ok)"
printf '{"success":false}' > "$SC/items_id7.1.json"
printf '{"success":false}' > "$SC/items_id7.2.json"
items_json a.example b.example > "$SC/items_id7.3.json"
st=$(run "$SC" "" _fetch_one_slot 7 id7 "$SC/r7")
check_status "前兩次失敗、第三次成功 → 成功" 0 "$st"
calls=$(grep -c '/items' "$SC/calls.log" 2>/dev/null) || calls=0
if [[ "$calls" == "3" ]]; then ok "重試了 3 次"; else bad "重試次數不對（實得 $calls）"; fi
sleeps=$(grep -c . "$SC/sleeps.log" 2>/dev/null) || sleeps=0
if [[ "$sleeps" == "2" ]]; then ok "兩次重試之間有退避（sleep 2 次）"; else bad "退避次數不對（實得 $sleeps）"; fi

# ── 案例 12：一直失敗就停，不是無限重試 ──────────────────
SC="$(scenario retry_exhaust)"
printf '{"success":false}' > "$SC/items_id7.json"
st=$(run "$SC" "" _fetch_one_slot 7 id7 "$SC/r7")
check_status "一直失敗 → 非零狀態" 1 "$st"
calls=$(grep -c '/items' "$SC/calls.log" 2>/dev/null) || calls=0
if [[ "$calls" == "3" ]]; then ok "剛好試 3 次就停（不是無限重試）"; else bad "重試次數不對（實得 $calls）"; fi

# ── 案例 13：原因檔可讀，而且不含回應內容 ────────────────
if [[ -s "$SC/r7" ]]; then ok "失敗時寫下了原因"; else bad "失敗時沒有寫下原因"; fi

# 用金絲雀驗，不要用「原因字串裡有沒有某個字」—— 原因字串本來就會提到欄位名稱
# （例如「success 不是 true」），拿欄位名稱當洩漏訊號只會驗到自己的用詞。
# 這裡把一段獨一無二的字串塞進回應本體，斷言它不會出現在任何輸出裡。
SC="$(scenario canary)"
printf '{"success":false,"errors":[{"message":"LEAKCANARY_7f3a91"}]}' > "$SC/items_id7.json"
st=$(run "$SC" "" _fetch_one_slot 7 id7 "$SC/r7")
check_status "回應帶金絲雀字串且失敗 → 非零狀態" 1 "$st"
if grep -rq 'LEAKCANARY_7f3a91' "$SC/r7" "$SC/warns.log" 2>/dev/null; then
  bad "回應內容外流到原因檔或 warn（這是公開 repo 的日誌）"
else
  ok "回應內容沒有外流到原因檔或 warn（公開日誌規則）"
fi

# ── 案例 14：失敗時會清掉既有的槽位檔 ────────────────────
# 留著舊檔案就等於拿上一次的內容冒充這一次的現況。
SC="$(scenario stale)"
printf '{"success":false}' > "$SC/items_id7.json"
mkdir -p "$SC/tmp/slot"
printf 'stale.example\n' > "$SC/tmp/slot/7.txt"
st=$(run "$SC" "" _fetch_one_slot 7 id7 "$SC/r7")
check_status "失敗（且原本有舊槽位檔）→ 非零狀態" 1 "$st"
if [[ "$(slot_lines "$SC" 7)" == "NOFILE" ]]; then
  ok "失敗時把舊的槽位檔清掉了（不會拿上次的內容冒充現況）"
else
  bad "失敗時留下了舊的槽位檔（$(slot_lines "$SC" 7) 行）"
fi

echo "fetch_slot_membership：整合層"

# ── 案例 15：三份全部讀得到 ──────────────────────────────
SC="$(scenario all_ok)"
lists_json 3 > "$SC/lists.json"
items_json a.example > "$SC/items_id1.json"
items_json b.example > "$SC/items_id2.json"
items_json c.example > "$SC/items_id3.json"
st=$(run "$SC" "" fetch_slot_membership)
check_status "三份全部讀得到 → 成功" 0 "$st"

# ── 案例 16：其中一份讀不到 ──────────────────────────────
SC="$(scenario one_bad)"
lists_json 3 > "$SC/lists.json"
items_json a.example > "$SC/items_id1.json"
printf '{"success":true,"result":{}}' > "$SC/items_id2.json"
items_json c.example > "$SC/items_id3.json"
st=$(run "$SC" "" fetch_slot_membership)
check_status "三份裡有一份讀不到 → 非零狀態（整批中止）" 1 "$st"
if [[ "$(slot_lines "$SC" 2)" == "NOFILE" ]]; then
  ok "讀不到的那一份沒有留下槽位檔"
else
  bad "讀不到的那一份留下了槽位檔（$(slot_lines "$SC" 2) 行）"
fi
if grep -q '讀不到' "$SC/warns.log" 2>/dev/null; then
  ok "有 warn 說明讀不到（操作者看得到原因）"
else
  bad "沒有任何 warn，操作者看不到原因"
fi

# ── 案例 17：清單是合法的零筆時，整批仍須成功 ────────────
SC="$(scenario all_empty_lists)"
lists_json 2 > "$SC/lists.json"
printf '{"success":true,"result":[]}' > "$SC/items_id1.json"
items_json c.example > "$SC/items_id2.json"
st=$(run "$SC" "" fetch_slot_membership)
check_status "其中一份真的是空的 → 整批仍須成功" 0 "$st"

# ══════════════════════════════════════════════════════════
# 反事實：每一道守衛單獨移除之後，對應案例必須變紅
# ══════════════════════════════════════════════════════════
echo "反事實"

mutate() {
  # $1 = 名稱, $2.. = sed 指令
  local name="$1"; shift
  cp "$WORK/extracted.sh" "$WORK/mut_$name.sh"
  local before after
  before=$(md5sum < "$WORK/mut_$name.sh")
  local s
  for s in "$@"; do sed -i "$s" "$WORK/mut_$name.sh"; done
  after=$(md5sum < "$WORK/mut_$name.sh")
  if [[ "$before" == "$after" ]]; then
    echo "❌ 反事實 $name 沒有改到任何東西（錨點失效，這個反事實是假的）" >&2
    exit 2
  fi
  printf '%s\n' "$WORK/mut_$name.sh"
}

# A：把整段還原成原本那行 pipeline（重現真正發生過的 bug）
cat > "$WORK/orig.sh" <<'ORIGEOF'
_fetch_one_slot() {
  local idx="$1" id="$2" reason_file="$3"
  cf_curl GET "/accounts/$CF_ACCOUNT_ID/gateway/lists/$id/items?per_page=$LIST_CHUNK_SIZE" \
    | jq -r '.result[]?.value // empty' | sort -u > "$TMP_DIR/slot/$idx.txt"
}
ORIGEOF
grep -v '^_fetch_one_slot() {$' /dev/null >/dev/null 2>&1  # no-op，維持結構可讀
awk '
  /^_fetch_one_slot\(\) \{$/ { skip = 1 }
  skip && /^\}$/             { skip = 0; next }
  !skip                      { print }
' "$WORK/extracted.sh" > "$WORK/mut_orig_rest.sh"
cat "$WORK/orig.sh" "$WORK/mut_orig_rest.sh" > "$WORK/mut_orig.sh"
grep -q "result\[\]?" "$WORK/mut_orig.sh" || { echo "❌ 反事實 orig 組裝失敗" >&2; exit 2; }

SC="$(scenario cf_orig)"
printf '{"success":true,"result":{}}' > "$SC/items_id7.json"
st=$(run "$SC" "$WORK/mut_orig.sh" _fetch_one_slot 7 id7 "$SC/r7")
if [[ "$st" == "0" && "$(slot_lines "$SC" 7)" == "0" ]]; then
  ok "反事實 A（還原成原本那行 pipeline）→ 壞回應變成「零筆的槽位」，正是這一片要修的事"
else
  bad "反事實 A 沒有重現原本的行為（狀態 $st，槽位 $(slot_lines "$SC" 7)）"
fi

SC="$(scenario cf_orig_int)"
lists_json 2 > "$SC/lists.json"
items_json a.example > "$SC/items_id1.json"
printf '{"success":true,"result":{}}' > "$SC/items_id2.json"
st=$(run "$SC" "$WORK/mut_orig.sh" fetch_slot_membership)
if [[ "$st" == "0" ]]; then
  ok "反事實 A（整合層）→ 一份讀不到卻整批回報成功，下游會刪掉那一份"
else
  bad "反事實 A 整合層沒有重現（實得狀態 $st）"
fi

# B：拿掉結構斷言
M="$(mutate no_shape "s/elif ! jq -e '.result | type == \"array\"' <<< \"\$resp\" >\/dev\/null 2>&1; then/elif false; then/")"
SC="$(scenario cf_shape)"
printf '{"success":true,"result":{}}' > "$SC/items_id7.json"
st=$(run "$SC" "$M" _fetch_one_slot 7 id7 "$SC/r7")
if [[ "$st" == "0" ]]; then
  ok "反事實 B（拿掉結構斷言）→ result 是 {} 時靜默變成零筆"
else
  bad "反事實 B 沒有重現（實得狀態 $st）"
fi

# C：拿掉筆數比對
M="$(mutate no_count 's/if \[\[ "\$expected" != "\$actual" \]\]; then/if false; then/')"
SC="$(scenario cf_count)"
printf '{"success":true,"result":[{"value":"a.example"},{"value":null}]}' > "$SC/items_id7.json"
st=$(run "$SC" "$M" _fetch_one_slot 7 id7 "$SC/r7")
if [[ "$st" == "0" ]]; then
  ok "反事實 C（拿掉筆數比對）→ value 是 null 的元素被吞掉卻回報成功"
else
  bad "反事實 C 沒有重現（實得狀態 $st）"
fi

# D：拿掉失敗時的清檔
M="$(mutate no_cleanup 's/^  rm -f "\$raw" "\$out"$/  rm -f "$raw"/')"
SC="$(scenario cf_cleanup)"
printf '{"success":false}' > "$SC/items_id7.json"
mkdir -p "$SC/tmp/slot"
printf 'stale.example\n' > "$SC/tmp/slot/7.txt"
st=$(run "$SC" "$M" _fetch_one_slot 7 id7 "$SC/r7")
if [[ "$(slot_lines "$SC" 7)" != "NOFILE" ]]; then
  ok "反事實 D（拿掉失敗清檔）→ 舊的槽位檔留了下來，會冒充這次的現況"
else
  bad "反事實 D 沒有重現（槽位檔仍然不存在）"
fi

# E：拿掉整批的失敗檢查
M="$(mutate no_gate 's/if \[\[ "\${failed_n:-0}" -gt 0 \]\]; then/if false; then/')"
SC="$(scenario cf_gate)"
lists_json 2 > "$SC/lists.json"
items_json a.example > "$SC/items_id1.json"
printf '{"success":false}' > "$SC/items_id2.json"
st=$(run "$SC" "$M" fetch_slot_membership)
if [[ "$st" == "0" ]]; then
  ok "反事實 E（拿掉整批失敗檢查）→ 個別失敗不再往上傳，中止接線收不到訊號"
else
  bad "反事實 E 沒有重現（實得狀態 $st）"
fi

echo
echo "通過 $PASS / 失敗 $FAIL"
[[ $FAIL -eq 0 ]]
