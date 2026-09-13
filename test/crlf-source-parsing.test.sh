#!/usr/bin/env bash
# 「CRLF 行尾的訂閱來源」必須跟同內容的 LF 來源解析出完全相同的網域。
#
# 為什麼需要這支測試：sync.sh 的三個解析器全部以 `$` 錨定行尾，而 Linux 上的 GNU grep
# 逐行比對時會保留行尾的 \r。filters.adtidy.org 提供的 AdGuard-Mobile-Ads-filter 與
# AdGuard-WO-Easylist 是 CRLF，於是在 GitHub Actions 上長期「解析出 0 筆網域」——
# 不報錯、不失敗，D1 裡記下的 checksum 是空內容的 sha256，兩者合計約 1.3 萬個網域從未生效。
#
# 這個 bug 在 Windows 的 Git Bash 上**完全看不出來**：那裡的 grep 3.0、gawk、GNU sed
# 預設會自己把 CR 剝掉（連管線輸入也會），同一份檔案在本機解析得好好的。
# 所以這支測試用三個替身讓兩個平台都呈現 Linux 的行為：
#
#   grep -U            在 Windows 上關掉 CR 剝除；在 Linux 上沒有作用
#   awk -v BINMODE=3   同上（gawk 的 BINMODE；mawk 只會多設一個變數）
#   sed -b             同上
#
# 替身只存在於 runner 裡，production 不受影響。開頭會先驗證替身真的保留 CR ——
# 沒有這一步，在 Windows 上反事實會因為工具自己剝掉 CR 而永遠是綠的。
#
# 做法：從 sync.sh / setup.sh **抽出正在跑的函式**（不是抄一份平行實作）。全程離線。
#
# 用法：bash test/crlf-source-parsing.test.sh [repo 根目錄]
set -uo pipefail

ROOT="${1:-$(dirname "$0")/..}"
SYNC="$ROOT/sync.sh"
SETUP="$ROOT/setup.sh"
[[ -f "$SYNC" ]] || { echo "找不到 $SYNC" >&2; exit 2; }
[[ -f "$SETUP" ]] || { echo "找不到 $SETUP" >&2; exit 2; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); echo "  ✅ $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  ❌ $1"; }

# ── 抽取 ──────────────────────────────────────────────────
# 只對「腳本本身」剝 CR 以供 awk 抽取。fixture 的 CR 絕對不可以經過這一步。
tr -d '\r' < "$SYNC"  > "$WORK/sync_lf.sh"
tr -d '\r' < "$SETUP" > "$WORK/setup_lf.sh"

extract_fn() {
  # $1 = 檔案, $2 = 函式名
  awk -v fn="$2" '
    $0 == fn "() {"     { inside = 1 }
    inside              { print }
    inside && $0 == "}" { exit }
  ' "$1"
}

build_harness() {
  # $1 = 來源檔, $2 = 輸出檔, $3 = 變數名前綴（空字串或 SETUP_）, $4.. = 函式名
  local src="$1" out="$2" pfx="$3"; shift 3
  : > "$out"
  grep -E "^(${pfx}DOMAIN_REGEX|${pfx}IPV4_REGEX)=" "$src" >> "$out"
  [[ "$(grep -cE "^(${pfx}DOMAIN_REGEX|${pfx}IPV4_REGEX)=" "$out")" == "2" ]] \
    || { echo "❌ 抽取失敗：找不到 ${pfx}DOMAIN_REGEX 或 ${pfx}IPV4_REGEX" >&2; exit 2; }
  local fn
  for fn in "$@"; do
    extract_fn "$src" "$fn" > "$WORK/fn.tmp"
    [[ -s "$WORK/fn.tmp" ]] || { echo "❌ 抽取失敗：找不到函式 $fn" >&2; exit 2; }
    [[ "$(tail -n 1 "$WORK/fn.tmp")" == "}" ]] \
      || { echo "❌ 抽取失敗：$fn 的最後一行不是收尾大括號" >&2; exit 2; }
    cat "$WORK/fn.tmp" >> "$out"
    echo >> "$out"
  done
}

build_harness "$WORK/sync_lf.sh"  "$WORK/sync_fns.sh"  ""       parse_domains parse_adblock parse_hosts
build_harness "$WORK/setup_lf.sh" "$WORK/setup_fns.sh" "SETUP_" setup_parse

