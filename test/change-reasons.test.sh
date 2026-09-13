#!/usr/bin/env bash
# 「偵測到變動」原因的顯示測試。
#
# 為什麼需要這支測試：原因以前是用 `paste -sd'；'` 接成一行。全形分號是 3 個位元組，而 paste -d
# 把參數當成「逐位元組輪流使用」的分隔符清單，每個接縫只吐一個位元組 —— 不是合法的 UTF-8，
# 日誌上顯示成「來源內容變動 AdGuard-DNS-filter�來源內容變動 easylist�…」。
# Ubuntu 的 coreutils 沒有多位元組修補，runner 上一定重現；本機的 paste 則可能不會，
# 所以這支測試不靠 paste 的行為，而是直接驗「輸出是合法 UTF-8」與分組後的確切內容。
#
# 另外釘住 Job Summary 的 Markdown 跳脫：變動原因表格與既有的失敗來源清單。
#
# 做法：從 sync.sh **抽出正在跑的函式**（不是抄一份平行實作）。全程離線。
#
# 用法：bash test/change-reasons.test.sh [repo 根目錄]
set -uo pipefail

ROOT="${1:-$(dirname "$0")/..}"
SYNC="$ROOT/sync.sh"
[[ -f "$SYNC" ]] || { echo "找不到 $SYNC" >&2; exit 2; }

for tool in awk sed grep tr head wc cmp diff iconv mktemp; do
  command -v "$tool" >/dev/null 2>&1 || { echo "❌ 缺少必要工具：$tool（不跳過，直接失敗）" >&2; exit 2; }
done
# iconv 本身要真的會拒絕不合法的 UTF-8，案例 1 才有意義
if printf 'ok\357\n' | iconv -f UTF-8 -t UTF-8 >/dev/null 2>&1; then
  echo "❌ 自我驗證失敗：這個環境的 iconv 不會拒絕不合法的 UTF-8" >&2; exit 2
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# ── 抽取 ──────────────────────────────────────────────────
tr -d '\r' < "$SYNC" > "$WORK/sync_lf.sh"

extract_fn() {
  awk -v fn="$1" '
    $0 == fn "() {"     { inside = 1 }
    inside              { print }
    inside && $0 == "}" { exit }
  ' "$WORK/sync_lf.sh"
}

HARNESS="$WORK/extracted.sh"
: > "$HARNESS"
for fn in d1_budget_left decide_should_sync md_escape render_change_reasons write_step_summary; do
  extract_fn "$fn" > "$WORK/fn.tmp"
  [[ -s "$WORK/fn.tmp" ]] || { echo "❌ 抽取失敗：找不到函式 $fn" >&2; exit 2; }
  [[ "$(tail -n 1 "$WORK/fn.tmp")" == "}" ]] || { echo "❌ 抽取失敗：$fn 的最後一行不是收尾大括號" >&2; exit 2; }
  cat "$WORK/fn.tmp" >> "$HARNESS"
  echo >> "$HARNESS"
done
grep -v '^[[:space:]]*#' "$HARNESS" | grep -q 'paste -sd' && { echo "❌ 自我驗證失敗：抽出來的程式裡還有 paste -sd" >&2; exit 2; }

# ── 執行器 ────────────────────────────────────────────────
cat > "$WORK/runner.sh" <<'RUNNEREOF'
#!/usr/bin/env bash
# $1 = 函式檔, $2 = 情境目錄, $3.. = 指令
set -uo pipefail
HARNESS="$1"; SC="$2"; shift 2
TMP_DIR="$SC/tmp"
FORCE_SYNC="${T_FORCE:-0}"
STATE_AVAILABLE="${T_STATE:-1}"
DEFERRED_BACKLOG="${T_BACKLOG:-0}"
D1_DAILY_WRITE_BUDGET=90000; D1_WRITES_TODAY=0; D1_WRITES_ADDED=0
UPLOAD_STAT_UPLOADED=1; UPLOAD_STAT_SKIPPED=2; UPLOAD_STAT_FAILED=0; UPLOAD_STAT_TOTAL=3
CACHE_SOURCE=kv; CACHE_BLOB_BYTES=0; CACHE_BLOB_ROWS=0; DEFERRED_CACHE_ROWS=0
GITHUB_STEP_SUMMARY="$SC/summary.md"
# 讓 Windows 上的 grep／awk／sed 也呈現 Linux 的 CR 語意（見 test/crlf-source-parsing.test.sh）
grep() { command grep -U "$@"; }
awk()  { command awk -v BINMODE=3 "$@"; }
sed()  { command sed -b "$@"; }
# shellcheck disable=SC1090
source "$HARNESS"
case "$1" in
  decide)  decide_should_sync "$SC/prev.txt" "$2" "$3" ;;
  *)       "$@" ;;
