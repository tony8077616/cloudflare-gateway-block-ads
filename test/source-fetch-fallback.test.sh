#!/usr/bin/env bash
# 來源取得的連線預案、TXT 限制與注入防護的測試。
#
# 為什麼需要這支測試：
#   1. curl 的離開狀態以前被忽略。--max-time 在傳輸途中觸發時 curl 以 28 結束「但仍印出 200」，
#      截斷的檔案被解析、ETag 被存下，之後的 304 讓截斷的 checksum 一直延續。
#   2. 上游回應標頭（ETag／Last-Modified）會以 TAB 分隔寫進 D1，下次再塞進 curl -H。
#   3. 取檔失敗時，嘗試到一半的檔案一旦出現在 $TMP_DIR 最上層，就會被 build_merged 的
#      cat parsed_*.txt 合併進去。
#
# 頭號案例是 1 與 2：健康狀態下行為與改動之前相同（只呼叫一次 curl、同一組條件式標頭）。
#
# 做法：從 sync.sh **抽出正在跑的函式**（不是抄一份平行實作），curl 換成替身。
# 替身依取檔方式與網址回傳受控的離開狀態、HTTP 碼、內容、標頭，模擬 -o／-D 的寫檔語意
# （離開狀態 28 寫入半截內容；7 這類傳輸前就失敗的情況不建立任何檔案），並記錄完整 argv。
# 全程離線。
#
# 用法：bash test/source-fetch-fallback.test.sh [repo 根目錄]
set -uo pipefail

ROOT="${1:-$(dirname "$0")/..}"
SYNC="$ROOT/sync.sh"
[[ -f "$SYNC" ]] || { echo "找不到 $SYNC" >&2; exit 2; }

for tool in awk sed grep tr head tail wc cmp diff seq sha256sum mktemp; do
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

HARNESS="$WORK/extracted.sh"
: > "$HARNESS"
VARS='DOMAIN_REGEX|IPV4_REGEX|SOURCE_MAX_BYTES|SOURCE_FALLBACK_BUDGET_SECONDS|SOURCE_FALLBACK_SPENT|SOURCE_FALLBACK_BUDGET_NOTED'
grep -E "^($VARS)=" "$WORK/sync_lf.sh" >> "$HARNESS"
n_vars=$(grep -cE "^($VARS)=" "$HARNESS") || n_vars=0
[[ "$n_vars" == "6" ]] || { echo "❌ 抽取失敗：頂層變數應有 6 個，實得 $n_vars" >&2; exit 2; }

for fn in byte_len has_control_chars sanitize_for_log trim validate_source_name validate_source_url \
          state_get last_header_block header_value sanitize_validator_header validate_text_content \
          parse_domains parse_adblock parse_hosts curl_source parse_source_into fetch_source_with_fallback \
          fetch_and_merge_sources materialize_sources collect_source_checksums emit_meta_state md_escape render_change_reasons write_step_summary; do
  extract_fn "$fn" > "$WORK/fn.tmp"
  [[ -s "$WORK/fn.tmp" ]] || { echo "❌ 抽取失敗：找不到函式 $fn" >&2; exit 2; }
  [[ "$(tail -n 1 "$WORK/fn.tmp")" == "}" ]] || { echo "❌ 抽取失敗：$fn 的最後一行不是收尾大括號" >&2; exit 2; }
  cat "$WORK/fn.tmp" >> "$HARNESS"
  echo >> "$HARNESS"
done

# main() 裡的狀態回寫組法（案例 28 用）：從 new_state_file 的建立到 emit_meta_state
{
  echo 'assemble_state() {'
  sed -n '/^  local new_state_file="\$TMP_DIR\/new_state.txt"$/,/^  emit_meta_state >> "\$new_state_file"$/p' "$WORK/sync_lf.sh"
  echo '}'
} > "$WORK/fn.tmp"
grep -q 'failed_sources.txt' "$WORK/fn.tmp" && grep -q '^  emit_meta_state >> ' "$WORK/fn.tmp" \
  || { echo "❌ 抽取失敗：main() 的狀態回寫區塊找不到（錨點可能改了）" >&2; exit 2; }
cat "$WORK/fn.tmp" >> "$HARNESS"

# 抽出來的變數不能是空的：漏抽 DOMAIN_REGEX 時 grep -E "" 會放行每一行
# shellcheck disable=SC1090
( source "$HARNESS"; [[ -n "${DOMAIN_REGEX:-}" && -n "${IPV4_REGEX:-}" && "${SOURCE_MAX_BYTES:-0}" -gt 0 && -n "${SOURCE_FALLBACK_BUDGET_SECONDS:-}" ]] ) \
  || { echo "❌ 抽取自我驗證失敗：必要的頂層變數是空的" >&2; exit 2; }