# 抽出來的變數不能是空的：漏抽 DOMAIN_REGEX 時 grep -E "" 會放行每一行，
# 位元組比對的案例就失去意義。
# shellcheck disable=SC1090
( source "$WORK/sync_fns.sh";  [[ -n "${DOMAIN_REGEX:-}" && -n "${IPV4_REGEX:-}" ]] ) \
  || { echo "❌ 抽取自我驗證失敗：DOMAIN_REGEX／IPV4_REGEX 是空的" >&2; exit 2; }
# shellcheck disable=SC1090
( source "$WORK/setup_fns.sh"; [[ -n "${SETUP_DOMAIN_REGEX:-}" && -n "${SETUP_IPV4_REGEX:-}" ]] ) \
  || { echo "❌ 抽取自我驗證失敗：SETUP_DOMAIN_REGEX／SETUP_IPV4_REGEX 是空的" >&2; exit 2; }

# ── 執行器 ────────────────────────────────────────────────
# $1 = 函式檔, $2 = 是否使用替身（1/0）, $3 = 函式名, 其餘 = 參數；stdin → stdout
cat > "$WORK/runner.sh" <<'RUNNEREOF'
#!/usr/bin/env bash
set -uo pipefail
HARNESS="$1"; USE_SHIMS="$2"; FN="$3"; shift 3
if [[ "$USE_SHIMS" == "1" ]]; then
  grep() { command grep -U "$@"; }
  awk()  { command awk -v BINMODE=3 "$@"; }
  sed()  { command sed -b "$@"; }
fi
# shellcheck disable=SC1090
source "$HARNESS"
"$FN" "$@"
RUNNEREOF

run() { bash "$WORK/runner.sh" "$@"; }

# 工具探針：用來驗證「這個環境看不看得到 CR」
cat > "$WORK/probe.sh" <<'PROBEEOF'
probe_grep() { grep -c 'ab\.com$'; }
probe_awk()  { awk '{print length($2)}'; }
probe_sed()  { sed -E 's/x/x/'; }
PROBEEOF

cr_bytes() { tr -cd '\r' | wc -c | tr -d ' '; }

tool_keeps_cr() {
  # $1 = 是否使用替身 → 印出 "grep awk sed" 三個 0/1（1 = 保留 CR）
  local shims="$1" g a s
  g=$(printf '0.0.0.0 ab.com\r\n' | run "$WORK/probe.sh" "$shims" probe_grep 2>/dev/null) || true
  a=$(printf '0.0.0.0 ab.com\r\n' | run "$WORK/probe.sh" "$shims" probe_awk  2>/dev/null) || true
  s=$(printf '0.0.0.0 ab.com\r\n' | run "$WORK/probe.sh" "$shims" probe_sed  2>/dev/null | cr_bytes) || true
  # grep：保留 CR 時 `ab\.com$` 對不上 → 0；awk：保留 CR 時 $2 長度 7；sed：保留 CR 時輸出含 1 個 CR
  printf '%s %s %s\n' \
    "$([[ "$g" == "0" ]] && echo 1 || echo 0)" \
    "$([[ "$a" == "7" ]] && echo 1 || echo 0)" \
    "$([[ "$s" == "1" ]] && echo 1 || echo 0)"
}

# ── 替身自我驗證（不通過就 exit 2）────────────────────────
read -r SG SA SS <<< "$(tool_keeps_cr 1)"
if [[ "$SG$SA$SS" != "111" ]]; then
  echo "❌ 替身自我驗證失敗：替身沒有保留 CR（grep=$SG awk=$SA sed=$SS，1 = 保留）" >&2
  echo "   這支測試因此觀察不到 Linux 上的行為，任何結果都不可信。" >&2
  exit 2
fi

# ── 平台偵測：原生工具會不會剝 CR ─────────────────────────
read -r NG NA NS <<< "$(tool_keeps_cr 0)"
if [[ "$NG$NA$NS" == "111" ]]; then NATIVE_STRIPS=0; else NATIVE_STRIPS=1; fi

echo "環境：替身保留 CR；原生工具 grep=$NG awk=$NA sed=$NS（1 = 保留 CR）"

# ── fixture ───────────────────────────────────────────────
to_crlf() { while IFS= read -r line || [[ -n "$line" ]]; do printf '%s\r\n' "$line"; done; }

cat > "$WORK/adblock.lf" <<'EOF'
[Adblock Plus 2.0]
! Title: crlf test
||ads1.example^
||ads2.example^$third-party
||ads3.example^
EOF

cat > "$WORK/hosts.lf" <<'EOF'
# hosts comment
127.0.0.1 localhost
0.0.0.0 track1.example
0.0.0.0 track2.example
EOF

