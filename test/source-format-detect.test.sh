#!/usr/bin/env bash
# 來源格式自動偵測的測試。
#
# 為什麼需要這支測試：格式只能從內容判斷（台灣廣告過濾的網址是 hosts_abp.txt，內容卻是 adblock），
# 而這套解析器有反覆誤判的歷史（||youtube.com^$removeparam=pp 曾讓 YouTube 全站被擋）。
# 所以偵測刻意不引入任何新的解析邏輯：用正在跑的三個解析器各解析一次，解析出最多網域的勝出。
#
# 這支測試要釘住的是：
#   * 明確寫出的格式完全不偵測（硬性覆寫），打錯的格式照舊拒絕，不會被默默改成自動偵測
#   * 偵測的候選輸出不會外洩到 $TMP_DIR 最上層 —— build_merged 是 cat parsed_*.txt
#
# 做法：從 sync.sh **抽出正在跑的函式**（不是抄一份平行實作）。全程離線。
#
# 用法：bash test/source-format-detect.test.sh [repo 根目錄]
set -uo pipefail

ROOT="${1:-$(dirname "$0")/..}"
SYNC="$ROOT/sync.sh"
[[ -f "$SYNC" ]] || { echo "找不到 $SYNC" >&2; exit 2; }

for tool in awk sed grep tr head tail wc cmp diff sort sha256sum mktemp; do
  command -v "$tool" >/dev/null 2>&1 || { echo "❌ 缺少必要工具：$tool（不跳過，直接失敗）" >&2; exit 2; }
done

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# ── 抽取 ──────────────────────────────────────────────────
# 只對「腳本本身」剝 CR 以供 awk 抽取。fixture 絕對不經過這一步。
tr -d '\r' < "$SYNC" > "$WORK/sync_lf.sh"

extract_fn() {
  awk -v fn="$1" '
    $0 == fn "() {"     { inside = 1 }
    inside              { print }
    inside && $0 == "}" { exit }
  ' "$WORK/sync_lf.sh"
}

build_harness() {
  # $1 = 輸出檔, $2 = 要抽的頂層變數（regex 選項）
  local out="$1" vars="$2" fn
  : > "$out"
  grep -E "^($vars)=" "$WORK/sync_lf.sh" >> "$out"
  for fn in parse_domains parse_adblock parse_hosts parse_source_into _detect_and_parse build_merged; do
    extract_fn "$fn" > "$WORK/fn.tmp"
    [[ -s "$WORK/fn.tmp" ]] || { echo "❌ 抽取失敗：找不到函式 $fn" >&2; exit 2; }
    [[ "$(tail -n 1 "$WORK/fn.tmp")" == "}" ]] || { echo "❌ 抽取失敗：$fn 的最後一行不是收尾大括號" >&2; exit 2; }
    cat "$WORK/fn.tmp" >> "$out"
    echo >> "$out"
  done
}

harness_valid() {
  # 抽出來的 DOMAIN_REGEX 與 IPV4_REGEX 都不能是空的：
  # 漏 DOMAIN_REGEX 時 grep -E "" 放行每一行；漏 IPV4_REGEX 在 set -u 下報錯。
  # shellcheck disable=SC1090
  ( set -u; source "$1"; [[ -n "${DOMAIN_REGEX:-}" && -n "${IPV4_REGEX:-}" ]] ) 2>/dev/null
}

HARNESS="$WORK/extracted.sh"
build_harness "$HARNESS" 'DOMAIN_REGEX|IPV4_REGEX'
harness_valid "$HARNESS" || { echo "❌ 抽取自我驗證失敗：DOMAIN_REGEX／IPV4_REGEX 是空的" >&2; exit 2; }

# ── 執行器 ────────────────────────────────────────────────
cat > "$WORK/runner.sh" <<'RUNNEREOF'
#!/usr/bin/env bash
# $1 = 函式檔, $2 = 情境目錄, $3.. = 要呼叫的函式與參數
set -uo pipefail
HARNESS="$1"; SC="$2"; shift 2
TMP_DIR="$SC/tmp"
# 讓 Windows 上的 grep／awk／sed 也呈現 Linux 的 CR 語意（見 test/crlf-source-parsing.test.sh）
grep() { command grep -U "$@"; }
awk()  { command awk -v BINMODE=3 "$@"; }
sed()  { command sed -b "$@"; }
log()  { echo "log: $*" >> "$SC/log"; }
warn() { echo "warn: $*" >> "$SC/log"; }
# shellcheck disable=SC1090
source "$HARNESS"
"$@"
RUNNEREOF