# ── 自我驗證：curl_source 只能由 fetch_source_with_fallback 呼叫 ─────
curl_source_call_sites() {
  # $1 = 檔案 → 每一個實際呼叫 curl_source 的行印出它所在的函式名（排除註解行與定義行本身）
  awk '
    /^[A-Za-z_][A-Za-z0-9_]*\(\) \{$/ { fn = substr($0, 1, index($0, "(") - 1) }
    /^[[:space:]]*#/                  { next }
    /^curl_source\(\) \{$/            { next }
    /(^|[^A-Za-z0-9_])curl_source([^A-Za-z0-9_]|$)/ { print fn }
  ' "$1"
}
self_check_call_sites() { [[ "$(curl_source_call_sites "$1")" == "fetch_source_with_fallback" ]]; }
if ! self_check_call_sites "$WORK/sync_lf.sh"; then
  echo "❌ 自我驗證失敗：sync.sh 裡 curl_source 的呼叫應該恰好一處、位於 fetch_source_with_fallback，實得：" >&2
  curl_source_call_sites "$WORK/sync_lf.sh" | sed 's/^/     /' >&2
  exit 2
fi

# ── 執行器 ────────────────────────────────────────────────
cat > "$WORK/runner.sh" <<'RUNNEREOF'
#!/usr/bin/env bash
# $1 = 函式檔, $2 = 情境目錄, $3 = 入口（gate / materialize / summary / fn）, 其餘 = 參數
set -uo pipefail
HARNESS="$1"; SC="$2"; ENTRY="$3"; shift 3
TMP_DIR="$SC/tmp"
SOURCES_FILE="$SC/sources.conf"
PREV_STATE_FILE="$SC/prev_state.txt"
GITHUB_STEP_SUMMARY="$SC/summary.md"
UPLOAD_STAT_UPLOADED=0; UPLOAD_STAT_SKIPPED=0; UPLOAD_STAT_FAILED=0; UPLOAD_STAT_TOTAL=0
D1_WRITES_TODAY=0; D1_WRITES_ADDED=0; D1_DAILY_WRITE_BUDGET=1
CACHE_SOURCE=kv; CACHE_BLOB_BYTES=0; CACHE_BLOB_ROWS=0; DEFERRED_CACHE_ROWS=0

# 讓 Windows 上的 grep／awk／sed 也呈現 Linux 的 CR 語意（見 test/crlf-source-parsing.test.sh）
grep() { command grep -U "$@"; }
awk()  { command awk -v BINMODE=3 "$@"; }
sed()  { command sed -b "$@"; }

log()  { echo "[00:00:00] $*" >&2; }
warn() { echo "[00:00:00] ⚠ $*" >&2; }

# shellcheck disable=SC1090
source "$HARNESS"
[[ -n "${OVERRIDE_BUDGET:-}" ]] && SOURCE_FALLBACK_BUDGET_SECONDS="$OVERRIDE_BUDGET"
[[ -n "${OVERRIDE_MAX:-}" ]] && SOURCE_MAX_BYTES="$OVERRIDE_MAX"

# 時鐘替身：情境目錄有 clock 檔時，每次 date +%s 前進 100 秒
date() {
  if [[ "${1:-}" == "+%s" && -f "$SC/clock" ]]; then
    local t; t=$(cat "$SC/clock"); echo $((t + 100)) > "$SC/clock"; echo "$t"
  else
    command date "$@"
  fi
}

# curl 替身
curl() {
  local n
  n=$(( $(cat "$SC/ncalls" 2>/dev/null || echo 0) + 1 ))
  echo "$n" > "$SC/ncalls"
  printf '%s\n' "$@" > "$SC/argv.$n"
  local -a a=("$@")
  local i hdr="" out="" url="" inm="" method=m1
  for ((i = 0; i < ${#a[@]}; i++)); do
    case "${a[i]}" in
      -D) hdr="${a[i+1]}" ;;
      -o) out="${a[i+1]}" ;;
      -H) case "${a[i+1]}" in "If-None-Match: "*) inm="${a[i+1]#If-None-Match: }" ;; esac ;;
      --http1.1) method=m2 ;;
      --) url="${a[i+1]}" ;;
    esac
  done
  local name="${url##*/}"; name="${name%.txt}"
  printf '%s %s %s\n' "$n" "$name" "$method" >> "$SC/calls.log"
  local rc=0 code=200 body="" headers="" partial=0 nofiles=0 etag304="" force304=0 stderr=""
  if [[ ! -f "$SC/spec/$name.$method" ]]; then
    echo "no spec for $name.$method" >> "$SC/stub_errors"
    printf '000'; return 7
  fi
  # shellcheck disable=SC1090
  source "$SC/spec/$name.$method"
  [[ -n "$stderr" ]] && printf '%s\n' "$stderr" >&2
  if [[ "$force304" == "1" || ( -n "$etag304" && "$inm" == "$etag304" ) ]]; then
    [[ -n "$hdr" ]] && printf 'HTTP/2 304\r\netag: %s\r\n\r\n' "$etag304" > "$hdr"
    printf '304'; return 0
  fi
  if [[ "$nofiles" == "1" ]]; then printf '%s' "$code"; return "$rc"; fi
  if [[ -n "$hdr" ]]; then
    if [[ -n "$headers" ]]; then cat "$headers" > "$hdr"; else printf 'HTTP/2 %s\r\n\r\n' "$code" > "$hdr"; fi
  fi
  if [[ -n "$out" && -n "$body" ]]; then
    if [[ "$partial" == "1" ]]; then
      local sz; sz=$(wc -c < "$body"); head -c $((sz / 2)) "$body" > "$out"
    else
      cat "$body" > "$out"
    fi
  fi
  printf '%s' "$code"
  return "$rc"
}

mkdir -p "$TMP_DIR"
case "$ENTRY" in
  gate)
    fetch_and_merge_sources ;;
  gate_summary)
    fetch_and_merge_sources
    write_step_summary "success" 1 1 "$(printf '來源內容變動\t%s' c21ok)" ;;
  materialize)
    materialize_sources
    collect_source_checksums
    assemble_state ;;
  fn)
    "$@" ;;
esac
RUNNEREOF

# ── 情境工具 ──────────────────────────────────────────────
new_sc() {
  # 同一個標籤每次都重建（反事實會對同一個情境重跑一次）
  local d="$WORK/sc/$1"
  rm -rf "$d"; mkdir -p "$d/tmp" "$d/spec" "$d/files"
  : > "$d/prev_state.txt"; : > "$d/sources.conf"; : > "$d/calls.log"
  echo "$d"
}
url_of() { printf 'https://src.example/list/%s.txt' "$1"; }
add_source() { printf '%s|%s|%s\n' "$2" "$(url_of "$2")" "${3:-adblock}" >> "$1/sources.conf"; }
spec() { local d="$1" name="$2" m="$3"; shift 3; printf '%s\n' "$@" > "$d/spec/$name.$m"; }
state() { printf '%s\t%s\n' "$2" "$3" >> "$1/prev_state.txt"; }
run_entry() { local h="$1" d="$2"; shift 2; bash "$WORK/runner.sh" "$h" "$d" "$@" > "$d/stdout" 2> "$d/log"; }
calls() { local n; n=$(grep -c " $2 " "$1/calls.log") || n=0; echo "$n"; }
call_argv() { awk -v nm="$2" -v m="$3" '$2 == nm && $3 == m { print $1; exit }' "$1/calls.log" | { read -r k && echo "$1/argv.$k"; }; }
in_failed() { [[ -f "$1/tmp/failed_sources.txt" ]] && grep -qxF "$2" "$1/tmp/failed_sources.txt"; }
meta_field() { awk -F'\t' -v nm="$2" -v f="$3" '$1 == nm { print $f; exit }' "$1/tmp/newmeta.txt"; }
has_domain() { [[ -f "$1" ]] && grep -qxF "$2" "$1"; }
sha_of() { sha256sum < "$1" | awk '{print $1}'; }
EMPTY_SHA=$(sha256sum < /dev/null | awk '{print $1}')

# ── fixture ───────────────────────────────────────────────
FX="$WORK/fx"; mkdir -p "$FX"
{ echo '||only-in-m1.example^'; for i in $(seq 1 40); do echo "! padding line $i ........................................"; done; echo '||m1-tail.example^'; } > "$FX/m1_partial_src"
printf '[Adblock Plus 2.0]\n! Title: m2\n||m2-ok.example^\n||m2-second.example^\n' > "$FX/m2_ok"
printf '[Adblock Plus 2.0]\n||healthy-a.example^\n||healthy-b.example^$third-party\n' > "$FX/healthy"
printf '[Adblock Plus 2.0]\n! only comments here\n' > "$FX/zero"
printf '<!DOCTYPE html>\n<html><body>\n||only-in-html.example^\n</body></html>\n' > "$FX/html"
printf 'HTTP/1.1 200 OK\r\nETag: "m1"\r\nLast-Modified: Wed, 01 Jan 2026 00:00:00 GMT\r\n\r\n' > "$FX/hdr_m1"
printf 'HTTP/2 200\r\netag: "m2"\r\nlast-modified: Thu, 02 Jan 2026 00:00:00 GMT\r\n\r\n' > "$FX/hdr_m2"