cat > "$WORK/domains.lf" <<'EOF'
# domains comment
! another comment
dom1.example
*.dom2.example
dom3.example
EOF

# 案例 5：誤判陷阱行 ＋ 應被保留的正常規則
cat > "$WORK/trap.lf" <<'EOF'
||keep1.example^
||youtube.com^$removeparam=pp
||keep2.example^$third-party
||x.com^*/ads.js
@@||a.com^
example.com##.ad
||b.com^$badfilter
||keep3.example^
EOF

cat > "$WORK/blank_comment.lf" <<'EOF'
# only a comment

! another comment

EOF

for f in adblock hosts domains trap blank_comment; do
  to_crlf < "$WORK/$f.lf" > "$WORK/$f.crlf"
done

# fixture 自我驗證：CRLF 版真的有 CR，LF 版真的沒有
for f in adblock hosts domains trap; do
  [[ "$(cr_bytes < "$WORK/$f.crlf")" -gt 0 ]] || { echo "❌ fixture 錯誤：$f.crlf 沒有 CR" >&2; exit 2; }
  [[ "$(cr_bytes < "$WORK/$f.lf")" == "0" ]]  || { echo "❌ fixture 錯誤：$f.lf 含 CR" >&2; exit 2; }
done

# 混雜：奇數行 CRLF、偶數行 LF
awk 'NR % 2 == 1 { printf "%s\r\n", $0; next } { print }' "$WORK/adblock.lf" > "$WORK/adblock.mixed"
[[ "$(cr_bytes < "$WORK/adblock.mixed")" -gt 0 ]] || { echo "❌ fixture 錯誤：adblock.mixed 沒有 CR" >&2; exit 2; }

lines() { if [[ -s "$1" ]]; then wc -l < "$1" | tr -d ' '; else echo 0; fi; }

# ── 案例 ──────────────────────────────────────────────────
# $1 = 函式檔, $2 = 函式名, $3 = fixture 名, $4 = 格式參數（setup_parse 才用）
same_output() {
  local h="$1" fn="$2" fx="$3" arg="${4:-}" tag="$5"
  run "$h" 1 "$fn" $arg < "$WORK/$fx.lf"   > "$WORK/out_${tag}.lf"
  run "$h" 1 "$fn" $arg < "$WORK/$fx.crlf" > "$WORK/out_${tag}.crlf"
  [[ "$(lines "$WORK/out_${tag}.lf")" -gt 0 ]] && cmp -s "$WORK/out_${tag}.lf" "$WORK/out_${tag}.crlf"
}

check_case_1() { same_output "$1" parse_adblock adblock "" c1; }
check_case_2() { same_output "$1" parse_hosts   hosts   "" c2; }
check_case_3() { same_output "$1" parse_domains domains "" c3; }

check_case_5a() {
  local h="$1"
  run "$h" 1 parse_adblock < "$WORK/trap.lf"   > "$WORK/out_c5.lf"
  run "$h" 1 parse_adblock < "$WORK/trap.crlf" > "$WORK/out_c5.crlf"
  cmp -s "$WORK/out_c5.lf" "$WORK/out_c5.crlf" || return 1
  local k
  for k in keep1.example keep2.example keep3.example; do
    command grep -qxF "$k" "$WORK/out_c5.crlf" || return 1
  done
}

check_case_5b() {
  local h="$1" d
  run "$h" 1 parse_adblock < "$WORK/trap.crlf" > "$WORK/out_c5b.crlf"
  for d in youtube.com x.com a.com b.com example.com; do
    command grep -qxF "$d" "$WORK/out_c5b.crlf" && return 1
  done
  return 0
}

check_case_8() {
  local h="$1" fmt
  for fmt in adblock hosts domains; do
    same_output "$h" setup_parse "$fmt" "$fmt" "c8_$fmt" || return 1
  done
}

first_code_is_tr() {
  # $1 = 函式檔, $2 = 函式名：函式本體第一個非空白、非註解行必須以 tr -d '\r' 開頭
  extract_fn "$1" "$2" | awk '
    NR == 1 { next }
    /^[[:space:]]*$/ || /^[[:space:]]*#/ { next }
    { if ($0 ~ /^[[:space:]]*tr -d \047\\r\047/) { print "yes" } else { print "no" }; exit }
  ' | command grep -qx yes
}

