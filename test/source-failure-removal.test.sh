#!/usr/bin/env bash
# 「某個來源這次沒抓到」不可以被當成「那個來源的網域該解除封鎖」的測試。
#
# 為什麼需要這支測試：`build_merged` 是 `cat "$TMP_DIR"/parsed_*.txt | sort -u`。
# 抓取失敗的來源沒有 parsed_ 檔，它的網域就整個從合併結果裡消失。接著
# `plan_slot_changes` 的
#
#     comm -23 "$current_all" "$desired" > "$to_remove"
#
# 會把那些網域算成「該從 Gateway 移除」。
#
# 光是這樣還只是一次性的翻攪。真正讓它變嚴重的是狀態回寫：抓取失敗的來源會**沿用
# 前次 checksum**（那是為了避免下次把它誤判成「內容變動」）。於是下一次它抓成功、
# 內容又沒變時，閘門判定無變動而**略過整次同步** —— 被拿掉的那些網域要等到有別的
# 來源變動才會被補回來。一次暫時性的抓取失敗，換來一段沒有上限的解除封鎖。
#
# 修法不是去補復原路徑，而是讓那個移除一開始就不要發生：有來源失敗時，只移除
# 「本次合併結果裡確實出現過」的網域（那些是白名單／原生分類主動刷掉的，有把握），
# 其餘一律押後。
#
# 最重要的兩個案例是**案例 1（沒有來源失敗時，移除必須照常發生）**與
# **案例 3（白名單造成的移除不可以被押後）**，不是那些押後案例。一個「有來源失敗
# 就什麼都不移除」的天真實作會通過所有押後案例，卻讓使用者的白名單永遠不生效。
#
# 做法：從 sync.sh **抽出正在跑的 plan_slot_changes**（不是抄一份平行實作），
# 用檔案佈置出各種現況。全程離線，不呼叫任何 API。
#
# 用法：bash test/source-failure-removal.test.sh [repo 根目錄]
set -uo pipefail