new_sc() {
  local d="$WORK/sc/$1"
  rm -rf "$d"; mkdir -p "$d/tmp"; : > "$d/log"
  echo "$d"
}
run() { local h="$1" d="$2"; shift 2; bash "$WORK/runner.sh" "$h" "$d" "$@"; }
parse_into() {
  # $1 = 函式檔, $2 = 情境, $3 = 來源名, $4 = 格式, $5 = raw → 輸出目錄是 tmp/fetch_<name>/m1（跟正式流程相同的位置）
  local h="$1" d="$2" name="$3" fmt="$4" raw="$5"
  mkdir -p "$d/tmp/fetch_$name/m1"
  run "$h" "$d" parse_source_into "$name" "$fmt" "$raw" "$d/tmp/fetch_$name/m1"
}
outdir() { printf '%s/tmp/fetch_%s/m1' "$1" "$2"; }
warns() { local n; n=$(grep -c '^warn:' "$1/log") || n=0; echo "$n"; }

# ── fixture ───────────────────────────────────────────────
FX="$WORK/fx"; mkdir -p "$FX"
printf '[Adblock Plus 2.0]\n! Title: t\n||a1.example^\n||a2.example^$third-party\n||a3.example^\n' > "$FX/adblock"
printf '# hosts\n127.0.0.1 localhost\n0.0.0.0 h1.example\n0.0.0.0 h2.example\n' > "$FX/hosts"
printf '# domains\nd1.example\n*.d2.example\nd3.example\n' > "$FX/domains"
printf '! nothing here\n# nor here\n\n' > "$FX/zero"
# 混合：10 條 adblock ＋ 2 行純網域（次高 2 ≥ 10 的 10%）
{ echo '[Adblock Plus 2.0]'; for i in $(seq 1 10); do echo "||mix$i.example^"; done; echo 'plain1.example'; echo 'plain2.example'; } > "$FX/mixed"
# 誤判陷阱 ＋ 足量正常規則
{
  echo '[Adblock Plus 2.0]'
  echo '||youtube.com^$removeparam=pp'
  echo '||x.com^*/ads.js'
  echo '@@||a.com^'
  echo 'example.com##.ad'
  echo '||b.com^$badfilter'
  for i in $(seq 1 8); do echo "||trapkeep$i.example^"; done
} > "$FX/trap"
# 候選不外洩：adblock 為主，但 parse_domains 也撈得到 1 筆（次高 1 < 20 的 10%，不會觸發警告）
{ echo '[Adblock Plus 2.0]'; for i in $(seq 1 20); do echo "||leakkeep$i.example^"; done; echo 'leak-only-domains.example'; } > "$FX/leak"

# fixture 自我驗證：各解析器對各 fixture 的筆數要符合設計
count_of() { run "$HARNESS" "$WORK" "parse_$1" < "$2" | wc -l | tr -d ' '; }
mkdir -p "$WORK/tmp"
expect_counts() {
  # $1 = fixture, $2 $3 $4 = adblock hosts domains 的預期筆數
  local f="$1" a h dm
  a=$(count_of adblock "$FX/$f"); h=$(count_of hosts "$FX/$f"); dm=$(count_of domains "$FX/$f")
  [[ "$a $h $dm" == "$2 $3 $4" ]] || { echo "❌ fixture 錯誤：$f 的筆數（adblock hosts domains）應為「$2 $3 $4」，實得「$a $h $dm」" >&2; exit 2; }
}
expect_counts adblock 3 0 0
expect_counts hosts   0 2 0
expect_counts domains 0 0 3
expect_counts zero    0 0 0
expect_counts mixed   10 0 2
expect_counts trap    8 0 0
expect_counts leak    20 0 1

PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); echo "  ✅ $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  ❌ $1"; }
check() { local desc="$1"; shift; if "$@"; then ok "$desc"; else bad "$desc"; fi; }