esac
RUNNEREOF

WL=wl-sum; BL=bl-sum

new_sc() {
  # $1 = 標籤 → 情境目錄（前次狀態只含白名單／自訂封鎖清單的 checksum）
  local d="$WORK/sc/$1"
  rm -rf "$d"; mkdir -p "$d/tmp"
  printf 'whitelist\t%s\nblocklist\t%s\n' "$WL" "$BL" > "$d/prev.txt"
  : > "$d/tmp/failed_sources.txt"; : > "$d/tmp/source_checksums.txt"
  echo "$d"
}
prev_src()  { printf 'src:%s\t%s\n' "$2" "$3" >> "$1/prev.txt"; }
now_src()   { printf '%s\t%s\n' "$2" "$3" >> "$1/tmp/source_checksums.txt"; }
failed()    { printf '%s\n' "$2" >> "$1/tmp/failed_sources.txt"; }
decide()    {
  # $1 = 函式檔, $2 = 情境, $3 = 白名單 checksum → 輸出寫進 reasons.txt、回傳碼寫進 rc
  local h="$1" d="$2" wl="${3:-$WL}"
  bash "$WORK/runner.sh" "$h" "$d" decide "$wl" "$BL" > "$d/reasons.txt"
  echo $? > "$d/rc"
}
render()    { bash "$WORK/runner.sh" "$1" "$2" render_change_reasons "$3" < "$2/reasons.txt"; }
utf8_ok()   { iconv -f UTF-8 -t UTF-8 < "$1" > /dev/null 2>&1; }
lines_eq()  {
  # $1 = 實得檔案, 其餘 = 預期的每一行
  local got="$1"; shift
  printf '%s\n' "$@" > "$got.expected"
  cmp -s "$got" "$got.expected"
}

PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); echo "  ✅ $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  ❌ $1"; }
check() { local desc="$1"; shift; if "$@"; then ok "$desc"; else bad "$desc"; fi; }

TW='台灣165反詐騙提供'

three_changed_sc() {
  local d; d=$(new_sc "$1")
  prev_src "$d" AdGuard-DNS-filter 1; prev_src "$d" easylist 1; prev_src "$d" "$TW" 1
  now_src "$d" AdGuard-DNS-filter 2;  now_src "$d" easylist 2;  now_src "$d" "$TW" 2
  echo "$d"
}

case_1() {
  local h="$1" d; d=$(three_changed_sc c1)
  now_src "$d" brand-new 9
  decide "$h" "$d"
  render "$h" "$d" log > "$d/log.txt"
  render "$h" "$d" md > "$d/md.txt"
  # 前提：輸出真的有多個原因接在同一行（有「、」這個多位元組接縫），才驗得到接縫
  grep -q '、' "$d/log.txt" && grep -q '、' "$d/md.txt" || return 1
  utf8_ok "$d/log.txt" && utf8_ok "$d/md.txt"
}

case_2() {
  local h="$1" d; d=$(three_changed_sc c2)
  decide "$h" "$d"
  render "$h" "$d" log > "$d/log.txt"
  lines_eq "$d/log.txt" "  - 來源內容變動（3）：AdGuard-DNS-filter、easylist、$TW"
}

interleaved_sc() {
  local d; d=$(new_sc "$1")
  prev_src "$d" c1 1; prev_src "$d" c2 1
  now_src "$d" n1 1; now_src "$d" c1 2; now_src "$d" n2 1; now_src "$d" c2 2
  echo "$d"
}

case_3() {
  local h="$1" d; d=$(interleaved_sc c3)
  decide "$h" "$d" changed-wl
  render "$h" "$d" log > "$d/log.txt"
  lines_eq "$d/log.txt" "  - 新增來源（2）：n1、n2" "  - 來源內容變動（2）：c1、c2" "  - 白名單有變動"
}