# fixture 自我驗證：半截內容必須含完整的 ||only-in-m1.example^ 那一行，② 的內容不可以含它
half=$(( $(wc -c < "$FX/m1_partial_src") / 2 ))
head -c "$half" "$FX/m1_partial_src" | grep -qx '||only-in-m1.example^' \
  || { echo "❌ fixture 錯誤：m1 的半截內容不含完整的 only-in-m1 那一行" >&2; exit 2; }
head -c "$half" "$FX/m1_partial_src" | grep -q 'm1-tail' \
  && { echo "❌ fixture 錯誤：m1 的半截內容不應該含結尾那一行" >&2; exit 2; }
grep -q 'only-in-m1' "$FX/m2_ok" && { echo "❌ fixture 錯誤：② 的內容含 only-in-m1" >&2; exit 2; }
bash "$WORK/runner.sh" "$HARNESS" "$WORK" fn parse_adblock < "$FX/html" | grep -qx 'only-in-html.example' \
  || { echo "❌ fixture 錯誤：HTML fixture 裡沒有能解析成網域的標記行，驗不到「沒被採用」" >&2; exit 2; }
[[ -z "$(bash "$WORK/runner.sh" "$HARNESS" "$WORK" fn parse_adblock < "$FX/zero")" ]] \
  || { echo "❌ fixture 錯誤：zero fixture 應該解析出 0 筆" >&2; exit 2; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); echo "  ✅ $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  ❌ $1"; }
check() { local desc="$1"; shift; if "$@"; then ok "$desc"; else bad "$desc"; fi; }

M1_ARGS=(-sSL --retry 3 --retry-all-errors --max-time 60)

# ══════════════════════════════════════════════════════════
# 閘門階段（fetch_and_merge_sources）
# ══════════════════════════════════════════════════════════

case_1() {
  local h="$1" d; d=$(new_sc c1)
  add_source "$d" s1
  state "$d" 'etag:s1' '"v1"'
  state "$d" 'lastmod:s1' 'Wed, 01 Jan 2026 00:00:00 GMT'
  spec "$d" s1 m1 "body='$FX/healthy'" "headers='$FX/hdr_m1'"
  run_entry "$h" "$d" gate
  [[ "$(calls "$d" s1)" == "1" ]] || return 1
  local m="$d/tmp/fetch_s1/m1"
  printf '%s\n' -q "${M1_ARGS[@]}" --proto =https --proto-redir =https --max-redirs 5 --max-filesize 52428800 \
    -A cloudflare-gateway-block-ads-sync/1.0 \
    -H 'If-None-Match: "v1"' -H 'If-Modified-Since: Wed, 01 Jan 2026 00:00:00 GMT' \
    -D "$m/headers" -o "$m/body" -w '%{http_code}' -- "$(url_of s1)" > "$d/expected_argv"
  cmp -s "$d/expected_argv" "$(call_argv "$d" s1 m1)" || return 1
  bash "$WORK/runner.sh" "$h" "$d" fn parse_adblock < "$FX/healthy" > "$d/expected_parsed"
  cmp -s "$d/expected_parsed" "$d/tmp/parsed_s1.txt" || return 1
  [[ "$(meta_field "$d" s1 2)" == '"m1"' ]]
}

case_2() {
  local h="$1" d; d=$(new_sc c2)
  add_source "$d" s2
  state "$d" 'etag:s2' '"v2"'
  state "$d" 'src:s2' 'prevsum2'
  spec "$d" s2 m1 "etag304='\"v2\"'" "body='$FX/html'"
  run_entry "$h" "$d" gate
  [[ "$(calls "$d" s2)" == "1" ]] || return 1
  grep -qxF "$(printf 's2\tadblock')" "$d/tmp/notmodified.txt" || return 1
  [[ "$(cat "$d/tmp/sum_s2.txt")" == "prevsum2" ]] || return 1
  ! in_failed "$d" s2
}

case_3() {
  local h="$1" d; d=$(new_sc c3)
  add_source "$d" s3
  spec "$d" s3 m1 rc=28 code=200 partial=1 "body='$FX/m1_partial_src'" "headers='$FX/hdr_m1'"
  spec "$d" s3 m2 "body='$FX/m2_ok'" "headers='$FX/hdr_m2'"
  run_entry "$h" "$d" gate
  [[ "$(calls "$d" s3)" == "2" ]] || return 1
  has_domain "$d/tmp/parsed_s3.txt" only-in-m1.example && return 1
  has_domain "$d/tmp/parsed_s3.txt" m2-ok.example || return 1
  [[ "$(meta_field "$d" s3 2)" == '"m2"' ]]
}

case_4() {
  local h="$1" d; d=$(new_sc c4)
  add_source "$d" s4
  spec "$d" s4 m1 rc=63 code=200 partial=1 "body='$FX/m1_partial_src'"
  spec "$d" s4 m2 "body='$FX/m2_ok'"
  run_entry "$h" "$d" gate
  [[ "$(calls "$d" s4)" == "1" ]] && in_failed "$d" s4 && [[ ! -e "$d/tmp/parsed_s4.txt" ]]
}

case_5() {
  local h="$1" d; d=$(new_sc c5)
  add_source "$d" s5
  spec "$d" s5 m1 rc=7 code=000 nofiles=1
  spec "$d" s5 m2 "body='$FX/m2_ok'" "headers='$FX/hdr_m2'"
  run_entry "$h" "$d" gate
  [[ "$(calls "$d" s5)" == "2" ]] && has_domain "$d/tmp/parsed_s5.txt" m2-ok.example \
    && [[ "$(meta_field "$d" s5 2)" == '"m2"' ]] && ! in_failed "$d" s5
}

case_6() {
  local h="$1" d; d=$(new_sc c6)
  add_source "$d" s6
  spec "$d" s6 m1 rc=7 code=000 nofiles=1
  spec "$d" s6 m2 code=503 "body='$FX/html'"
  run_entry "$h" "$d" gate
  [[ "$(calls "$d" s6)" == "2" ]] && in_failed "$d" s6 \
    && [[ ! -e "$d/tmp/parsed_s6.txt" && ! -e "$d/tmp/sum_s6.txt" ]]
}

case_7() {
  local h="$1" d; d=$(new_sc c7)
  add_source "$d" s7
  spec "$d" s7 m1 code=404 "body='$FX/html'"
  spec "$d" s7 m2 "body='$FX/m2_ok'"
  run_entry "$h" "$d" gate
  [[ "$(calls "$d" s7)" == "1" ]] && in_failed "$d" s7
}