ROOT="${1:-$(dirname "$0")/..}"
SYNC="$ROOT/sync.sh"
[[ -f "$SYNC" ]] || { echo "找不到 $SYNC" >&2; exit 2; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# 先把 CR 去掉再交給 awk：工作目錄裡的 sync.sh 在 Windows 上是 CRLF。
tr -d '\r' < "$SYNC" > "$WORK/sync_lf.sh"

extract_fn() {
  awk -v fn="$1" '
    $0 == fn "() {"     { inside = 1 }
    inside              { print }
    inside && $0 == "}" { exit }
  ' "$WORK/sync_lf.sh"
}

: > "$WORK/extracted.sh"
for fn in build_merged plan_slot_changes; do
  extract_fn "$fn" > "$WORK/fn_$fn.sh"
  [[ -s "$WORK/fn_$fn.sh" ]] || { echo "❌ 抽取失敗：找不到函式 $fn（可能已被改名）" >&2; exit 2; }
  [[ "$(tail -n 1 "$WORK/fn_$fn.sh")" == "}" ]] \
    || { echo "❌ 抽取失敗：$fn 的最後一行不是收尾大括號" >&2; exit 2; }
  cat "$WORK/fn_$fn.sh" >> "$WORK/extracted.sh"
  echo >> "$WORK/extracted.sh"
done

# 確認抽到的真的是我們要驗的那段邏輯。守衛被拿掉時，這裡要先大聲失敗，
# 而不是讓下面每個押後斷言默默通過。
for marker in \
  'failed_sources.txt.*merged_domains.txt' \
  'comm -12 "\$to_remove_all" "\$TMP_DIR/merged_domains.txt"' \
  '暫緩移除'
do
  grep -qE "$marker" "$WORK/extracted.sh" || {
    echo "❌ 抽取自我驗證失敗：抽出來的程式裡找不到「$marker」" >&2
    echo "   守衛可能被改掉了，這支測試會因此驗不到東西。" >&2
    exit 2
  }
done

# ── 執行器 ────────────────────────────────────────────────
cat > "$WORK/runner.sh" <<'RUNNEREOF'
#!/usr/bin/env bash
# $1 = 函式檔, $2 = 情境目錄
set -uo pipefail
HARNESS="$1"; SC="$2"
TMP_DIR="$SC/tmp"
LIST_CHUNK_SIZE=1000

log()  { :; }
warn() { printf '%s\n' "$*" >> "$SC/warns.log"; }

# shellcheck disable=SC1090
source "$HARNESS"

plan_slot_changes "$TMP_DIR/desired.txt"
printf '%s\n' "$?"
RUNNEREOF

# ── 情境佈置 ──────────────────────────────────────────────
# 一個情境需要：
#   tmp/slot/<idx>.txt      Gateway 現況（每份清單的成員）
#   tmp/slot_ids.txt        idx<TAB>list_id
#   tmp/merged_domains.txt  本次各來源合併去重後的結果
#   tmp/desired.txt         本次的目標清單（合併 → 扣白名單 → 扣原生分類 → 加自訂封鎖）
#   tmp/failed_sources.txt  本次抓取失敗的來源名（空檔 = 全部成功）
scenario() {
  local d="$WORK/sc_$1"
  rm -rf "$d"; mkdir -p "$d/tmp/slot"
  : > "$d/tmp/failed_sources.txt"
  : > "$d/warns.log"
  echo "$d"
}

put_slot() {
  # $1 = 情境目錄, $2 = 槽位編號, $3.. = 網域
  local d="$1" idx="$2"; shift 2
  printf '%s\n' "$@" | sort -u > "$d/tmp/slot/$idx.txt"
  printf '%s\tid%s\n' "$idx" "$idx" >> "$d/tmp/slot_ids.txt"
}

put_file() {
  # $1 = 情境目錄, $2 = 檔名, $3.. = 每行內容（無參數 = 空檔）
  local d="$1" f="$2"; shift 2
  if [[ $# -eq 0 ]]; then : > "$d/tmp/$f"; else printf '%s\n' "$@" | sort -u > "$d/tmp/$f"; fi
}

run() { bash "$WORK/runner.sh" "${2:-$WORK/extracted.sh}" "$1"; }

removed() {
  # $1 = 情境目錄 → to_remove.txt 的內容（逗號分隔，空的印 "(none)"）
  local f="$1/tmp/to_remove.txt"
  if [[ -s "$f" ]]; then paste -sd, "$f"; else printf '(none)\n'; fi
}

slot_after() {
  # $1 = 情境目錄, $2 = 槽位編號 → 這次規劃後該槽位的內容
  local f="$1/tmp/newslot/$2.txt"
  if [[ -s "$f" ]]; then paste -sd, "$f"; else printf '(empty)\n'; fi
}

PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); echo "  ✅ $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  ❌ $1"; }
eq()  { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1（期望「$3」，實得「$2」）"; fi; }

echo "沒有來源失敗時的基準行為"

# ── 案例 1：全部來源成功 → 移除照常發生（頭號反事實） ────
# 「有來源失敗就什麼都不移除」的天真實作會通過所有押後案例，卻在這裡爆掉。
SC="$(scenario baseline)"
put_slot  "$SC" 1 a.example b.example gone.example
put_file  "$SC" merged_domains.txt a.example b.example
put_file  "$SC" desired.txt a.example b.example
st=$(run "$SC")
eq "全部來源成功 → 狀態 0" "$st" "0"
eq "全部來源成功 → 來源已拿掉的網域照常移除" "$(removed "$SC")" "gone.example"
eq "全部來源成功 → 槽位內容不含被移除的網域" "$(slot_after "$SC" 1)" "a.example,b.example"

echo "有來源失敗時"

# ── 案例 2：失敗來源獨有的網域 → 押後，不移除 ────────────
# gone.example 在 Gateway 上、不在本次合併結果裡 —— 因為裝著它的那個來源沒抓到。
SC="$(scenario held)"
put_slot  "$SC" 1 a.example b.example gone.example
put_file  "$SC" merged_domains.txt a.example b.example
put_file  "$SC" desired.txt a.example b.example
put_file  "$SC" failed_sources.txt 1Hosts-Lite
st=$(run "$SC")
eq "有來源失敗 → 狀態 0" "$st" "0"
eq "有來源失敗 → 不在合併結果裡的網域被押後，不移除" "$(removed "$SC")" "(none)"
eq "有來源失敗 → 那個網域仍留在槽位裡（Gateway 上不會被拿掉）" \
   "$(slot_after "$SC" 1)" "a.example,b.example,gone.example"
if grep -q '暫緩移除 1 筆' "$SC/warns.log" 2>/dev/null; then
  ok "有來源失敗 → warn 說明押後了幾筆"
else
  bad "有來源失敗 → 沒有 warn，操作者看不到押後這件事"
fi

# ── 案例 3：白名單造成的移除不可以被押後 ─────────────────
# white.example 出現在本次合併結果裡（來源還看得到它），是白名單把它從 desired
# 刷掉的 —— 那是使用者明確的意思，必須照做。
SC="$(scenario whitelist_still_applies)"
put_slot  "$SC" 1 a.example white.example
put_file  "$SC" merged_domains.txt a.example white.example
put_file  "$SC" desired.txt a.example
put_file  "$SC" failed_sources.txt 1Hosts-Lite
st=$(run "$SC")
eq "有來源失敗 → 白名單造成的移除仍然照做" "$(removed "$SC")" "white.example"
eq "有來源失敗 → 白名單網域確實離開槽位" "$(slot_after "$SC" 1)" "a.example"

# ── 案例 4：兩種移除同時存在 ─────────────────────────────
SC="$(scenario mixed)"
put_slot  "$SC" 1 a.example white.example gone.example
put_file  "$SC" merged_domains.txt a.example white.example
put_file  "$SC" desired.txt a.example
put_file  "$SC" failed_sources.txt 1Hosts-Lite
st=$(run "$SC")
eq "混合 → 只移除有把握的那一筆" "$(removed "$SC")" "white.example"
eq "混合 → 押後的那一筆留在槽位裡" "$(slot_after "$SC" 1)" "a.example,gone.example"

# ── 案例 5：新增不受押後影響 ─────────────────────────────
SC="$(scenario adds_unaffected)"
put_slot  "$SC" 1 a.example gone.example
put_file  "$SC" merged_domains.txt a.example new.example
put_file  "$SC" desired.txt a.example new.example
put_file  "$SC" failed_sources.txt 1Hosts-Lite
st=$(run "$SC")
eq "有來源失敗 → 新網域照常新增" "$(slot_after "$SC" 1)" "a.example,gone.example,new.example"
eq "有來源失敗 → 舊網域沒有被移除" "$(removed "$SC")" "(none)"

# ── 案例 6：沒有任何要押後的東西時不要亂 warn ────────────
SC="$(scenario nothing_to_hold)"
put_slot  "$SC" 1 a.example white.example
put_file  "$SC" merged_domains.txt a.example white.example
put_file  "$SC" desired.txt a.example
put_file  "$SC" failed_sources.txt 1Hosts-Lite
st=$(run "$SC")
if grep -q '暫緩移除' "$SC/warns.log" 2>/dev/null; then
  bad "沒有東西需要押後卻印了 warn（會變成每次都有的雜訊）"
else
  ok "沒有東西需要押後時不印 warn"
fi

# ── 案例 7：押後不會讓槽位被誤判成空的 ───────────────────
# 一份清單如果只裝著失敗來源的網域，押後之後它仍然是滿的，不可以進 empty_slots。
SC="$(scenario not_emptied)"
put_slot  "$SC" 1 a.example
put_slot  "$SC" 2 only.example
put_file  "$SC" merged_domains.txt a.example
put_file  "$SC" desired.txt a.example
put_file  "$SC" failed_sources.txt 1Hosts-Lite
st=$(run "$SC")
eq "押後 → 只裝著失敗來源網域的那份清單沒有變空" "$(slot_after "$SC" 2)" "only.example"
if grep -qx '2' "$SC/tmp/empty_slots.txt" 2>/dev/null; then
  bad "那份清單被標記成空的了 —— 下游會對它送出 DELETE"
else
  ok "那份清單沒有被標記成空的（不會被 DELETE）"
fi

# ══════════════════════════════════════════════════════════
# 反事實
# ══════════════════════════════════════════════════════════
echo "反事實"

mutate() {
  local name="$1"; shift
  cp "$WORK/extracted.sh" "$WORK/mut_$name.sh"
  local before after s
  before=$(md5sum < "$WORK/mut_$name.sh")
  for s in "$@"; do sed -i "$s" "$WORK/mut_$name.sh"; done
  after=$(md5sum < "$WORK/mut_$name.sh")
  if [[ "$before" == "$after" ]]; then
    echo "❌ 反事實 $name 沒有改到任何東西（錨點失效，這個反事實是假的）" >&2
    exit 2
  fi
  printf '%s\n' "$WORK/mut_$name.sh"
}

# A：拿掉押後（重現修正前的行為）
M="$(mutate no_hold 's|if \[\[ -s "\$TMP_DIR/failed_sources.txt" \&\& -s "\$TMP_DIR/merged_domains.txt" \]\]; then|if false; then|')"
SC="$(scenario cf_no_hold)"
put_slot  "$SC" 1 a.example gone.example
put_file  "$SC" merged_domains.txt a.example
put_file  "$SC" desired.txt a.example
put_file  "$SC" failed_sources.txt 1Hosts-Lite
st=$(run "$SC" "$M")
if [[ "$(removed "$SC")" == "gone.example" ]]; then
  ok "反事實 A（拿掉押後）→ 失敗來源獨有的網域被算成該移除，正是這一片要修的事"
else
  bad "反事實 A 沒有重現（實得移除「$(removed "$SC")」）"
fi

# B：押後改成「一律不移除」（會讓白名單永遠不生效）
M="$(mutate hold_all 's|comm -12 "\$to_remove_all" "\$TMP_DIR/merged_domains.txt" > "\$to_remove"|: > "$to_remove"|')"
SC="$(scenario cf_hold_all)"
put_slot  "$SC" 1 a.example white.example
put_file  "$SC" merged_domains.txt a.example white.example
put_file  "$SC" desired.txt a.example
put_file  "$SC" failed_sources.txt 1Hosts-Lite
st=$(run "$SC" "$M")
if [[ "$(removed "$SC")" == "(none)" ]]; then
  ok "反事實 B（押後改成一律不移除）→ 白名單造成的移除也被吃掉，案例 3 會抓到"
else
  bad "反事實 B 沒有重現（實得移除「$(removed "$SC")」）"
fi

echo
echo "通過 $PASS / 失敗 $FAIL"
[[ $FAIL -eq 0 ]]