check_case_9() {
  local sh="$1" ph="$2" fn
  for fn in parse_domains parse_adblock parse_hosts; do
    first_code_is_tr "$sh" "$fn" || return 1
  done
  first_code_is_tr "$ph" setup_parse
}

echo "CRLF 與 LF 解析結果相同"

if check_case_1 "$WORK/sync_fns.sh"; then ok "1. parse_adblock：CRLF 與 LF 輸出位元組相同（$(lines "$WORK/out_c1.lf") 筆）"; else bad "1. parse_adblock：CRLF 與 LF 輸出不同"; fi
if check_case_2 "$WORK/sync_fns.sh"; then ok "2. parse_hosts：CRLF 與 LF 輸出位元組相同（$(lines "$WORK/out_c2.lf") 筆）"; else bad "2. parse_hosts：CRLF 與 LF 輸出不同"; fi
if check_case_3 "$WORK/sync_fns.sh"; then ok "3. parse_domains：CRLF 與 LF 輸出位元組相同（$(lines "$WORK/out_c3.lf") 筆）"; else bad "3. parse_domains：CRLF 與 LF 輸出不同"; fi

cr_total=0
for t in c1 c2 c3; do cr_total=$((cr_total + $(cr_bytes < "$WORK/out_$t.crlf"))); done
if [[ "$cr_total" == "0" ]]; then ok "4. 三個解析器的輸出不含任何 CR 位元組"; else bad "4. 解析器輸出含 $cr_total 個 CR 位元組"; fi

if check_case_5a "$WORK/sync_fns.sh"; then ok "5(a). CRLF 混合 fixture：輸出與 LF 版相同，且保留 keep1～keep3"; else bad "5(a). CRLF 混合 fixture：輸出與 LF 版不同或缺少正常規則"; fi
if check_case_5b "$WORK/sync_fns.sh"; then ok "5(b). CRLF 下誤判陷阱行仍全部被排除"; else bad "5(b). CRLF 下有陷阱網域漏進輸出"; fi

run "$WORK/sync_fns.sh" 1 parse_adblock < "$WORK/adblock.mixed" > "$WORK/out_c6.mixed"
run "$WORK/sync_fns.sh" 1 parse_adblock < "$WORK/adblock.lf"    > "$WORK/out_c6.lf"
if cmp -s "$WORK/out_c6.lf" "$WORK/out_c6.mixed"; then ok "6. CRLF 與 LF 混雜的檔案：輸出與全 LF 版相同"; else bad "6. 混雜行尾的檔案輸出與全 LF 版不同"; fi

c7_ok=1
for fn in parse_domains parse_adblock parse_hosts; do
  run "$WORK/sync_fns.sh" 1 "$fn" < "$WORK/blank_comment.crlf" > "$WORK/out_c7_$fn"
  [[ -s "$WORK/out_c7_$fn" ]] && c7_ok=0
done
if [[ $c7_ok -eq 1 ]]; then ok "7. CRLF 的空行與註解行不產生任何輸出"; else bad "7. CRLF 的空行或註解行產生了輸出"; fi

if check_case_8 "$WORK/setup_fns.sh"; then ok "8. setup_parse 三種格式：CRLF 與 LF 輸出位元組相同"; else bad "8. setup_parse 有格式的 CRLF 與 LF 輸出不同"; fi
if check_case_9 "$WORK/sync_fns.sh" "$WORK/setup_fns.sh"; then ok "9. 三個解析器與 setup_parse 的第一道管線都是 tr -d '\\r'"; else bad "9. 有函式的第一道管線不是 tr -d '\\r'"; fi

# ══════════════════════════════════════════════════════════
# 反事實：每一個變異都必須讓對應案例變紅
# ══════════════════════════════════════════════════════════
echo "反事實"

mutate() {
  # $1 = 來源函式檔, $2 = 輸出檔, $3 = 函式名, $4 = 要改寫的那一行（完全比對）, $5 = 改成什麼（空字串 = 刪除該行）
  local src="$1" out="$2" fn="$3" from="$4" to="$5"
  # 字串一律經 ENVIRON 傳進 awk，不用 -v：`awk -v` 會處理跳脫序列，
  # 把原始碼裡字面上的 \r 變成真正的 CR，錨點就永遠比對不到。
  MUT_FN="$fn" MUT_FROM="$from" MUT_TO="$to" MUT_DEL="$([[ -z "$to" ]] && echo 1 || echo 0)" awk '
    $0 == ENVIRON["MUT_FN"] "() {" { inside = 1 }
    inside && !done && $0 == ENVIRON["MUT_FROM"] { done = 1; if (ENVIRON["MUT_DEL"] != "1") print ENVIRON["MUT_TO"]; next }
    { print }
    inside && $0 == "}" { inside = 0 }
  ' "$src" > "$out"
  if cmp -s "$src" "$out"; then
    echo "❌ 反事實產生失敗：$fn 裡找不到「$from」（錨點失效，這個反事實是假的）" >&2
    exit 2
  fi
}