case_8() {
  local h="$1" d c; d=$(new_sc c8)
  for c in 429 503 403; do
    add_source "$d" "s8_$c"
    spec "$d" "s8_$c" m1 "code=$c" "body='$FX/html'"
    spec "$d" "s8_$c" m2 "body='$FX/m2_ok'"
  done
  run_entry "$h" "$d" gate
  for c in 429 503 403; do
    [[ "$(calls "$d" "s8_$c")" == "2" ]] || return 1
    has_domain "$d/tmp/parsed_s8_$c.txt" m2-ok.example || return 1
  done
}

case_9() {
  local h="$1" d; d=$(new_sc c9)
  add_source "$d" s9                       # 沒有前次 src:，0 筆防護不介入
  spec "$d" s9 m1 "body='$FX/html'"
  spec "$d" s9 m2 "body='$FX/m2_ok'"
  run_entry "$h" "$d" gate
  [[ "$(calls "$d" s9)" == "2" ]] || return 1
  has_domain "$d/tmp/parsed_s9.txt" only-in-html.example && return 1
  has_domain "$d/tmp/parsed_s9.txt" m2-ok.example
}

# 內容檢查的 fixture
C="$WORK/content"; mkdir -p "$C"
: > "$C/bad_empty"
printf '||a.example^\n\000\n' > "$C/bad_nul"
printf '\037\213\010\000\000\000\000\000' > "$C/bad_gzip"
printf 'PK\003\004rest-of-zip' > "$C/bad_zip"
printf '<!DOCTYPE html>\n<html></html>\n' > "$C/bad_doctype"
printf '\357\273\277<html>\n<body>x</body>\n' > "$C/bad_bom_html"
printf '\n   \r\n\t\r\n<HTML>\n<body>x</body>\n' > "$C/bad_blank_cr_html"
printf '<?xml version="1.0"?>\n<rss/>\n' > "$C/bad_xml"
printf '||a.example^\n||b.example^\n' > "$C/bad_overlimit"          # 搭配 OVERRIDE_MAX=10
printf '[Adblock Plus 2.0]\n||a.example^\n' > "$C/good_adblock"
printf '# hosts\n0.0.0.0 a.example\n' > "$C/good_hosts"
printf 'a.example\nb.example\n' > "$C/good_domains"
printf '[Adblock Plus 2.0]\n! this list blocks ads injected into <html> pages\n||a.example^\n' > "$C/good_comment_html"
printf 'PKG notes: plain text\n||a.example^\n' > "$C/good_pk_text"

content_ok() { bash "$WORK/runner.sh" "$1" "$WORK" fn validate_text_content "$2" 2>/dev/null; }

case_10() {
  local h="$1" f
  for f in bad_empty bad_nul bad_gzip bad_zip bad_doctype bad_bom_html bad_blank_cr_html bad_xml; do
    content_ok "$h" "$C/$f" && return 1
  done
  OVERRIDE_MAX=10 content_ok "$h" "$C/bad_overlimit" && return 1
  content_ok "$h" "$C/bad_overlimit"          # 同一份檔案在預設上限下是合格的（證明是上限擋的）
}

case_11() {
  local h="$1" f
  for f in good_adblock good_hosts good_domains good_comment_html good_pk_text; do
    content_ok "$h" "$C/$f" || return 1
  done
}

case_12() {
  local h="$1" d; d=$(new_sc c12)
  add_source "$d" s12
  state "$d" 'src:s12' 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
  spec "$d" s12 m1 "body='$FX/zero'"
  spec "$d" s12 m2 "body='$FX/m2_ok'"
  run_entry "$h" "$d" gate
  [[ "$(calls "$d" s12)" == "2" ]] && has_domain "$d/tmp/parsed_s12.txt" m2-ok.example
}

case_13() {
  local h="$1" d; d=$(new_sc c13)
  add_source "$d" s13
  state "$d" 'src:s13' "$EMPTY_SHA"
  spec "$d" s13 m1 "body='$FX/zero'"
  spec "$d" s13 m2 "body='$FX/m2_ok'"
  run_entry "$h" "$d" gate
  [[ "$(calls "$d" s13)" == "1" ]] && [[ "$(cat "$d/tmp/sum_s13.txt" 2>/dev/null)" == "$EMPTY_SHA" ]] && ! in_failed "$d" s13
}

case_14() {
  local h="$1" d; d=$(new_sc c14)
  add_source "$d" s14
  spec "$d" s14 m1 "body='$FX/zero'"
  spec "$d" s14 m2 "body='$FX/m2_ok'"
  run_entry "$h" "$d" gate
  [[ "$(calls "$d" s14)" == "1" ]] && [[ "$(cat "$d/tmp/sum_s14.txt" 2>/dev/null)" == "$EMPTY_SHA" ]] && ! in_failed "$d" s14
}

url_ok() { bash "$WORK/runner.sh" "$1" "$WORK" fn validate_source_url "$2" 2>/dev/null; }

case_15() {
  local h="$1" u
  for u in https://h.example/a.txt 'https://h.example/a.txt?v=2' https://h.example/a.TXT 'https://h.example/a.txt#x'; do
    url_ok "$h" "$u" || return 1
  done
  for u in https://h.example/a.html https://h.example/a.txt.html 'https://h.example/a.html?x=.txt' 'https://h.example/a.html#.txt'; do
    url_ok "$h" "$u" && return 1
  done
  return 0
}

case_16() {
  local h="$1" d name long256 long257; d=$(new_sc c16)
  long256=$(printf '%0256d' 0); long257=$(printf '%0257d' 0)
  printf 'HTTP/2 200\r\netag: "ab\tcd"\r\n\r\n'          > "$d/files/h_tab"
  printf 'HTTP/2 200\r\netag: "ab\001cd"\r\n\r\n'        > "$d/files/h_ctl"
  printf 'HTTP/2 200\r\netag: "caf\303\251"\r\n\r\n'     > "$d/files/h_utf8"
  printf 'HTTP/2 200\r\netag: %s\r\n\r\n' "$long257"     > "$d/files/h_257"
  printf 'HTTP/2 200\r\netag: %s\r\nlast-modified: Wed,\t01 Jan\r\n\r\n' "$long256" > "$d/files/h_256"
  for name in tab ctl utf8 257 256; do
    add_source "$d" "s16_$name"
    spec "$d" "s16_$name" m1 "body='$FX/healthy'" "headers='$d/files/h_$name'"
  done
  run_entry "$h" "$d" gate
  for name in tab ctl utf8 257; do
    grep -q "^s16_$name	" "$d/tmp/newmeta.txt" || return 1       # 有記錄這個來源（成功）
    [[ "$(awk -F'\t' -v nm="s16_$name" '$1 == nm { print NF; exit }' "$d/tmp/newmeta.txt")" == "3" ]] || return 1
    [[ -z "$(meta_field "$d" "s16_$name" 2)" ]] || return 1
  done
  [[ "$(meta_field "$d" s16_256 2)" == "$long256" ]] || return 1
  [[ -z "$(meta_field "$d" s16_256 3)" ]]                            # 含 TAB 的 Last-Modified 也丟棄
}

