#!/usr/bin/env bash
# 「讀不到 Gateway 上有什麼」與「Gateway 上真的沒有東西」必須被分開處理的測試。
#
# 為什麼需要這支測試：`get_existing_lists` 曾經是 sync.sh 裡**唯一一個沒有檢查回應**
# 的 Cloudflare 呼叫，而且呼叫端用行程替換讀它、離開狀態被丟掉。於是 401／500／
# HTML 錯誤頁通通變成「零份清單」，被解讀成「Gateway 上還沒有任何清單」，
# 接著在既有 225 份清單還在的情況下另外新建一整批、再把 Policy 改成只指向新的那批。
#
# 下游**沒有任何守衛**攔得住：兩道空清單檢查看的是「上傳的網域數／清單數是不是 0」，
# 而這條路徑上兩個數字都很大。
#
# 跟白名單那一課完全一樣，最重要的案例是**合法的零份仍須成功**（案例 1）
# 與**查得到但沒有同名規則仍須新建**（案例 8），不是那些失敗案例。
# 一個「讀不到就一律中止」的天真實作會通過每一個失敗案例，卻讓每次全新安裝都掛掉。
#
# 做法：從 sync.sh **抽出正在跑的函式**（不是抄一份平行實作），把 cf_curl 換成
# 會記錄「送出了什麼」並回傳受控內容的替身。全程離線，不起伺服器、不需要憑證。
#
# 用法：bash test/gateway-enumeration.test.sh [repo 根目錄]
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
for fn in is_valid_json get_existing_lists fetch_slot_membership ensure_policy; do
  extract_fn "$fn" > "$WORK/fn_$fn.sh"
  [[ -s "$WORK/fn_$fn.sh" ]] || { echo "❌ 抽取失敗：找不到函式 $fn（可能已被改名）" >&2; exit 2; }
  [[ "$(tail -n 1 "$WORK/fn_$fn.sh")" == "}" ]] \
    || { echo "❌ 抽取失敗：$fn 的最後一行不是收尾大括號" >&2; exit 2; }
  cat "$WORK/fn_$fn.sh" >> "$WORK/extracted.sh"
  echo >> "$WORK/extracted.sh"
done

# 確認抽到的真的是我們要驗的那段邏輯。守衛被拿掉時，這裡要先大聲失敗，
# 而不是讓下面每個「應該中止」的斷言默默通過。
for marker in \
  'result | type == "array"' \
  'result_info.total_count' \
  'REBUILD_SLOTS' \
  '不新建 policy'
do
  grep -q "$marker" "$WORK/extracted.sh" || {
    echo "❌ 抽取自我驗證失敗：抽出來的程式裡找不到「$marker」" >&2
    echo "   守衛可能被改掉了，這支測試會因此驗不到東西。" >&2
    exit 2
  }
done

# ── 執行器 ────────────────────────────────────────────────
cat > "$WORK/runner.sh" <<'RUNNEREOF'
#!/usr/bin/env bash
# $1 = 函式檔, $2 = 情境目錄, $3 = 要呼叫的函式（含參數用空白分隔）
# 印出「狀態<TAB>stdout 行數」；送出的請求記在 $2/calls.log
set -uo pipefail
HARNESS="$1"; SC="$2"; shift 2
OUT="$SC/stdout.txt"
CALLS="$SC/calls.log"
: > "$CALLS"

TMP_DIR="$SC/tmp"; mkdir -p "$TMP_DIR"
CF_ACCOUNT_ID="acct"
LIST_PREFIX="Block ads"
POLICY_NAME="Block ads"
LIST_CHUNK_SIZE=1000
SLOT_FETCH_PARALLEL=10
STATE_AVAILABLE="${STATE_AVAILABLE:-1}"
PREV_STATE_FILE="${PREV_STATE_FILE:-$SC/prev_state.txt}"
[[ -f "$PREV_STATE_FILE" ]] || : > "$PREV_STATE_FILE"

