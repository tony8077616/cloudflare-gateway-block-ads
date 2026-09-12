#!/usr/bin/env bash
# 中止「接線」的測試：偵測到問題之後，真的有人把它接成中止嗎？
#
# 為什麼需要這支測試：PR #14 有兩支測試證明「白名單讀不到時 load_whitelist 回傳非 0」，
# 但**沒有任何東西**驗證呼叫端會理會那個回傳值。PR #14 的獨立驗證構造出兩個變異，
# 它們讓整組測試維持全綠、卻完整還原了 2026-09-04 那個 fail-open：
#
#   1. 把呼叫端的 `if ! load_whitelist > "$f"; then` 拆成 `load_whitelist > "$f"; if false; then`
#   2. 把中止函式最後的 `exit 1` 改成 `return 1` —— 因為它是 then 分支的最後一個語句，
#      main() 會若無其事地繼續，而且失敗紀錄與失敗摘要都已經寫下去了，
#      結果是「回報失敗，同時上傳一份沒套白名單的清單」
#
# 兩個都通過 bash -n、都全綠出貨。單元測試證明了守衛會回報，證明不了有人在聽。
#
# 做法：把 main() 裡的那兩段**連同中止函式一起抽出來實際執行**，在後面放一個標記，
# 然後斷言「該中止時行程以非 0 結束，而且標記沒有被印出來」。
#
# 用法：bash test/abort-wiring.test.sh [repo 根目錄]
set -uo pipefail