case_17() {
  local h="$1" d name f; d=$(new_sc c17)
  for name in tab esc long; do add_source "$d" "s17_$name"; spec "$d" "s17_$name" m1 "body='$FX/healthy'"; done
  printf 'etag:s17_tab\t"ab"\t"cd"\n'                     >> "$d/prev_state.txt"
  printf 'lastmod:s17_tab\tWed,\t01 Jan 2026\n'           >> "$d/prev_state.txt"
  printf 'etag:s17_esc\t"x\033[31my"\n'                   >> "$d/prev_state.txt"
  printf 'lastmod:s17_esc\tWed, 01 Jan 2026 \001GMT\n'    >> "$d/prev_state.txt"
  printf 'etag:s17_long\t%s\n'    "$(printf '%0300d' 0)" >> "$d/prev_state.txt"
  printf 'lastmod:s17_long\t%s\n' "$(printf '%0300d' 0)" >> "$d/prev_state.txt"
  run_entry "$h" "$d" gate
  for name in tab esc long; do
    f=$(call_argv "$d" "s17_$name" m1)
    [[ -f "$f" ]] || return 1
    grep -qE '^(If-None-Match|If-Modified-Since):' "$f" && return 1
    grep -qx -- '-H' "$f" && return 1
  done
  return 0
}

case_18() {
  local h="$1" d; d=$(new_sc c18)
  add_source "$d" s18
  printf 'HTTP/1.1 301 Moved\r\nLocation: https://hop.example/a.txt\r\nETag: "hop-etag"\r\nLast-Modified: Mon, 01 Jan 2024 00:00:00 GMT\r\n\r\nHTTP/2 200\r\ncontent-type: text/plain\r\n\r\n' > "$d/files/h18"
  spec "$d" s18 m1 "body='$FX/healthy'" "headers='$d/files/h18'"
  run_entry "$h" "$d" gate
  grep -q "^s18	" "$d/tmp/newmeta.txt" && [[ -z "$(meta_field "$d" s18 2)" && -z "$(meta_field "$d" s18 3)" ]]
}

case_19() {
  local h="$1" d; d=$(new_sc c19)
  add_source "$d" s19
  spec "$d" s19 m1 rc=28 code=200 partial=1 "body='$FX/m1_partial_src'" "headers='$FX/hdr_m1'"
  spec "$d" s19 m2 "body='$FX/m2_ok'" "headers='$FX/hdr_m2'"
  run_entry "$h" "$d" gate
  cmp -s "$FX/m2_ok" "$d/tmp/raw_s19.txt" || return 1
  bash "$WORK/runner.sh" "$h" "$d" fn parse_adblock < "$FX/m2_ok" > "$d/expected_parsed"
  cmp -s "$d/expected_parsed" "$d/tmp/parsed_s19.txt" || return 1
  [[ "$(cat "$d/tmp/sum_s19.txt")" == "$(sha_of "$d/expected_parsed")" ]] || return 1
  [[ ! -e "$d/tmp/fetch_s19" ]] || return 1
  [[ "$(cd "$d/tmp" && ls parsed_*.txt 2>/dev/null)" == "parsed_s19.txt" ]]
}

case_20() {
  local h="$1" d name n; d=$(new_sc c20)
  echo 0 > "$d/clock"
  for name in b1 b2 b3 b4; do
    add_source "$d" "$name"
    spec "$d" "$name" m1 rc=7 code=000 nofiles=1
    spec "$d" "$name" m2 rc=7 code=000 nofiles=1
  done
  OVERRIDE_BUDGET=150 run_entry "$h" "$d" gate
  [[ "$(calls "$d" b1)" == "2" && "$(calls "$d" b2)" == "2" && "$(calls "$d" b3)" == "1" && "$(calls "$d" b4)" == "1" ]] || return 1
  n=$(grep -c '時間預算' "$d/log") || n=0
  [[ "$n" == "1" ]]
}

CANARIES=(CANARY_BODY_OK CANARY_BODY_HTML CANARY_HOP_ETAG CANARY_LOCATION CANARY_FINAL_ETAG CANARY_LASTMOD CANARY_FINALURL CANARY_STDERR_1 CANARY_STDERR_2 CANARY_CODE)

case_21() {
  local h="$1" d c; d=$(new_sc c21)
  add_source "$d" c21ok
  add_source "$d" c21fail
  printf '[Adblock Plus 2.0]\n! ##[error]CANARY_BODY_OK\n::warning::CANARY_BODY_OK\n||canary-ok.example^\n' > "$d/files/body_ok"
  printf '<!DOCTYPE html>\n::error::CANARY_BODY_HTML\n##[warning]CANARY_BODY_HTML\n||canary-html.example^\n' > "$d/files/body_html"
  printf 'HTTP/1.1 302 Found\r\nLocation: https://x.example/::error::CANARY_LOCATION.txt\r\nETag: "CANARY_HOP_ETAG"\r\n\r\nHTTP/2 200\r\netag: "##[error]CANARY_FINAL_ETAG"\r\nlast-modified: ::warning::CANARY_LASTMOD\r\ncontent-location: https://final.example/CANARY_FINALURL.txt\r\n\r\n' > "$d/files/h_ok"
  spec "$d" c21ok m1 rc=7 code=000 nofiles=1 "stderr='::error::CANARY_STDERR_1 ##[error]'"
  spec "$d" c21ok m2 "body='$d/files/body_ok'" "headers='$d/files/h_ok'"
  spec "$d" c21fail m1 "code='200::error::CANARY_CODE'" "body='$d/files/body_html'" "stderr='##[error]CANARY_STDERR_2'"
  spec "$d" c21fail m2 "body='$d/files/body_html'" "headers='$d/files/h_ok'"
  run_entry "$h" "$d" gate_summary
  # 前提：真的走過兩個來源、兩種方式，而且成功的那個有被採用
  [[ "$(calls "$d" c21ok)" == "2" && "$(calls "$d" c21fail)" == "2" ]] || return 1
  has_domain "$d/tmp/parsed_c21ok.txt" canary-ok.example || return 1
  in_failed "$d" c21fail || return 1
  [[ -s "$d/summary.md" ]] || return 1
  cat "$d/stdout" "$d/log" "$d/summary.md" > "$d/all_output"
  for c in "${CANARIES[@]}"; do
    grep -q "$c" "$d/all_output" && return 1
  done
  grep -qF '##[' "$d/all_output" && return 1
  grep -q '^::' "$d/all_output" && return 1
  # curl 從來沒有被要求輸出最終網址
  cat "$d"/argv.* | grep -q 'url_effective' && return 1
  return 0
}