log()  { :; }
warn() { :; }

# cf_curl 的替身：記錄「送出了什麼」，並依路徑回傳這個情境準備好的內容。
# 記錄是為了能斷言「查詢失敗時**沒有**送出 POST」—— 光看回傳值證明不了這件事。
cf_curl() {
  local method="$1" path="$2"
  printf '%s %s\n' "$method" "$path" >> "$CALLS"
  case "$path" in
    */gateway/lists) cat "$SC/lists.json" ;;
    */gateway/rules) cat "$SC/rules.json" ;;
    *)               printf '{"success":true,"result":{}}' ;;
  esac
}

# shellcheck disable=SC1090
source "$HARNESS"

"$@" > "$OUT"
st=$?
if [[ -s "$OUT" ]]; then lines=$(wc -l < "$OUT" | tr -d ' '); else lines=0; fi
printf '%s\t%s\n' "$st" "$lines"
RUNNEREOF

scenario() {
  local d="$WORK/sc_$1"
  rm -rf "$d"; mkdir -p "$d"
  printf '{"success":true,"result":[]}' > "$d/lists.json"
  printf '{"success":true,"result":[]}' > "$d/rules.json"
  echo "$d"
}

run() { bash "$WORK/runner.sh" "${2:-$WORK/extracted.sh}" "$1" "${@:3}"; }

lists_json() {
  # $1 = 份數
  jq -nc --argjson n "$1" '
    {success: true,
     result: [range(1; $n + 1) | {id: ("id" + (. | tostring)),
                                 name: ("Block ads - " + (. | tostring | ("00" + .)[-3:]))}]}'
}

PASS=0; FAIL=0
check() {
  local name="$1" want="$2" got="$3"
  local w_st w_ln g_st g_ln
  IFS='/' read -r w_st w_ln <<< "$want"
  IFS=$'\t' read -r g_st g_ln <<< "$got"
  local ok=1
  [[ "$w_st" == "-" || "$w_st" == "$g_st" ]] || ok=0
  [[ "$w_ln" == "-" || "$w_ln" == "$g_ln" ]] || ok=0
  if [[ $ok -eq 1 ]]; then echo "  ✅ $name"; PASS=$((PASS + 1))
  else echo "  ❌ $name：期望 狀態/行數=$want，實得 $g_st/$g_ln"; FAIL=$((FAIL + 1)); fi
}

echo "── get_existing_lists：讀不到 vs 真的沒有 ──"

# 案例 1：帳戶上真的一份都沒有。**最重要的案例。**
D=$(scenario zero); printf '{"success":true,"result":[]}' > "$D/lists.json"
check "合法的零份 → 成功、輸出空" "0/0" "$(run "$D" "" get_existing_lists)"

# 案例 2：225 份（線上實際份數）。
D=$(scenario full); lists_json 225 > "$D/lists.json"
check "225 份 → 成功、225 行" "0/225" "$(run "$D" "" get_existing_lists)"

# 案例 3：401 長這樣。
D=$(scenario sf); printf '{"success":false,"errors":[{"code":10000}],"result":null}' > "$D/lists.json"
check "success 為 false → 失敗、輸出空" "1/0" "$(run "$D" "" get_existing_lists)"

# 案例 4：上游代理的 HTML 錯誤頁。
D=$(scenario html); printf '<html><title>502 Bad Gateway</title></html>' > "$D/lists.json"
check "HTML 錯誤頁 → 失敗、輸出空" "1/0" "$(run "$D" "" get_existing_lists)"

# 案例 5：curl 整個死掉。
D=$(scenario empty); : > "$D/lists.json"
check "空回應 → 失敗、輸出空" "1/0" "$(run "$D" "" get_existing_lists)"

# 案例 6a：success 是 true 但 result 是 null。
D=$(scenario shape); printf '{"success":true,"result":null}' > "$D/lists.json"
check "success=true 但 result 是 null → 失敗" "1/0" "$(run "$D" "" get_existing_lists)"