ROOT="${1:-$(dirname "$0")/..}"
SYNC="$ROOT/sync.sh"
[[ -f "$SYNC" ]] || { echo "找不到 $SYNC" >&2; exit 2; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
tr -d '\r' < "$SYNC" > "$WORK/sync_lf.sh"

drop_last() { sed '$d'; }

# ── 抽取 ──────────────────────────────────────────────────
# 白名單那一段：從宣告 whitelist_file 起，到 checksum 那段之前為止。
sed -n '/^  local whitelist_file=/,/^  local wl_sum bl_sum$/p' "$WORK/sync_lf.sh" \
  | drop_last > "$WORK/block_whitelist.sh"

# Gateway 列舉那一段：從 fetch_slot_membership 的守衛起，到 plan_slot_changes 之前為止。
sed -n '/^  if ! fetch_slot_membership; then$/,/^  plan_slot_changes /p' "$WORK/sync_lf.sh" \
  | drop_last > "$WORK/block_gateway.sh"

# 中止函式本體（白名單那一段會呼叫它）。
awk '
  $0 == "abort_on_authoritative_read_failure() {" { inside = 1 }
  inside              { print }
  inside && $0 == "}" { exit }
' "$WORK/sync_lf.sh" > "$WORK/fn_abort.sh"

for f in block_whitelist block_gateway fn_abort; do
  [[ -s "$WORK/$f.sh" ]] || { echo "❌ 抽取失敗：$f 是空的（錨點可能被改動了）" >&2; exit 2; }
done

# 抽取自我驗證：抽出來的東西必須真的含有「中止」與「呼叫載入器」這兩件事，
# 否則後面每一個「應該中止」的斷言都會因為根本沒跑到而假通過。
grep -q 'load_whitelist' "$WORK/block_whitelist.sh" \
  || { echo "❌ 抽取自我驗證失敗：白名單區塊裡沒有 load_whitelist" >&2; exit 2; }
grep -q 'abort_on_authoritative_read_failure' "$WORK/block_whitelist.sh" \
  || { echo "❌ 抽取自我驗證失敗：白名單區塊裡沒有呼叫中止函式" >&2; exit 2; }
grep -q 'exit 1' "$WORK/fn_abort.sh" \
  || { echo "❌ 抽取自我驗證失敗：中止函式裡沒有 exit 1" >&2; exit 2; }
grep -q 'exit 1' "$WORK/block_gateway.sh" \
  || { echo "❌ 抽取自我驗證失敗：Gateway 區塊裡沒有 exit 1" >&2; exit 2; }

# ── 組裝 ──────────────────────────────────────────────────
build_harness() {
  # $1 = 區塊檔, $2 = 輸出檔, $3 = 額外前置（stub 定義）
  {
    echo 'set -uo pipefail'
    echo 'TMP_DIR="$WORK_RUN"'
    echo 'total_merged=278678; excluded_by_native=54723; whitelisted_count=4'
    echo 'log() { :; }'
    echo 'warn() { :; }'
    echo 'group_begin() { :; }'
    echo 'group_end() { :; }'
    echo 'record_sync_history() { printf "history %s\n" "$1" >> "$WORK_RUN/side.log"; }'
    echo 'write_step_summary() { printf "summary %s\n" "$1" >> "$WORK_RUN/side.log"; }'
    echo "$3"
    cat "$WORK/fn_abort.sh"
    echo 'run_block() {'
    cat "$1"
    # 這一行是整支測試的核心斷言對象：中止沒接好的話它就會被印出來。
    echo '  echo "REACHED_PAST_GUARD"'
    echo '}'
    echo 'run_block'
  } > "$2"
}

run_harness() {
  # $1 = harness 檔。印出「狀態<TAB>有沒有越過守衛(yes/no)」
  local d="$WORK/run"; rm -rf "$d"; mkdir -p "$d"
  local out
  out=$(WORK_RUN="$d" bash "$1" 2>/dev/null)
  local st=$?
  local past=no
  grep -q 'REACHED_PAST_GUARD' <<< "$out" && past=yes
  printf '%s\t%s\n' "$st" "$past"
}

PASS=0; FAIL=0
check() {
  local name="$1" want="$2" got="$3"
  if [[ "$got" == "$want" ]]; then echo "  ✅ $name"; PASS=$((PASS + 1))
  else echo "  ❌ $name：期望 狀態/越過=$want，實得 $got"; FAIL=$((FAIL + 1)); fi
}

STUB_WL_FAIL='load_whitelist() { return 1; }
load_custom_blocklist() { return 0; }'
STUB_BL_FAIL='load_whitelist() { return 0; }
load_custom_blocklist() { return 1; }'
STUB_WL_OK='load_whitelist() { return 0; }
load_custom_blocklist() { return 0; }'
STUB_GW_FAIL='fetch_slot_membership() { return 1; }'
STUB_GW_OK='fetch_slot_membership() { return 0; }'

echo "── 白名單：偵測到之後真的有中止嗎 ──"
build_harness "$WORK/block_whitelist.sh" "$WORK/h.sh" "$STUB_WL_FAIL"
check "白名單讀不到 → 非 0 結束、沒有越過守衛" "1	no" "$(run_harness "$WORK/h.sh")"

build_harness "$WORK/block_whitelist.sh" "$WORK/h.sh" "$STUB_BL_FAIL"
check "自訂封鎖清單讀不到 → 非 0 結束、沒有越過守衛" "1	no" "$(run_harness "$WORK/h.sh")"

build_harness "$WORK/block_whitelist.sh" "$WORK/h.sh" "$STUB_WL_OK"
check "兩份都讀得到 → 0 結束、正常越過" "0	yes" "$(run_harness "$WORK/h.sh")"

echo
echo "── Gateway 列舉：偵測到之後真的有中止嗎 ──"
build_harness "$WORK/block_gateway.sh" "$WORK/h.sh" "$STUB_GW_FAIL"
check "讀不到現有清單 → 非 0 結束、沒有越過守衛" "1	no" "$(run_harness "$WORK/h.sh")"

build_harness "$WORK/block_gateway.sh" "$WORK/h.sh" "$STUB_GW_OK"
check "讀得到 → 0 結束、正常越過" "0	yes" "$(run_harness "$WORK/h.sh")"

# ── 反事實 ────────────────────────────────────────────────
# 這一段就是這支測試存在的理由：PR #14 的驗證器示範的那兩個變異，必須在這裡變紅。
echo
echo "── 反事實（PR #14 驗證器示範過的兩個變異）──"

counterfactual() {
  # $1 = 名稱, $2 = 要改的檔（block 或 abort）, $3 = sed 運算式, $4 = stub, $5 = 原本的結果
  local name="$1" target="$2" expr="$3" stub="$4" want="$5"
  local saved="$WORK/saved.sh"
  cp "$WORK/$target" "$saved"
  sed "$expr" "$saved" > "$WORK/$target"
  if cmp -s "$saved" "$WORK/$target"; then
    echo "  ❌ $name：變異沒有改到任何東西（sed 樣式過時）"; FAIL=$((FAIL + 1))
    cp "$saved" "$WORK/$target"; return
  fi
  local block="$WORK/block_whitelist.sh"
  [[ "$target" == "block_gateway.sh" ]] && block="$WORK/block_gateway.sh"
  build_harness "$block" "$WORK/h.sh" "$stub"
  local got; got="$(run_harness "$WORK/h.sh")"
  cp "$saved" "$WORK/$target"
  if [[ "$got" == "$want" ]]; then
    echo "  ❌ $name：變異之後結果沒變（仍是 $got）—— 這條接線沒有被驗到"; FAIL=$((FAIL + 1))
  else
    echo "  ✅ $name：變異之後從 $want 變成 $got"; PASS=$((PASS + 1))
  fi
}

# 變異 1：把呼叫端的 `if !` 拆掉，讓回傳值不再被理會。
counterfactual "拆掉呼叫端的 if !（守衛形同不存在）" \
  "block_whitelist.sh" \
  's|^  if ! load_whitelist > "\$whitelist_file"; then$|  load_whitelist > "$whitelist_file"; if false; then|' \
  "$STUB_WL_FAIL" "1	no"

# 變異 2：把中止函式的 exit 1 改成 return 1，於是 main() 會繼續往下走。
counterfactual "中止函式改成 return（回報失敗卻繼續執行）" \
  "fn_abort.sh" \
  's/^  exit 1$/  return 1/' \
  "$STUB_WL_FAIL" "1	no"

# 變異 3：Gateway 那一段同樣把 exit 1 拿掉。
counterfactual "Gateway 區塊的 exit 1 改成 :（偵測到卻繼續上傳）" \
  "block_gateway.sh" \
  's/^    exit 1$/    :/' \
  "$STUB_GW_FAIL" "1	no"

echo
echo "通過 $PASS / 失敗 $FAIL"
[[ $FAIL -eq 0 ]]