argv_rules() {
  # $1 = argv 檔 → 案例 22／27 的共同規則
  local f="$1"
  [[ -f "$f" ]] || return 1
  [[ "$(head -n 1 "$f")" == "-q" ]] || return 1
  awk 'prev == "--proto" && $0 == "=https" { a = 1 }
       prev == "--proto-redir" && $0 == "=https" { b = 1 }
       prev == "--max-redirs" && $0 == "5" { c = 1 }
       prev == "--max-filesize" && $0 ~ /^[0-9]+$/ { d = 1 }
       { prev = $0 }
       END { exit !(a && b && c && d) }' "$f" || return 1
  [[ "$(tail -n 2 "$f" | head -n 1)" == "--" ]] || return 1
  grep -qxE -- '-K|--config' "$f" && return 1
  grep -qE -- '^(-K|--config=)' "$f" && return 1
  return 0
}

case_22() {
  local h="$1" d f1 f2; d=$(new_sc c22)
  add_source "$d" s22
  spec "$d" s22 m1 rc=7 code=000 nofiles=1
  spec "$d" s22 m2 "body='$FX/m2_ok'"
  run_entry "$h" "$d" gate
  [[ "$(calls "$d" s22)" == "2" ]] || return 1
  f1=$(call_argv "$d" s22 m1); f2=$(call_argv "$d" s22 m2)
  argv_rules "$f1" && argv_rules "$f2" || return 1
  grep -qx -- '--http1.1' "$f2" && grep -qx -- '-4' "$f2"
}

# ══════════════════════════════════════════════════════════
# 補抓階段（materialize_sources）
# ══════════════════════════════════════════════════════════
PREVSUM='bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'

mat_sc() {
  # $1 = 標籤, $2 = 來源名 → 情境目錄：notmodified 一筆、前次 src:、閘門階段寫的 sum_
  local d; d=$(new_sc "$1")
  printf '%s|%s|adblock\n' "$2" "$(url_of "$2")" >> "$d/sources.conf"
  printf '%s\t%s\tadblock\n' "$2" "$(url_of "$2")" > "$d/tmp/source_list.txt"
  printf '%s\tadblock\n' "$2" > "$d/tmp/notmodified.txt"
  state "$d" "src:$2" "$PREVSUM"
  state "$d" "etag:$2" '"old"'
  echo "$PREVSUM" > "$d/tmp/sum_$2.txt"
  : > "$d/tmp/failed_sources.txt"
  : > "$d/tmp/newmeta.txt"
  echo "$d"
}
src_lines() { local n; n=$(grep -c "^src:$2	" "$1/tmp/new_state.txt") || n=0; echo "$n"; }

run_mat_23() {
  local h="$1" d; d=$(mat_sc c23 s23)
  spec "$d" s23 m1 rc=28 code=200 partial=1 "body='$FX/m1_partial_src'" "headers='$FX/hdr_m1'"
  spec "$d" s23 m2 "body='$FX/m2_ok'" "headers='$FX/hdr_m2'"
  run_entry "$h" "$d" materialize
  echo "$d"
}

case_23() {
  local h="$1" d; d=$(run_mat_23 "$h")
  has_domain "$d/tmp/parsed_s23.txt" only-in-m1.example && return 1
  has_domain "$d/tmp/parsed_s23.txt" m2-ok.example || return 1
  [[ "$(cat "$d/tmp/sum_s23.txt")" == "$(sha_of "$d/tmp/parsed_s23.txt")" && "$(cat "$d/tmp/sum_s23.txt")" != "$PREVSUM" ]] || return 1
  grep -q "^s23	" "$d/tmp/newmeta.txt" && ! in_failed "$d" s23
}

run_mat_24() {
  local h="$1" d; d=$(mat_sc c24 s24)
  spec "$d" s24 m1 rc=7 code=000 nofiles=1
  spec "$d" s24 m2 rc=7 code=000 nofiles=1
  run_entry "$h" "$d" materialize
  echo "$d"
}

case_24() {
  local h="$1" d; d=$(run_mat_24 "$h")
  in_failed "$d" s24 && [[ ! -e "$d/tmp/sum_s24.txt" ]]
}

case_25() {
  local h="$1" d; d=$(mat_sc c25 s25)
  spec "$d" s25 m1 "body='$FX/zero'"
  spec "$d" s25 m2 "body='$FX/m2_ok'"
  run_entry "$h" "$d" materialize
  [[ "$(calls "$d" s25)" == "2" ]] && has_domain "$d/tmp/parsed_s25.txt" m2-ok.example && ! in_failed "$d" s25
}

case_26() {
  local h="$1" d; d=$(mat_sc c26 s26)
  spec "$d" s26 m1 force304=1          # 逐案例覆寫：對無條件請求也回 304（只有案例 26、30 使用）
  spec "$d" s26 m2 force304=1
  run_entry "$h" "$d" materialize
  in_failed "$d" s26 || return 1
  [[ ! -e "$d/tmp/sum_s26.txt" && ! -e "$d/tmp/parsed_s26.txt" ]] || return 1
  [[ "$(src_lines "$d" s26)" == "1" ]] && grep -qxF "$(printf 'src:s26\t%s' "$PREVSUM")" "$d/tmp/new_state.txt"
}

case_27() {
  local h="$1" d f1 f2; d=$(run_mat_23 "$h")
  [[ "$(calls "$d" s23)" == "2" ]] || return 1
  f1=$(call_argv "$d" s23 m1); f2=$(call_argv "$d" s23 m2)
  argv_rules "$f1" && argv_rules "$f2" || return 1
  grep -qx -- '--http1.1' "$f2" || return 1
  # 補抓一律是無條件請求
  ! grep -qE '^If-(None-Match|Modified-Since):' "$f1" "$f2"
}

case_28() {
  local h="$1" d
  d=$(run_mat_23 "$h")
  [[ "$(src_lines "$d" s23)" == "1" ]] || return 1
  grep -qxF "$(printf 'src:s23\t%s' "$(sha_of "$d/tmp/parsed_s23.txt")")" "$d/tmp/new_state.txt" || return 1
  d=$(run_mat_24 "$h")
  [[ "$(src_lines "$d" s24)" == "1" ]] || return 1
  grep -qxF "$(printf 'src:s24\t%s' "$PREVSUM")" "$d/tmp/new_state.txt"
}

# ══════════════════════════════════════════════════════════
# 失敗嘗試不留下殘骸
# ══════════════════════════════════════════════════════════
case_29() {
  local h="$1" d f; d=$(new_sc c29)
  add_source "$d" s29
  spec "$d" s29 m1 rc=28 code=200 partial=1 "body='$FX/m1_partial_src'" "headers='$FX/hdr_m1'"
  spec "$d" s29 m2 rc=7 code=000 nofiles=1
  run_entry "$h" "$d" gate
  [[ "$(calls "$d" s29)" == "2" ]] || return 1
  in_failed "$d" s29 || return 1
  for f in raw hdr parsed sum fmt; do
    [[ ! -e "$d/tmp/${f}_s29.txt" ]] || return 1
  done
  [[ ! -e "$d/tmp/fetch_s29" ]]
}

