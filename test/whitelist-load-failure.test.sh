#!/usr/bin/env bash
# 「白名單讀不到」與「白名單真的是零筆」必須被分開處理的測試。
#
# 為什麼需要這支測試：這兩種情況在程式裡長得**一模一樣**（都是零行輸出），
# 但語意完全相反 ——
#   零筆 → 使用者沒有設白名單，應該照常放行全部網域（全新安裝的必經路徑）
#   讀不到 → 無從判斷該放行什麼，硬做下去會把使用者明確放行的網域封回去
#
# 2026-09-04/05 線上實際走過這條路：Actions 裡的 token 沒有 D1 權限，白名單讀取回 401、
# 被當成空白名單。當時是另一個 bug（空白名單把整份清單扣光）意外擋下了上傳；
# 那個 bug 修掉之後，這裡就變成「照常上傳一份沒有套用白名單的清單」。
#
# 這支測試最重要的案例是**案例 1（零筆仍須成功）**，不是那些失敗案例。
# 一個天真的實作（「輸出是空的就算失敗」）會通過每一個失敗案例，
# 卻讓每一次全新安裝都掛掉。所以每道守衛都配一個反事實：把守衛單獨拿掉，
# 對應的案例必須真的變紅。
#
# 做法：從 sync.sh **抽出正在跑的那幾個函式**（不是抄一份平行實作），
# 用假的 d1_query 餵各種回應進去，看回傳狀態、輸出行數與重試次數。
# 全程離線，不需要任何憑證，不會碰到 Cloudflare。
#
# 用法：bash test/whitelist-load-failure.test.sh [repo 根目錄]
set -uo pipefail

ROOT="${1:-$(dirname "$0")/..}"
SYNC="$ROOT/sync.sh"
[[ -f "$SYNC" ]] || { echo "找不到 $SYNC" >&2; exit 2; }