same_as_parser() {
  # $1 = 函式檔, $2 = 情境, $3 = 來源名, $4 = 解析器格式, $5 = raw
  run "$1" "$2" "parse_$4" < "$5" > "$2/expected"
  cmp -s "$2/expected" "$(outdir "$2" "$3")/parsed.txt"
}
fmt_is() { [[ "$(cat "$(outdir "$1" "$2")/fmt.txt" 2>/dev/null)" == "$3" ]]; }

explicit_case() {
  # $1 = 函式檔, $2 = 格式
  local h="$1" f="$2" d; d=$(new_sc "explicit_$f")
  parse_into "$h" "$d" s "$f" "$FX/$f" || return 1
  same_as_parser "$h" "$d" s "$f" "$FX/$f" && fmt_is "$d" s "$f" && [[ "$(warns "$d")" == "0" ]]
}
case_1() { explicit_case "$1" adblock; }
case_2() { explicit_case "$1" hosts; }
case_3() { explicit_case "$1" domains; }

auto_case() {
  local h="$1" f="$2" d; d=$(new_sc "auto_$f")
  parse_into "$h" "$d" s auto "$FX/$f" || return 1
  fmt_is "$d" s "$f" && same_as_parser "$h" "$d" s "$f" "$FX/$f" \
    && [[ "$(cat "$(outdir "$d" s)/sum.txt")" == "$(sha256sum < "$d/expected" | awk '{print $1}')" ]]
}
case_4() { auto_case "$1" adblock; }
case_5() { auto_case "$1" hosts; }
case_6() { auto_case "$1" domains; }

case_7() {
  local h="$1" f d1 d2
  for f in adblock hosts domains zero; do
    d1=$(new_sc "blank_$f"); d2=$(new_sc "blankauto_$f")
    parse_into "$h" "$d1" s "" "$FX/$f" || return 1
    parse_into "$h" "$d2" s auto "$FX/$f" || return 1
    cmp -s "$(outdir "$d1" s)/parsed.txt" "$(outdir "$d2" s)/parsed.txt" || return 1
    cmp -s "$(outdir "$d1" s)/fmt.txt" "$(outdir "$d2" s)/fmt.txt" || return 1
  done
}

case_8() {
  local h="$1" d; d=$(new_sc unknown)
  parse_into "$h" "$d" s auto "$FX/zero" || return 1
  fmt_is "$d" s unknown && [[ ! -s "$(outdir "$d" s)/parsed.txt" && -f "$(outdir "$d" s)/parsed.txt" ]] \
    && [[ "$(warns "$d")" == "1" ]] && grep -q 'unknown' "$d/log"
}

case_9() {
  local h="$1" d; d=$(new_sc override)
  parse_into "$h" "$d" s hosts "$FX/adblock" || return 1
  fmt_is "$d" s hosts && [[ -f "$(outdir "$d" s)/parsed.txt" && ! -s "$(outdir "$d" s)/parsed.txt" ]]
}

case_10() {
  local h="$1" d; d=$(new_sc typo)
  parse_into "$h" "$d" s adbock "$FX/adblock" && return 1
  # 不走偵測：輸出目錄裡什麼都沒有
  [[ -z "$(ls -A "$(outdir "$d" s)")" ]]
}

case_11() {
  local h="$1" d; d=$(new_sc mixed)
  parse_into "$h" "$d" s auto "$FX/mixed" || return 1
  fmt_is "$d" s adblock && same_as_parser "$h" "$d" s adblock "$FX/mixed" && [[ "$(warns "$d")" == "1" ]]
}

case_12() {
  local h="$1" d f
  for f in adblock auto; do
    d=$(new_sc "location_$f")
    parse_into "$h" "$d" s "$f" "$FX/adblock" || return 1
    # 最上層只有測試自己建立的 fetch_s，沒有任何新檔案
    [[ "$(ls -A "$d/tmp")" == "fetch_s" ]] || return 1
    [[ -s "$(outdir "$d" s)/parsed.txt" && -s "$(outdir "$d" s)/sum.txt" && -s "$(outdir "$d" s)/fmt.txt" ]] || return 1
  done
}