# ══════════════════════════════════════════════════════════
# 閘門階段：304 卻沒有前次 checksum
# ══════════════════════════════════════════════════════════
case_30() {
  # 狀態裡有 ETag 但沒有 src:（理論上不會發生，保險路徑）→ 閘門改用無條件請求重抓。
  # 伺服器對無條件請求仍回 304 就是沒有內容可用，必須視為失敗。
  # 這條路若被當成成功：最上層沒有 sum_／parsed_、名字也不進失敗清單，
  # #18 的暫緩移除不會生效，該來源的網域會被從 Gateway 移除。
  local h="$1" d; d=$(new_sc c30)
  add_source "$d" s30
  state "$d" 'etag:s30' '"v30"'
  spec "$d" s30 m1 force304=1          # 逐案例覆寫：對無條件請求也回 304（只有案例 26、30 使用）
  spec "$d" s30 m2 force304=1
  run_entry "$h" "$d" gate
  [[ "$(calls "$d" s30)" == "2" ]] || return 1
  # 這個情境只有一個來源：第一次帶條件式標頭、第二次是無條件請求
  grep -qx 'If-None-Match: "v30"' "$d/argv.1" || return 1
  ! grep -qE '^If-(None-Match|Modified-Since):' "$d/argv.2" || return 1
  in_failed "$d" s30 || return 1
  [[ ! -e "$d/tmp/sum_s30.txt" && ! -e "$d/tmp/parsed_s30.txt" ]] || return 1
  [[ ! -s "$d/tmp/notmodified.txt" ]]
}

run_all_cases() {
  local h="$1"
  echo "閘門階段"
  check "1. 健康狀態：只呼叫一次 curl，argv 與釘住的預期值完全相同" case_1 "$h"
  check "2. ① 回 304：只呼叫一次，沿用前次 checksum" case_2 "$h"
  check "3. ① exit 28 ＋ 200 ＋ 半截內容：視為失敗，採用 ②，ETag 是 ② 的" case_3 "$h"
  check "4. ① exit 63：視為失敗，不嘗試 ②" case_4 "$h"
  check "5. ① 回 000：採用 ② 的內容，ETag 有記錄" case_5 "$h"
  check "6. ① ② 都失敗：進 failed_sources.txt，最上層沒有 parsed_／sum_" case_6 "$h"
  check "7. ① 回 404：不嘗試 ②" case_7 "$h"
  check "8. ① 回 429／503／403：嘗試 ②" case_8 "$h"
  check "9. ① 回 200 但內容是 HTML：嘗試 ②，最上層 parsed_ 是 ② 的" case_9 "$h"
  check "10. 內容檢查：空檔、NUL、gzip、zip、DOCTYPE、BOM＋html、空行＋CR＋HTML、xml、超過上限全部不合格" case_10 "$h"
  check "11. 內容檢查：adblock、hosts、domains、註解提到 <html>、PK 開頭的純文字全部合格" case_11 "$h"
  check "12. 0 筆防護：前次 src: 非空、這次 0 筆 → 嘗試 ②" case_12 "$h"
  check "13. 0 筆防護：前次 src: 是空內容的 sha256 → 成功" case_13 "$h"
  check "14. 0 筆防護：沒有前次 src: → 成功" case_14 "$h"
  check "15. 網址：.txt／?v=2／.TXT／#x 接受；.html／.txt.html 拒絕" case_15 "$h"
  check "16. ETag 含 TAB、控制字元、非 ASCII、長度 257 丟棄；長度 256 保留" case_16 "$h"
  check "17. 狀態裡的舊驗證標頭含 TAB、控制字元、過長：不塞進 -H，改成無條件請求" case_17 "$h"
  check "18. 多組轉址標頭：第一跳有 ETag、最終回應沒有 → 不記錄" case_18 "$h"
  check "19. ① 半截後失敗、② 成功：最上層 raw_／parsed_／sum_ 都是 ② 的，fetch_ 已刪" case_19 "$h"
  check "20. 預算耗盡：後續來源不再嘗試 ②，log 只印一次" case_20 "$h"
  check "21. 金絲雀：本體、標頭、Location、最終網址、stderr、HTTP 碼都不出現在 log／Job Summary" case_21 "$h"
  check "22. ①、② 的 argv：-q 第一、--proto／--proto-redir／--max-redirs／--max-filesize、-- 在網址前、無 -K／--config" case_22 "$h"
  echo "補抓階段"
  check "23. ① exit 28 半截、② 成功：採用 ②，sum_ 被覆寫，newmeta 有記錄" case_23 "$h"
  check "24. ① ② 都失敗：進 failed_sources.txt，最上層 sum_ 已刪除" case_24 "$h"
  check "25. ① 200 但 0 筆、前次 src: 非空：嘗試 ②" case_25 "$h"
  check "26. 無條件請求仍回 304：視為失敗，最上層沒有 sum_／parsed_，src: 只出現一次" case_26 "$h"
  check "27. 補抓的 ①、② argv 符合同一組規則，且不帶條件式標頭" case_27 "$h"
  check "28. 狀態回寫檔裡 src:<name> 只出現一次（23 為新值、24 為前次值）" case_28 "$h"
  echo "失敗嘗試不留下殘骸"
  check "29. ① 半截、② 傳輸前失敗：最上層沒有 raw_／hdr_／parsed_／sum_，fetch_ 已刪" case_29 "$h"
  echo "閘門階段：304 卻沒有前次 checksum"
  check "30. 無條件重抓仍回 304：視為失敗，進 failed_sources.txt，最上層沒有 sum_／parsed_" case_30 "$h"
}

run_all_cases "$HARNESS"
if compgen -G "$WORK/sc/*/stub_errors" > /dev/null; then
  bad "curl 替身收到沒有對應 spec 的請求（fixture 寫錯）：$(cat "$WORK"/sc/*/stub_errors | head -3)"
fi

# ══════════════════════════════════════════════════════════
# 反事實：每一個變異都必須讓對應案例變紅
# ══════════════════════════════════════════════════════════
echo "反事實"

mutate() {
  # $1 = 變異代號, $2 = 函式名；stdin 兩行：第一行 = 要改寫的那一行（完全比對），第二行 = 改成什麼（@@DELETE@@ = 刪除）
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
  # $1 = 描述, $2 = 變異檔, $3.. = 案例編號
  local desc="$1" m="$2"; shift 2
  local c
  for c in "$@"; do
    if [[ "$c" == "self" ]]; then
      if self_check_call_sites "$m"; then bad "反事實 $desc：自我驗證仍然通過"; else ok "反事實 $desc → 自我驗證 exit 2"; fi
    elif "case_$c" "$m"; then
      bad "反事實 $desc：案例 $c 仍然是綠的"
    else
      ok "反事實 $desc → 案例 $c 變紅"
    fi
  done
}

