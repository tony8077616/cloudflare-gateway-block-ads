#!/usr/bin/env bash
# 白名單扣除的回歸測試。
#
# 為什麼有這支測試：sync.sh 的白名單扣除曾經在「白名單是空的」時把整份合併清單
# 扣光（awk 的 NR==FNR 兩檔慣用法碰到空的第一個檔案會失效）。那個 bug 能無聲出貨，
# 是因為當時的比對測試有 15 組案例、但每一組的白名單都非空，而且測試本身沒有進 repo。
# 全新安裝的 custom_whitelist 就是空的，所以那條路徑是第一次同步必經的。
#
# 這支測試直接從 sync.sh 抽出「正在跑的那一段」來執行，而不是抄一份平行實作 ——
# 抄的那份不會跟著 sync.sh 一起改，測過也不代表出貨的程式是對的。
#
# 用法：bash test/whitelist-empty.test.sh [sync.sh 的路徑]
set -uo pipefail

SYNC="${1:-$(dirname "$0")/../sync.sh}"
[[ -f "$SYNC" ]] || { echo "找不到 $SYNC" >&2; exit 2; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# ── 抽取 ──────────────────────────────────────────────
# 抽出「local after_whitelist_file=...」到「local whitelisted_count」之間那一段。
# 這兩個錨點在修正前後都存在，所以同一支測試可以同時跑新舊版本（反事實驗證）。
sed -n '/^  local after_whitelist_file=/,/^  local whitelisted_count$/p' "$SYNC" \
  | sed '$d' > "$WORK/block.sh"

if [[ ! -s "$WORK/block.sh" ]]; then
  echo "❌ 抽取失敗：在 $SYNC 裡找不到白名單扣除區塊（錨點可能被改動了）" >&2
  exit 2
fi

# 區塊裡有 local，必須包在函式裡才能執行。
{
  echo 'run_block() {'
  cat "$WORK/block.sh"
  echo '  cat "$after_whitelist_file"'
  echo '}'
} > "$WORK/harness.sh"

# shellcheck disable=SC1090
if ! source "$WORK/harness.sh" 2>"$WORK/src_err"; then
  echo "❌ 抽出來的區塊無法載入（語法錯誤）：" >&2
  cat "$WORK/src_err" >&2
  exit 2
fi

TMP_DIR="$WORK"

run_case() {
  # $1 = 白名單內容（空字串代表空白名單）, $2 = merged 內容
  printf '%s' "$1" > "$WORK/wl.txt"
  printf '%s' "$2" > "$WORK/merged.txt"
  whitelist_file="$WORK/wl.txt"
  merged_file="$WORK/merged.txt"
  run_block
}

MERGED='ads.example.com
cdn.foo.org
example.com
sub.example.com
tracker.net
'

# ── 抽取自我驗證 ──────────────────────────────────────
# 先確認抽出來的程式真的跑得動、而且會產生非空輸出。
# 少了這一步，一次抽壞（例如把收尾的大括號一起刪掉）會讓 awk 靜靜吐出空輸出，
# 於是每一組「應該被過濾掉」的斷言都會意外通過，整組測試變成假的全綠。
probe="$(run_case 'tracker.net
' "$MERGED")"
if [[ -z "$probe" ]]; then
  echo "❌ 抽取自我驗證失敗：已知非空的案例卻得到空輸出，抽出來的程式沒有正常執行" >&2
  exit 2
fi

PASS=0; FAIL=0
check() {
  # $1 = 案例名, $2 = 白名單, $3 = 預期輸出
  local name="$1" wl="$2" want="$3" got
  got="$(run_case "$wl" "$MERGED")"
  if [[ "$got" == "$want" ]]; then
    echo "  ✅ $name"
    PASS=$((PASS + 1))
  else
    echo "  ❌ $name"
    echo "     預期：$(printf '%s' "$want" | tr '\n' ' ')"
    echo "     實際：$(printf '%s' "$got" | tr '\n' ' ')"
    FAIL=$((FAIL + 1))
  fi
}

echo "白名單扣除（來源：$SYNC）"

# 這一組就是曾經的回歸：空白名單必須原封不動放行全部，而不是扣成 0。
check '空白名單 → 全部保留' '' 'ads.example.com
cdn.foo.org
example.com
sub.example.com
tracker.net'

check '只有換行的白名單 → 全部保留' '
' 'ads.example.com
cdn.foo.org
example.com
sub.example.com
tracker.net'

check '單筆精確比對' 'tracker.net
' 'ads.example.com
cdn.foo.org
example.com
sub.example.com'

# *.example.com 放行子網域，但不放行 example.com 本體 ——
# 比對是先剝掉至少一個標籤才開始比後綴，這是 sync.sh 既有且刻意的語意。
check '*.suffix 放行子網域、不放行本體' '*.example.com
' 'cdn.foo.org
example.com
tracker.net'

check '精確 + suffix 混用' 'example.com
*.example.com
' 'cdn.foo.org
tracker.net'

check '白名單含空行不影響結果' 'tracker.net

' 'ads.example.com
cdn.foo.org
example.com
sub.example.com'

echo "通過 $PASS / 失敗 $FAIL"
[[ $FAIL -eq 0 ]]