case_13() {
  local h="$1" d dom; d=$(new_sc trap)
  parse_into "$h" "$d" s auto "$FX/trap" || return 1
  fmt_is "$d" s adblock || return 1
  for dom in youtube.com x.com a.com b.com example.com; do
    grep -qxF "$dom" "$(outdir "$d" s)/parsed.txt" && return 1
  done
  grep -qxF trapkeep1.example "$(outdir "$d" s)/parsed.txt"
}

promote() {
  # 模擬 fetch_source_with_fallback 在嘗試成功後的升級
  local d="$1" name="$2" o; o=$(outdir "$1" "$2")
  mv -f "$o/parsed.txt" "$d/tmp/parsed_$name.txt"
  mv -f "$o/sum.txt" "$d/tmp/sum_$name.txt"
  mv -f "$o/fmt.txt" "$d/tmp/fmt_$name.txt"
}

case_14() {
  local h="$1" d; d=$(new_sc leak)
  parse_into "$h" "$d" s14 auto "$FX/leak" || return 1
  [[ ! -e "$(outdir "$d" s14)/detect" ]] || return 1
  [[ "$(cat "$(outdir "$d" s14)/fmt.txt")" == "adblock" ]] || return 1
  promote "$d" s14
  [[ "$(cd "$d/tmp" && ls parsed_*.txt 2>/dev/null)" == "parsed_s14.txt" ]] || return 1
  run "$h" "$d" build_merged > "$d/merged"
  run "$h" "$d" parse_adblock < "$FX/leak" | sort -u > "$d/expected_merged"
  cmp -s "$d/merged" "$d/expected_merged"
}

case_15() {
  local h="$1" d; d=$(new_sc leak_unknown)
  parse_into "$h" "$d" s15 auto "$FX/zero" || return 1
  [[ ! -e "$(outdir "$d" s15)/detect" ]] || return 1
  promote "$d" s15
  [[ "$(cd "$d/tmp" && ls parsed_*.txt 2>/dev/null)" == "parsed_s15.txt" ]]
}

run_all_cases() {
  local h="$1"
  check "1. 明確 adblock：輸出與 parse_adblock 位元組相同" case_1 "$h"
  check "2. 明確 hosts：輸出與 parse_hosts 位元組相同" case_2 "$h"
  check "3. 明確 domains：輸出與 parse_domains 位元組相同" case_3 "$h"
  check "4. auto × adblock 內容：判定 adblock，輸出位元組相同" case_4 "$h"
  check "5. auto × hosts 內容：判定 hosts，輸出位元組相同" case_5 "$h"
  check "6. auto × domains 內容：判定 domains，輸出位元組相同" case_6 "$h"
  check "7. 空白格式與 auto 的輸出、判定完全相同" case_7 "$h"
  check "8. auto × 三個解析器都 0 筆：unknown、0 筆、回傳 0、有 warn" case_8 "$h"
  check "9. 明確 hosts × adblock 內容：0 筆，不被偵測糾正" case_9 "$h"
  check "10. 打錯的 adbock：回傳 1，不走偵測" case_10 "$h"
  check "11. 混合內容（次高 ≥ 10%）：有 warn，仍用勝出者" case_11 "$h"
  check "12. 輸出位置：只寫輸出目錄，最上層沒有任何新檔案" case_12 "$h"
  check "13. 誤判陷阱 × auto：判定 adblock，不含 youtube.com／x.com／a.com／b.com" case_13 "$h"
  check "14. 候選不外洩：detect/ 已刪，最上層只有 parsed_<name>.txt，build_merged 與 parse_adblock 相同" case_14 "$h"
  check "15. 候選不外洩 × unknown：無殘留 detect/、無多出的 parsed_*.txt" case_15 "$h"
}

run_all_cases "$HARNESS"

# ══════════════════════════════════════════════════════════
# 反事實：每一個變異都必須讓對應案例變紅
# ══════════════════════════════════════════════════════════
echo "反事實"