M=$(mutate ignore_rc fetch_source_with_fallback <<'EOF'
    rc=${res%% *}; code=${res##* }
    rc=0; code=${res##* }
EOF
) || exit 2
expect_red "忽略 curl 離開狀態" "$M" 3 23

M=$(mutate retry_63 fetch_source_with_fallback <<'EOF'
        47|63) verdict="stop" ;;
        47) verdict="stop" ;;
EOF
) || exit 2
expect_red "63 也換下一種" "$M" 4

M=$(mutate retry_404 fetch_source_with_fallback <<'EOF'
        000|403|408|425|429|5??) reason="伺服器沒有給出內容" ;;
        000|403|404|408|425|429|5??) reason="伺服器沒有給出內容" ;;
EOF
) || exit 2
expect_red "404 也換下一種" "$M" 7

M=$(mutate no_zero_guard fetch_source_with_fallback <<'EOF'
            if [[ -n "$prev_sum" && "$prev_sum" != "$empty_sum" ]]; then
            if false; then
EOF
) || exit 2
expect_red "拿掉 0 筆防護" "$M" 12 25

M=$(mutate zero_guard_no_empty fetch_source_with_fallback <<'EOF'
            if [[ -n "$prev_sum" && "$prev_sum" != "$empty_sum" ]]; then
            if [[ -n "$prev_sum" ]]; then
EOF
) || exit 2
expect_red "0 筆防護不檢查前次是否為空" "$M" 13

M=$(mutate sanitize_tab sanitize_validator_header <<'EOF'
  rest="$(printf '%s' "$v" | LC_ALL=C tr -d '\040-\176'; printf x)"
  rest="$(printf '%s' "$v" | LC_ALL=C tr -d '\011\040-\176'; printf x)"
EOF
) || exit 2
expect_red "sanitize_validator_header 放行 TAB" "$M" 16

M=$(mutate no_reread_etag curl_source <<'EOF'
    sanitize_validator_header "$et" >/dev/null || et=""
@@DELETE@@
EOF
) || exit 2
expect_red "拿掉讀出時的再驗證（ETag）" "$M" 17

M=$(mutate no_reread_lastmod curl_source <<'EOF'
    sanitize_validator_header "$lm" >/dev/null || lm=""
@@DELETE@@
EOF
) || exit 2
expect_red "拿掉讀出時的再驗證（Last-Modified）" "$M" 17

M=$(mutate state_get_field2 state_get <<'EOF'
  awk -F'\t' -v k="$1" '$1==k { if (index($0, "\t")) { sub(/^[^\t]*\t/, ""); print }; exit }' "$PREV_STATE_FILE"
  awk -F'\t' -v k="$1" '$1==k{print $2; exit}' "$PREV_STATE_FILE"
EOF
) || exit 2
expect_red "state_get 改回只取第二欄（TAB 之後被截掉，前綴照樣送出）" "$M" 17

M=$(mutate header_whole_file header_value <<'EOF'
  last_header_block "$1" \
  tr -d '\r' < "$1" \
EOF
) || exit 2
expect_red "標頭取整份檔案的最後一個" "$M" 18

M=$(mutate write_top_level curl_source <<'EOF'
    -D "$out_dir/headers" -o "$out_dir/body" \
    -D "$TMP_DIR/hdr_$name.txt" -o "$TMP_DIR/raw_$name.txt" \
EOF
) || exit 2
expect_red "嘗試結果直接寫最上層" "$M" 29

M=$(mutate no_html_rule validate_text_content <<'EOF'
  printf '%s\n' "$first" | LC_ALL=C grep -qiE '^[[:space:]]*<(!doctype|html|head|body|\?xml)' && return 1
@@DELETE@@
EOF
) || exit 2
expect_red "拿掉內容檢查的 HTML 規則" "$M" 9 10

M=$(mutate html_512 validate_text_content <<'EOF'
  printf '%s\n' "$first" | LC_ALL=C grep -qiE '^[[:space:]]*<(!doctype|html|head|body|\?xml)' && return 1
  head -c 512 "$f" | LC_ALL=C grep -qi '<html' && return 1
EOF
) || exit 2
expect_red "HTML 規則改成前 512 位元組出現 <html" "$M" 11

M=$(mutate http11_before_q curl_source <<'EOF'
  code=$(curl -q "$@" \
  code=$(curl --http1.1 -q "$@" \
EOF
) || exit 2
expect_red "把 --http1.1 插在 -q 前面" "$M" 22

M=$(mutate mat_direct_curl materialize_sources <<'EOF'
    if ! fetch_source_with_fallback "$name" "$url" "$format" 0 || [[ "$FETCH_STATUS" != "200" ]]; then
    if [[ "$(mkdir -p "$TMP_DIR/mm" && curl_source "$name" "$url" 0 "$TMP_DIR/mm" -sSL)" != *" 200" ]] || ! { parse_source_into "$name" "$format" "$TMP_DIR/mm/body" "$TMP_DIR/mm" && mv "$TMP_DIR/mm/parsed.txt" "$TMP_DIR/parsed_$name.txt" && mv "$TMP_DIR/mm/sum.txt" "$TMP_DIR/sum_$name.txt"; }; then
EOF
) || exit 2
expect_red "materialize_sources 改回直接呼叫 curl_source 並只檢查 200" "$M" 23 27 self

M=$(mutate mat_keep_sum materialize_sources <<'EOF'
      rm -f "$TMP_DIR/sum_$name.txt"
@@DELETE@@
EOF
) || exit 2
expect_red "materialize_sources 失敗時不刪最上層 sum_" "$M" 24 28

M=$(mutate mat_304_ok materialize_sources <<'EOF'
    if ! fetch_source_with_fallback "$name" "$url" "$format" 0 || [[ "$FETCH_STATUS" != "200" ]]; then
    if ! fetch_source_with_fallback "$name" "$url" "$format" 0; then
EOF
) || exit 2
expect_red "materialize_sources 把 304 當成成功" "$M" 26

M=$(mutate gate_refetch_304_ok fetch_and_merge_sources <<'EOF'
      if ! fetch_source_with_fallback "$name" "$url" "$format" 0 || [[ "$FETCH_STATUS" != "200" ]]; then
      if ! fetch_source_with_fallback "$name" "$url" "$format" 0; then
EOF
) || exit 2
expect_red "閘門階段的無條件重抓把 304 當成成功" "$M" 30

echo
echo "通過 $PASS / 失敗 $FAIL"
[[ $FAIL -eq 0 ]]