# jq 不是選用的：sync.sh 沒有 jq 根本跑不起來，而這支測試驗的就是它對回應的判讀。
# 這裡刻意用 exit 2 而不是「跳過但回傳 0」—— 跳過被當成通過，正是這個 repo 踩過的坑。
command -v jq >/dev/null 2>&1 || { echo "需要 jq 才能跑這支測試" >&2; exit 2; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# ── 抽取 ──────────────────────────────────────────────────
# 先把 CR 去掉再交給 awk。工作目錄裡的 sync.sh 在 Windows 上是 CRLF，
# 而各家 awk 對 CR 的處理不一致（MSYS 的會吃掉、Linux 的不會），
# 靠那個差異等於把測試能不能跑建立在實作細節上。先正規化就與平台無關。
tr -d '\r' < "$SYNC" > "$WORK/sync_lf.sh"

extract_fn() {
  # $1 = 函式名稱。抽出「^name() {」到隨後第一個「^}」為止（含）。
  awk -v fn="$1" '
    $0 == fn "() {" { inside = 1 }
    inside          { print }
    inside && $0 == "}" { exit }
  ' "$WORK/sync_lf.sh"
}

: > "$WORK/extracted.sh"
for fn in is_valid_json _load_domain_column load_whitelist load_custom_blocklist; do
  extract_fn "$fn" > "$WORK/fn_$fn.sh"
  if [[ ! -s "$WORK/fn_$fn.sh" ]]; then
    echo "❌ 抽取失敗：在 sync.sh 裡找不到函式 $fn（可能已被改名）" >&2
    exit 2
  fi
  # 收尾的大括號少抽或多抽都會讓後面的斷言變成假的，所以這裡直接檢查。
  if [[ "$(tail -n 1 "$WORK/fn_$fn.sh")" != "}" ]]; then
    echo "❌ 抽取失敗：$fn 抽出來的最後一行不是收尾的大括號" >&2
    exit 2
  fi
  cat "$WORK/fn_$fn.sh" >> "$WORK/extracted.sh"
  echo >> "$WORK/extracted.sh"
done

# 確認抽到的真的是我們要驗的那段邏輯，而不是剛好同名的另一個東西。
for marker in 'type == "array"' 'errors\[0\].code' 'for attempt in 1 2 3'; do
  if ! grep -q "$marker" "$WORK/extracted.sh"; then
    echo "❌ 抽取自我驗證失敗：抽出來的程式裡找不到「$marker」" >&2
    echo "   守衛可能被改掉了，而這支測試會因此驗不到東西 —— 先確認 sync.sh 的改動是不是故意的。" >&2
    exit 2
  fi
done

# ── 執行器 ────────────────────────────────────────────────
# 每個案例都跑在一個獨立的 bash 行程裡，避免上一個案例的函式定義或計數殘留。
cat > "$WORK/runner.sh" <<'RUNNEREOF'
#!/usr/bin/env bash
# $1 = 要載入的函式檔, $2 = 回應目錄, $3 = 要呼叫的函式
# 印出「狀態<TAB>輸出行數<TAB>d1_query 呼叫次數<TAB>sleep 次數」
set -uo pipefail
HARNESS="$1"; RESP_DIR="$2"; FN="$3"
OUT="$RESP_DIR/stdout.txt"
CALLS="$RESP_DIR/calls.log"
SLEEPS="$RESP_DIR/sleeps.log"
: > "$CALLS"; : > "$SLEEPS"

warn() { :; }
# 計數一定要記在檔案裡，不能用 shell 變數：被測函式是用 resp=$(d1_query ...) 呼叫的，
# 那是命令替換、也就是子行程，子行程裡對變數的遞增傳不回父行程 ——
# 計數會永遠是 0，而「重試了幾次」的斷言就會變成恆真的假斷言。
d1_query() {
  printf 'x\n' >> "$CALLS"
  local n f
  n=$(wc -l < "$CALLS" | tr -d ' ')
  f="$RESP_DIR/$n"
  [[ -f "$f" ]] || f="$RESP_DIR/last"
  cat "$f"
}
# 把 sleep 換掉，免得每個失敗案例都真的等 6 秒。次數同樣記進檔案，
# 這樣「重試迴圈有沒有真的退避」也能被斷言，而不是只能相信它。
sleep() { printf 'x\n' >> "$SLEEPS"; }

# shellcheck disable=SC1090
source "$HARNESS"

"$FN" > "$OUT"
st=$?
if [[ -s "$OUT" ]];    then lines=$(wc -l < "$OUT" | tr -d ' ');    else lines=0; fi
if [[ -s "$CALLS" ]];  then calls=$(wc -l < "$CALLS" | tr -d ' ');  else calls=0; fi
if [[ -s "$SLEEPS" ]]; then naps=$(wc -l < "$SLEEPS" | tr -d ' ');  else naps=0; fi
printf '%s\t%s\t%s\t%s\n' "$st" "$lines" "$calls" "$naps"
RUNNEREOF

mk_resp_dir() {
  # $1 = 目錄名。回傳路徑。後續用 > "$dir/last" 或 "$dir/1" 放回應。
  local d="$WORK/resp_$1"
  rm -rf "$d"; mkdir -p "$d"
  echo "$d"
}

run() {
  # $1 = 回應目錄, $2 = 函式檔（預設用未變動的抽取結果）, $3 = 函式名
  bash "$WORK/runner.sh" "${2:-$WORK/extracted.sh}" "$1" "${3:-load_whitelist}"
}

# ── 回應素材 ──────────────────────────────────────────────
rows_json() {
  # $1 = 筆數。產生 {"success":true,"result":[{"results":[{"domain":"dN.example"},...]}]}
  jq -nc --argjson n "$1" '
    {success: true, result: [{results: [range(0; $n) | {domain: ("d" + (. | tostring) + ".example")}]}]}
  '
}

PASS=0; FAIL=0
check() {
  # $1 = 案例名稱, $2 = 期望（狀態/行數/呼叫次數，用 - 代表不檢查）, $3 = 實得
  local name="$1" want="$2" got="$3"
  local w_st w_ln w_calls g_st g_ln g_calls
  IFS='/' read -r w_st w_ln w_calls <<< "$want"
  IFS=$'\t' read -r g_st g_ln g_calls _ <<< "$got"
  local ok=1
  [[ "$w_st"    == "-" || "$w_st"    == "$g_st"    ]] || ok=0
  [[ "$w_ln"    == "-" || "$w_ln"    == "$g_ln"    ]] || ok=0
  [[ "$w_calls" == "-" || "$w_calls" == "$g_calls" ]] || ok=0
  if [[ $ok -eq 1 ]]; then
    echo "  ✅ $name"
    PASS=$((PASS + 1))
  else
    echo "  ❌ $name：期望 狀態/行數/呼叫=$want，實得 狀態/行數/呼叫=$g_st/$g_ln/$g_calls"
    FAIL=$((FAIL + 1))
  fi
}

echo "── 正常與失敗的分辨 ──"

# 案例 1：真正的零筆。**這是最重要的一個案例。**
# 全新安裝的 custom_whitelist 就是零筆，必須成功、輸出空、而且只查一次（不該重試）。
D=$(mk_resp_dir zero); echo '{"success":true,"result":[{"results":[]}]}' > "$D/last"
ZERO_OUT="$(run "$D")"
check "零筆白名單 → 成功、輸出空、不重試" "0/0/1" "$ZERO_OUT"

# 案例 2：47 筆（跟線上實際的白名單筆數一致）。
D=$(mk_resp_dir rows47); rows_json 47 > "$D/last"
check "47 筆 → 成功、47 行、不重試" "0/47/1" "$(run "$D")"

# 抽取自我驗證：已知會成功的案例如果得不到預期輸出，就是抽壞了，
# 後面每一個「應該失敗」的斷言都會因為程式根本沒跑而假通過。
if [[ "$(printf '%s' "$ZERO_OUT" | cut -f1)" != "0" ]]; then
  echo "❌ 抽取自我驗證失敗：已知應該成功的零筆案例卻回傳非 0，抽出來的程式沒有正常執行" >&2
  exit 2
fi

# 案例 3：D1 明講失敗（線上 401 就是長這樣）。三次都失敗 → 查三次、退避兩次。
D=$(mk_resp_dir succfalse)
echo '{"success":false,"errors":[{"code":10000,"message":"Authentication error"}],"result":null}' > "$D/last"
FAIL3_OUT="$(run "$D")"
check "success 為 false → 失敗、輸出空、重試三次" "1/0/3" "$FAIL3_OUT"

# 退避單獨斷言一次。三次嘗試之間應該退避兩次（最後一次失敗後不必再等）。
# 沒有這一條的話，一個「重試但完全不等」的實作照樣全綠 ——
# 而那種實作在真的遇到速率限制時，只會用三倍的速度再撞三次。
naps="$(printf '%s' "$FAIL3_OUT" | cut -f4)"
if [[ "$naps" == "2" ]]; then
  echo "  ✅ 三次嘗試之間確實退避了兩次"
  PASS=$((PASS + 1))
else
  echo "  ❌ 退避次數不對：期望 2，實得 $naps"
  FAIL=$((FAIL + 1))
fi

# 案例 4：上游代理回 HTML 錯誤頁。
D=$(mk_resp_dir html); printf '<html><head><title>502 Bad Gateway</title></head></html>' > "$D/last"
check "HTML 錯誤頁 → 失敗、輸出空" "1/0/3" "$(run "$D")"

# 案例 5：curl 整個死掉，什麼都沒吐出來。
D=$(mk_resp_dir empty); : > "$D/last"
check "空回應 → 失敗、輸出空" "1/0/3" "$(run "$D")"

# 案例 6：結構漏洞。success 是 true，但 .result 是空陣列，
# 於是 .result[0].results[]?.domain 安靜地吐空 —— 只檢查 .success 的實作會把它當成零筆。
D=$(mk_resp_dir shape); echo '{"success":true,"result":[]}' > "$D/last"
check "success=true 但沒有結果集 → 失敗（不可誤判為零筆）" "1/0/3" "$(run "$D")"

# 案例 7：筆數不符。3 筆進來，其中一筆的 domain 是 null，// empty 會把它靜默丟掉。
# 這是「白名單只套用了一部分」，比整份讀不到更難察覺。
D=$(mk_resp_dir partial)
echo '{"success":true,"result":[{"results":[{"domain":"a.example"},{"domain":null},{"domain":"c.example"}]}]}' > "$D/last"
check "有列缺 domain（3 筆只取到 2 筆）→ 失敗" "1/0/3" "$(run "$D")"

# 案例 8：暫時性失敗之後恢復。這就是重試存在的理由 ——
# 少了它，單一次 5xx 就會殺掉整個小時的執行。
D=$(mk_resp_dir transient)
echo '{"success":false,"errors":[{"code":10000}],"result":null}' > "$D/1"
rows_json 2 > "$D/last"
check "第一次失敗、第二次成功 → 成功、2 行、共查兩次" "0/2/2" "$(run "$D")"

# 自訂封鎖清單走的是同一個實作，確認它真的接上了（而不是只有白名單被修）。
D=$(mk_resp_dir bl_fail)
echo '{"success":false,"errors":[{"code":10000}],"result":null}' > "$D/last"
check "自訂封鎖清單讀取失敗 → 同樣失敗" "1/0/3" "$(run "$D" "" load_custom_blocklist)"
D=$(mk_resp_dir bl_zero); echo '{"success":true,"result":[{"results":[]}]}' > "$D/last"
check "自訂封鎖清單零筆 → 同樣成功" "0/0/1" "$(run "$D" "" load_custom_blocklist)"

# ── 反事實 ────────────────────────────────────────────────
# 每道守衛單獨拿掉之後，對應的案例必須真的變紅。
# 少了這一段，上面全綠只能證明「目前的程式通過了」，不能證明「守衛真的在起作用」。
echo
echo "── 反事實（守衛必須是必要的）──"

mutate() {
  # $1 = sed 運算式, $2 = 輸出檔
  sed "$1" "$WORK/extracted.sh" > "$2"
  if cmp -s "$WORK/extracted.sh" "$2"; then
    echo "  ❌ 變異沒有改到任何東西（sed 樣式過時）：$1"
    FAIL=$((FAIL + 1))
    return 1
  fi
  return 0
}

counterfactual() {
  # $1 = 名稱, $2 = sed 運算式, $3 = 回應目錄, $4 = 原本期望的狀態（變異後必須不同）
  local name="$1" expr="$2" dir="$3" want_st="$4"
  local mutated="$WORK/mutated.sh"
  mutate "$expr" "$mutated" || return
  local got_st
  # 變異版本本來就會亂噴（例如對 null 做迭代的 jq 錯誤），那是預期內的，不要污染輸出。
  got_st="$(run "$dir" "$mutated" 2>/dev/null | cut -f1)"
  if [[ "$got_st" == "$want_st" ]]; then
    echo "  ❌ $name：拿掉守衛之後結果沒變（仍然是狀態 $got_st）—— 這個守衛沒有被驗到"
    FAIL=$((FAIL + 1))
  else
    echo "  ✅ $name：拿掉守衛之後從狀態 $want_st 變成 $got_st"
    PASS=$((PASS + 1))
  fi
}

# 反事實 A：最後的 return 1 改成 return 0（就是原本那個「裸 return 等於 0」的 bug）。
D=$(mk_resp_dir cf_a)
echo '{"success":false,"errors":[{"code":10000}],"result":null}' > "$D/last"
counterfactual "失敗時回傳非 0" 's/^  return 1$/  return 0/' "$D" 1

# 反事實 B：拿掉結構斷言，案例 6 就會被誤判成零筆並且成功。
D=$(mk_resp_dir cf_b); echo '{"success":true,"result":[]}' > "$D/last"
counterfactual "結構斷言（不可把沒有結果集誤判為零筆）" \
  's/^    elif ! jq -e .\.result\[0\]\.results | type == "array". <<< "\$resp" >\/dev\/null 2>&1; then$/    elif false; then/' \
  "$D" 1

# 反事實 C：拿掉筆數比對，案例 7 就會靜靜地只套用一部分白名單。
D=$(mk_resp_dir cf_c)
echo '{"success":true,"result":[{"results":[{"domain":"a.example"},{"domain":null},{"domain":"c.example"}]}]}' > "$D/last"
counterfactual "筆數比對（不可靜默漏掉幾筆）" \
  's/^      if \[\[ "\$expected" == "\$actual" \]\]; then$/      if true; then/' "$D" 1

# 反事實 D：天真實作 ——「輸出是空的就算失敗」。
# 它會通過上面每一個失敗案例，但會讓**全新安裝**掛掉。這是這支測試真正要守的東西。
D=$(mk_resp_dir cf_d); echo '{"success":true,"result":[{"results":[]}]}' > "$D/last"
counterfactual "零筆必須成功（天真實作會在這裡露餡）" \
  's/^      if \[\[ "\$expected" == "\$actual" \]\]; then$/      if [[ -n "$out" ]]; then/' "$D" 0

echo
echo "通過 $PASS / 失敗 $FAIL"
[[ $FAIL -eq 0 ]]