mutate() {
  # $1 = 變異代號, $2 = 函式名；stdin 兩行：要改寫的那一行（完全比對）、改成什麼（@@DELETE@@ = 刪除）
  local id="$1" fn="$2" from to out="$WORK/mut_$1.sh"
  IFS= read -r from; IFS= read -r to
  # 字串一律經 ENVIRON 傳進 awk，不用 -v：awk -v 會處理跳脫序列。
  MUT_FN="$fn" MUT_FROM="$from" MUT_TO="$to" command awk '
    $0 == ENVIRON["MUT_FN"] "() {" { inside = 1 }
    inside && !done && $0 == ENVIRON["MUT_FROM"] {
      done = 1
      if (ENVIRON["MUT_TO"] != "@@DELETE@@") print ENVIRON["MUT_TO"]
      next
    }
    { print }
    inside && $0 == "}" { inside = 0 }
  ' "$HARNESS" > "$out"
  if cmp -s "$HARNESS" "$out"; then
    echo "❌ 反事實 $id 沒有改到任何東西：$fn 裡找不到「$from」（錨點失效，這個反事實是假的）" >&2
    exit 2
  fi
  local changed
  # diff 有差異時回傳 1，在 pipefail 下會讓整條管線失敗，所以先吞掉它的離開狀態
  changed=$({ diff "$HARNESS" "$out" || :; } | grep -c '^[<>]') || changed=0
  if [[ "$to" == "@@DELETE@@" ]]; then [[ "$changed" == "1" ]]; else [[ "$changed" == "2" ]]; fi \
    || { echo "❌ 反事實 $id 改到的不只一行（$changed）" >&2; exit 2; }
  printf '%s\n' "$out"
}

expect_red() {
  local desc="$1" m="$2"; shift 2
  local c
  for c in "$@"; do
    if "case_$c" "$m"; then bad "反事實 $desc：案例 $c 仍然是綠的"; else ok "反事實 $desc → 案例 $c 變紅"; fi
  done
}

M=$(mutate always_domains _detect_and_parse <<'EOF'
    mv -f "$det/$best.txt" "$out_dir/parsed.txt"
    best=domains; mv -f "$det/$best.txt" "$out_dir/parsed.txt"
EOF
) || exit 2
expect_red "一律 domains" "$M" 4

M=$(mutate no_override parse_source_into <<'EOF'
    hosts)   parse_hosts   < "$raw_file" > "$parsed_file" ;;
    hosts)   _detect_and_parse "$name" "$raw_file" "$out_dir" || return 1 ;;
EOF
) || exit 2
expect_red "拿掉明確覆寫（hosts 也走偵測）" "$M" 9

M=$(mutate typo_detects parse_source_into <<'EOF'
    *) return 1 ;;
    *) _detect_and_parse "$name" "$raw_file" "$out_dir" || return 1 ;;
EOF
) || exit 2
expect_red "打錯字進偵測" "$M" 10

M=$(mutate pick_fewest _detect_and_parse <<'EOF'
    if [[ -z "$best" || $n -gt $best_n ]]; then
    if [[ -z "$best" || $n -lt $best_n ]]; then
EOF
) || exit 2
expect_red "取最少" "$M" 4 5 6

# 拿掉 DOMAIN_REGEX 抽取 → 抽取自我驗證必須失敗（exit 2 的那一道）
build_harness "$WORK/mut_no_domain_regex.sh" 'IPV4_REGEX'
if harness_valid "$WORK/mut_no_domain_regex.sh"; then
  bad "反事實 拿掉 DOMAIN_REGEX 抽取：自我驗證仍然通過"
else
  ok "反事實 拿掉 DOMAIN_REGEX 抽取 → 自我驗證失敗（exit 2）"
fi

M=$(mutate candidates_top _detect_and_parse <<'EOF'
    "parse_$fmt" < "$raw_file" > "$det/$fmt.txt"
    "parse_$fmt" < "$raw_file" | tee "$TMP_DIR/parsed_$name.$fmt.txt" > "$det/$fmt.txt"
EOF
) || exit 2
expect_red "候選寫到最上層 parsed_<name>.<格式>.txt" "$M" 14

M=$(mutate keep_detect _detect_and_parse <<'EOF'
  rm -rf "$det"
@@DELETE@@
EOF
) || exit 2
expect_red "拿掉刪除 detect/" "$M" 14 15

M=$(mutate parse_top_level parse_source_into <<'EOF'
  local parsed_file="$out_dir/parsed.txt"
  local parsed_file="$TMP_DIR/parsed_$name.txt"
EOF
) || exit 2
expect_red "parse_source_into 直接寫最上層" "$M" 12

echo
echo "通過 $PASS / 失敗 $FAIL"
[[ $FAIL -eq 0 ]]