case_4() {
  local h="$1" d; d=$(new_sc c4)
  prev_src "$d" a 1; now_src "$d" a 1
  decide "$h" "$d" changed-wl
  render "$h" "$d" log > "$d/log.txt"
  lines_eq "$d/log.txt" "  - 白名單有變動" && ! grep -q '[：（]' "$d/log.txt"
}

case_5() {
  local h="$1" d; d=$(interleaved_sc c5)
  decide "$h" "$d" changed-wl
  render "$h" "$d" md > "$d/md.txt"
  lines_eq "$d/md.txt" "| 變動類型 | 項目 |" "|---|---|" "| 新增來源 | n1、n2 |" "| 來源內容變動 | c1、c2 |" "| 白名單有變動 | — |"
}

case_6() {
  local h="$1" d; d=$(new_sc c6)
  prev_src "$d" a 1; prev_src "$d" b 1
  now_src "$d" a 2; now_src "$d" b 2
  T_BACKLOG=5 decide "$h" "$d" changed-wl
  render "$h" "$d" md > "$d/md.txt"
  lines_eq "$d/md.txt" "| 變動類型 | 項目 |" "|---|---|" "| 來源內容變動 | a、b |" "| 白名單有變動 | — |" "| 積欠的分類快取待補寫 | 5 筆 |"
}

case_7() {
  local h="$1" d n; d=$(new_sc c7)
  T_FORCE=1 decide "$h" "$d"
  [[ "$(cat "$d/rc")" == "0" ]] || return 1
  n=$(wc -l < "$d/reasons.txt" | tr -d ' ')
  [[ "$n" == "1" ]] && grep -q "$(printf '\t')" "$d/reasons.txt" || return 1
  render "$h" "$d" log > "$d/log.txt"
  render "$h" "$d" md > "$d/md.txt"
  lines_eq "$d/log.txt" "  - 強制同步（1）：FORCE_SYNC=1，略過閘門" \
    && lines_eq "$d/md.txt" "| 變動類型 | 項目 |" "|---|---|" '| 強制同步 | FORCE\_SYNC=1，略過閘門 |'
}

case_8() {
  local h="$1" d; d=$(new_sc c8)
  prev_src "$d" a 1; now_src "$d" a 1
  decide "$h" "$d"
  [[ "$(cat "$d/rc")" == "1" && ! -s "$d/reasons.txt" ]]
}

case_9() {
  local h="$1" d; d=$(new_sc c9)
  prev_src "$d" a 1; now_src "$d" a 2
  decide "$h" "$d"
  [[ "$(cat "$d/rc")" == "0" && -s "$d/reasons.txt" ]]
}

case_10() {
  local h="$1" d; d=$(new_sc c10)
  prev_src "$d" ok-src 1; prev_src "$d" broken 1
  now_src "$d" ok-src 2;  now_src "$d" broken 2
  failed "$d" broken
  decide "$h" "$d"
  render "$h" "$d" log > "$d/log.txt"
  lines_eq "$d/log.txt" "  - 來源內容變動（1）：ok-src"
}

case_11() {
  local h="$1" d; d=$(new_sc c11)
  prev_src "$d" "$TW" 1; now_src "$d" "$TW" 2
  decide "$h" "$d"
  render "$h" "$d" log > "$d/log.txt"
  render "$h" "$d" md > "$d/md.txt"
  lines_eq "$d/log.txt" "  - 來源內容變動（1）：$TW" && grep -qF "| 來源內容變動 | $TW |" "$d/md.txt" \
    && utf8_ok "$d/log.txt" && utf8_ok "$d/md.txt"
}

case_12() {
  local h="$1" d; d=$(new_sc c12)
  {
    printf '來源內容變動\t%s\n' 'x|y' '<script>' 'a`b' '[x](y)' '![](z)' '*_~' 'c\d' 'q&r'
  } > "$d/reasons.txt"
  render "$h" "$d" md > "$d/md.txt"
  lines_eq "$d/md.txt" "| 變動類型 | 項目 |" "|---|---|" \
    '| 來源內容變動 | x\|y、&lt;script&gt;、a\`b、\[x\]\(y\)、\!\[\]\(z\)、\*\_\~、c\\d、q&amp;r |' || return 1
  ! grep -q '<script>' "$d/md.txt"
}