TR_ADBLOCK_LINE="  tr -d '\\r' \\"
TR_SETUP_LINE="  tr -d '\\r' | case \"\$1\" in"

expect_red() {
  # $1 = 描述, $2.. = 指令；指令成功（綠）就是反事實失敗
  local desc="$1"; shift
  if "$@"; then bad "反事實 $desc：案例仍然是綠的"; else ok "反事實 $desc → 變紅"; fi
}

mutate "$WORK/sync_fns.sh" "$WORK/m_adblock.sh" parse_adblock "$TR_ADBLOCK_LINE" "  cat \\"
expect_red "拿掉 parse_adblock 的 tr → 案例 1"     check_case_1  "$WORK/m_adblock.sh"
expect_red "拿掉 parse_adblock 的 tr → 案例 5(a)"  check_case_5a "$WORK/m_adblock.sh"
expect_red "拿掉 parse_adblock 的 tr → 案例 9"     check_case_9  "$WORK/m_adblock.sh" "$WORK/setup_fns.sh"

mutate "$WORK/sync_fns.sh" "$WORK/m_hosts.sh" parse_hosts "$TR_ADBLOCK_LINE" "  cat \\"
expect_red "拿掉 parse_hosts 的 tr → 案例 2"       check_case_2  "$WORK/m_hosts.sh"
expect_red "拿掉 parse_hosts 的 tr → 案例 9"       check_case_9  "$WORK/m_hosts.sh" "$WORK/setup_fns.sh"

mutate "$WORK/sync_fns.sh" "$WORK/m_domains.sh" parse_domains "$TR_ADBLOCK_LINE" "  cat \\"
expect_red "拿掉 parse_domains 的 tr → 案例 3"     check_case_3  "$WORK/m_domains.sh"
expect_red "拿掉 parse_domains 的 tr → 案例 9"     check_case_9  "$WORK/m_domains.sh" "$WORK/setup_fns.sh"

mutate "$WORK/setup_fns.sh" "$WORK/m_setup.sh" setup_parse "$TR_SETUP_LINE" "  cat | case \"\$1\" in"
expect_red "拿掉 setup_parse 的 tr → 案例 8"       check_case_8  "$WORK/m_setup.sh"
expect_red "拿掉 setup_parse 的 tr → 案例 9"       check_case_9  "$WORK/sync_fns.sh" "$WORK/m_setup.sh"

mutate "$WORK/sync_fns.sh" "$WORK/m_eq.sh" parse_adblock "    | grep -vE '\\\$[a-zA-Z0-9_,.=~|-]*=' \\" ""
expect_red "保留 tr、拿掉 = 修飾詞排除 → 案例 5(b)" check_case_5b "$WORK/m_eq.sh"

# 替身那一列依平台跑不同的斷言
if [[ $NATIVE_STRIPS -eq 1 ]]; then
  # 不用替身時，原生工具自己剝 CR：拿掉 tr 的變異在這裡觀察不到 —— 證明替身是必要的
  run "$WORK/m_adblock.sh" 0 parse_adblock < "$WORK/adblock.lf"   > "$WORK/nat.lf"
  run "$WORK/m_adblock.sh" 0 parse_adblock < "$WORK/adblock.crlf" > "$WORK/nat.crlf"
  if cmp -s "$WORK/nat.lf" "$WORK/nat.crlf" && [[ "$(tool_keeps_cr 0)" != "1 1 1" ]]; then
    ok "替身反事實（本平台原生工具會剝 CR）→ 不用替身時看不到 bug、自我驗證也不通過，替身是必要的"
  else
    bad "替身反事實（本平台原生工具會剝 CR）：結果與預期不符"
  fi
else
  if [[ "$(tool_keeps_cr 0)" == "1 1 1" ]]; then
    ok "本平台原生工具已保留 CR，替身為恆等 → 原生 grep／awk／sed 皆保留 CR"
  else
    bad "本平台原生工具應保留 CR，但偵測結果不符"
  fi
fi

echo
echo "通過 $PASS / 失敗 $FAIL"
[[ $FAIL -eq 0 ]]