# 案例 6b：success 是 true 但 result 是物件。**這個比 null 更危險。**
# jq 迭代空物件不會報錯、回傳 0、什麼也不印 —— 沒有結構斷言的話，
# 它會安安靜靜地變成「零份清單」，而 null 至少還會讓 jq 以 5 結束。
D=$(scenario shape_obj); printf '{"success":true,"result":{}}' > "$D/lists.json"
check "success=true 但 result 是物件 → 失敗（這個會靜默變成零份）" "1/0" "$(run "$D" "" get_existing_lists)"

# 案例 7：分頁截斷。這個端點目前不回 result_info，所以是為了日後 API 改動而設。
D=$(scenario trunc)
jq -nc '{success: true, result_info: {total_count: 225},
         result: [{id:"id1", name:"Block ads - 001"}]}' > "$D/lists.json"
check "result_info 說 225 份卻只拿到 1 份 → 失敗" "1/0" "$(run "$D" "" get_existing_lists)"

echo
echo "── fetch_slot_membership：失敗要往上傳，零份要分辨 ──"

# 列舉失敗必須讓 fetch_slot_membership 也失敗（原本行程替換會把狀態吃掉）。
D=$(scenario fsm_fail); printf '{"success":false,"errors":[{"code":10000}]}' > "$D/lists.json"
check "列舉失敗 → fetch_slot_membership 也失敗" "1/0" "$(run "$D" "" fetch_slot_membership)"

# 全新安裝：零份、而且沒有前次狀態 → 成功，走新建。
D=$(scenario fsm_fresh); : > "$D/prev_state.txt"
check "零份 + 沒有前次狀態（全新安裝）→ 成功" "0/0" "$(run "$D" "" fetch_slot_membership)"

# 矛盾：零份、但上次同步留有狀態 → 中止，不當成全新安裝。
D=$(scenario fsm_contra); printf 'src:foo\tabc\n' > "$D/prev_state.txt"
check "零份 + 有前次狀態（矛盾）→ 中止" "1/0" "$(run "$D" "" fetch_slot_membership)"

# 逃生口：真的想從零重建。
D=$(scenario fsm_rebuild); printf 'src:foo\tabc\n' > "$D/prev_state.txt"
REBUILD_SLOTS=1 check_out="$(REBUILD_SLOTS=1 run "$D" "" fetch_slot_membership)"
check "零份 + 有前次狀態 + REBUILD_SLOTS=1 → 放行" "0/0" "$check_out"

echo
echo "── ensure_policy：查詢失敗不可以變成「再建一條」──"

posted() {
  # grep -c 找不到時會「印出 0 並且回傳非 0」，所以不能寫成 `grep -c ... || echo 0`
  # —— 那會印兩個 0，比對永遠不相等（第一版就是這樣假失敗的）。
  local n
  n=$(grep -c '^POST ' "$1/calls.log" 2>/dev/null) || n=0
  printf '%s' "$n"
}

# 規則查詢失敗 → 必須中止，而且**絕對不可以送出 POST**（那會建出第二條同名 policy）。
D=$(scenario pol_fail); printf 'id1\n' > "$D/ids.txt"
printf '{"success":false,"errors":[{"code":10000}],"result":null}' > "$D/rules.json"
OUT="$(run "$D" "" ensure_policy "$D/ids.txt")"
check "規則查詢失敗 → 中止" "1/-" "$OUT"
if [[ "$(posted "$D")" == "0" ]]; then
  echo "  ✅ 規則查詢失敗時沒有送出任何 POST（不會建出第二條 policy）"; PASS=$((PASS + 1))
else
  echo "  ❌ 規則查詢失敗時竟然送出了 POST —— 這正是會建出重複 policy 的那條路"; FAIL=$((FAIL + 1))
fi