case_13() {
  local h="$1" d; d=$(new_sc c13)
  printf '%s\n' '<script>' '[x](y)' '![](z)' 'a`b' '*_~' "$TW" > "$d/tmp/failed_sources.txt"
  printf '來源內容變動\tfine\n' > "$d/reasons.txt"
  bash "$WORK/runner.sh" "$h" "$d" write_step_summary success 1 1 "$(cat "$d/reasons.txt")" || return 1
  grep -q '<script>' "$d/summary.md" && return 1
  local want
  for want in '- &lt;script&gt;' '- \[x\]\(y\)' '- \!\[\]\(z\)' '- a\`b' '- \*\_\~' "- $TW"; do
    grep -qxF -- "$want" "$d/summary.md" || return 1
  done
  # 成功分支的標題不再夾原因字串，原因以表格呈現
  grep -qxF '✅ **同步完成**' "$d/summary.md" && grep -qxF '| 來源內容變動 | fine |' "$d/summary.md"
}

run_all_cases() {
  local h="$1"
  check "1. 多個來源變動：log 與 md 兩種輸出都是合法 UTF-8" case_1 "$h"
  check "2. 3 個來源內容變動：log 只有一行「來源內容變動（3）：…」" case_2 "$h"
  check "3. 多種類型交錯：依類型分組並保留第一次出現的順序" case_3 "$h"
  check "4. 白名單有變動：無冒號、無計數" case_4 "$h"
  check "5. md：表頭＋分隔列＋每類型一列，空項目為 —" case_5 "$h"
  check "6. 來源＋白名單＋積欠混合：各類各一列" case_6 "$h"
  check "7. FORCE_SYNC=1 提早返回：一行結構化輸出，可渲染" case_7 "$h"
  check "8. 無變動：回傳 1 且輸出為空" case_8 "$h"
  check "9. 有變動：回傳 0" case_9 "$h"
  check "10. 抓取失敗的來源不列入變動" case_10 "$h"
  check "11. 中文來源名 $TW 位元組不變" case_11 "$h"
  check "12. md 模式跳脫 |、<script>、\`、[x](y)、![](z)、*_~、\\、&" case_12 "$h"
  check "13. Job Summary 的失敗來源清單同樣跳脫" case_13 "$h"
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

# 刻意不用「把 paste 放回去」當反事實：它會不會拆位元組因平台而異。直接注入一個單獨的 0xEF。
M=$(mutate lone_ef render_change_reasons <<'EOF'
        else if (cnt[t]) print "  - " t "（" cnt[t] "）：" items[t]
        else if (cnt[t]) print "  - " t "（" cnt[t] "）：" items[t] "\357"
EOF
) || exit 2
expect_red "往輸出注入單獨的 \\xEF" "$M" 1

M=$(mutate no_grouping render_change_reasons <<'EOF'
      if (!(t in seen)) { seen[t] = 1; order[++n] = t; cnt[t] = 0; items[t] = "" }
      if (1) { seen[t] = 1; order[++n] = t; cnt[t] = 0; items[t] = "" }
EOF
) || exit 2
expect_red "拿掉分組" "$M" 2

M=$(mutate output_when_unchanged decide_should_sync <<'EOF'
  return 1
  printf '%s\t\n' "無變動"; return 1
EOF
) || exit 2
expect_red "無變動仍輸出" "$M" 8

M=$(mutate no_lt_escape md_escape <<'EOF'
    -e 's/</\&lt;/g' \
@@DELETE@@
EOF
) || exit 2
expect_red "拿掉 < 跳脫" "$M" 12

M=$(mutate failed_list_raw write_step_summary <<'EOF'
      md_escape < "$TMP_DIR/failed_sources.txt" | sed 's/^/- /'
      sed 's/^/- /' "$TMP_DIR/failed_sources.txt"
EOF
) || exit 2
expect_red "失敗清單不經 md_escape" "$M" 13

echo
echo "通過 $PASS / 失敗 $FAIL"
[[ $FAIL -eq 0 ]]