# 查得到、但還沒有同名規則 → 合法的第一次安裝，要走 POST。
D=$(scenario pol_first); printf 'id1\n' > "$D/ids.txt"
printf '{"success":true,"result":[]}' > "$D/rules.json"
OUT="$(run "$D" "" ensure_policy "$D/ids.txt")"
check "查得到但沒有同名規則 → 成功" "0/-" "$OUT"
if [[ "$(posted "$D")" == "1" ]]; then
  echo "  ✅ 第一次安裝確實走 POST 新建"; PASS=$((PASS + 1))
else
  echo "  ❌ 第一次安裝沒有送出 POST —— 全新安裝會裝不起來"; FAIL=$((FAIL + 1))
fi

# ── 反事實 ────────────────────────────────────────────────
echo
echo "── 反事實（守衛必須是必要的）──"

counterfactual() {
  # $1 = 名稱, $2 = sed 運算式, $3 = 情境目錄, $4 = 原本的狀態, $5.. = 要呼叫的函式
  local name="$1" expr="$2" dir="$3" want_st="$4"; shift 4
  local mutated="$WORK/mutated.sh"
  sed "$expr" "$WORK/extracted.sh" > "$mutated"
  if cmp -s "$WORK/extracted.sh" "$mutated"; then
    echo "  ❌ $name：變異沒有改到任何東西（sed 樣式過時）"; FAIL=$((FAIL + 1)); return
  fi
  local got_st
  got_st="$(run "$dir" "$mutated" "$@" 2>/dev/null | cut -f1)"
  if [[ "$got_st" == "$want_st" ]]; then
    echo "  ❌ $name：拿掉守衛之後結果沒變（仍是狀態 $got_st）—— 這個守衛沒有被驗到"
    FAIL=$((FAIL + 1))
  else
    echo "  ✅ $name：拿掉守衛之後從狀態 $want_st 變成 $got_st"; PASS=$((PASS + 1))
  fi
}

# A：拿掉 success 檢查 → 401 會被當成零份清單（原本那場災難的入口）。
D=$(scenario cf_a); printf '{"success":false,"errors":[{"code":10000}],"result":[]}' > "$D/lists.json"
counterfactual "success 檢查" \
  's/^  if \[\[ "\$(jq -r .\.success. <<< "\$resp")" != "true" \]\]; then$/  if false; then/' \
  "$D" 1 get_existing_lists

# B：拿掉結構斷言 → result 是物件時會**靜默**變成零份（狀態 0、輸出空）。
# 這裡刻意用 {} 而不是 null：null 會讓 jq 以 5 結束，就算沒有守衛也不會靜默通過，
# 用它當反事實會高估守衛的必要性。{} 才是這道守衛真正擋下來的東西。
D=$(scenario cf_b); printf '{"success":true,"result":{}}' > "$D/lists.json"
counterfactual "result 結構斷言" \
  's/^  if ! jq -e .\.result | type == "array". <<< "\$resp" >\/dev\/null 2>&1; then$/  if false; then/' \
  "$D" 1 get_existing_lists

# C：拿掉零份矛盾檢查 → 有前次狀態卻讀到零份也會被當成全新安裝。
D=$(scenario cf_c); printf 'src:foo\tabc\n' > "$D/prev_state.txt"
counterfactual "零份矛盾檢查" \
  's/^    if \[\[ "\${STATE_AVAILABLE:-0}" -eq 1 .*$/    if false; then/' \
  "$D" 1 fetch_slot_membership

# D：天真實作 ——「列舉到零份就一律當失敗」。
# 它會通過上面每一個失敗案例，但會讓**全新安裝**裝不起來。這是這支測試真正要守的東西。
D=$(scenario cf_d); printf '{"success":true,"result":[]}' > "$D/lists.json"; : > "$D/prev_state.txt"
counterfactual "合法的零份必須成功（天真實作會在這裡露餡）" \
  's/^    log "Gateway 上還沒有任何清單，全部視為新建"$/    return 1/' \
  "$D" 0 fetch_slot_membership

echo
echo "通過 $PASS / 失敗 $FAIL"
[[ $FAIL -eq 0 ]]
