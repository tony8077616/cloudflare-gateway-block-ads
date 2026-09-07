#!/usr/bin/env bash
# Cloudflare 呼叫的 Authorization 標頭測試。
#
# 為什麼需要這支測試：token 改成經 `curl --config -` 由 stdin 餵進去之後，這個改動的
# **每一種失敗都長得一模一樣** —— 漏掉 `cf_config_stdin |`、打錯變數名、`-q` 放錯位置，
# 全都收斂成「沒有 Authorization 標頭 → 401 → 被 best-effort 處理器吞掉 → 跑很久才
# 紅燈」，不會當場壞掉。所以驗證不能是「腳本跑得完」，必須**正面斷言標頭真的送到了**。
#
# 做法：起一個只綁 127.0.0.1 的小伺服器記錄收到的標頭，從 sync.sh / manage.sh
# **抽出正在跑的那幾行 curl 呼叫**（不是抄一份平行實作），把 CF_API 指向它，實際發請求，
# 然後檢查伺服器收到的東西。全程離線，不需要任何憑證，不會碰到 Cloudflare。
#
# 用法：bash test/cf-auth-header.test.sh [repo 根目錄]
set -uo pipefail

ROOT="${1:-$(dirname "$0")/..}"
SYNC="$ROOT/sync.sh"
MANAGE="$ROOT/manage.sh"
for f in "$SYNC" "$MANAGE"; do
  [[ -f "$f" ]] || { echo "找不到 $f" >&2; exit 2; }
done

command -v node >/dev/null 2>&1 || { echo "需要 node 才能跑這支測試" >&2; exit 2; }

WORK="$(mktemp -d)"
SERVER_PID=""
cleanup() {
  [[ -n "$SERVER_PID" ]] && kill "$SERVER_PID" 2>/dev/null
  rm -rf "$WORK"
}
trap cleanup EXIT

TOKEN="TESTTOKENabcdefghijklmnopqrstuvwxyz0123456789"
LOG="$WORK/requests.log"

# ── 收標頭的小伺服器 ──────────────────────────────────────
cat > "$WORK/server.mjs" <<'SERVEREOF'
import { createServer } from "node:http";
import { appendFileSync } from "node:fs";
const log = process.argv[2];
const server = createServer((req, res) => {
  let body = "";
  req.on("data", (c) => { body += c; });
  req.on("end", () => {
    appendFileSync(log, JSON.stringify({ method: req.method, url: req.url, headers: req.headers, body }) + "\n");
    res.writeHead(200, { "Content-Type": "application/json" });
    res.end(JSON.stringify({ success: true, result: [] }));
  });
});
server.listen(0, "127.0.0.1", () => {
  process.stdout.write(String(server.address().port) + "\n");
});
SERVEREOF

: > "$LOG"
node "$WORK/server.mjs" "$LOG" > "$WORK/port.txt" &
SERVER_PID=$!

# 等伺服器把埠號印出來（最多 5 秒）
PORT=""
for _ in $(seq 1 50); do
  PORT="$(cat "$WORK/port.txt" 2>/dev/null | tr -d '\r\n')"
  [[ -n "$PORT" ]] && break
  sleep 0.1
done
[[ -n "$PORT" ]] || { echo "❌ 本地伺服器沒有起來" >&2; exit 2; }

# ── 抽取 ──────────────────────────────────────────────────
# 從指定檔案抽出每一個 `cf_config_stdin | curl` 呼叫的完整語句。
# 一個語句從該行開始，一路收到第一個「不以反斜線結尾」的行為止 ——
# 這樣 `resp=$(... )` 這種形式也會被完整收進來（含結尾的括號）。
extract_calls() {
  awk '
    /cf_config_stdin \| curl/ { collecting = 1; n++; }
    collecting {
      print > (outdir "/call_" n ".sh")
      if ($0 !~ /\\$/) { collecting = 0 }
    }
  ' outdir="$1" "$2"
}

mkdir -p "$WORK/sync_calls" "$WORK/manage_calls"
extract_calls "$WORK/sync_calls" "$SYNC"
extract_calls "$WORK/manage_calls" "$MANAGE"

N_SYNC=$(find "$WORK/sync_calls" -name 'call_*.sh' | wc -l | tr -d ' ')
N_MANAGE=$(find "$WORK/manage_calls" -name 'call_*.sh' | wc -l | tr -d ' ')

# 抽取自我驗證：數量不對就是抽壞了或站點被改動了，直接失敗，
# 絕不能默默少測幾個站點還報全過。
if [[ "$N_SYNC" -ne 8 ]]; then
  echo "❌ 抽取失敗：sync.sh 預期 8 個 cf_config_stdin 呼叫，實際抽到 $N_SYNC 個" >&2
  echo "   （新增或移除呼叫點時要同步更新這個數字，並確認新的站點也被這支測試涵蓋）" >&2
  exit 2
fi
if [[ "$N_MANAGE" -ne 3 ]]; then
  echo "❌ 抽取失敗：manage.sh 預期 3 個 cf_config_stdin 呼叫，實際抽到 $N_MANAGE 個" >&2
  exit 2
fi

# ── 執行單一呼叫並回報伺服器收到的標頭 ────────────────────
read_default() {
  # 從受測檔案的設定區讀出一個數值設定。
  # 刻意不在測試裡另外寫死一份 —— 寫死的那份不會跟著受測檔案一起改，
  # 到時候測的就不是出貨的值了。抽不到就直接失敗，不要默默用預設值。
  local name="$1" file="$2" val
  val="$(grep -m1 "^$name=" "$file" | sed "s/^$name=\([0-9][0-9]*\).*/\1/")"
  if [[ ! "$val" =~ ^[0-9]+$ ]]; then
    echo "❌ 抽取失敗：$file 的設定區裡找不到 $name 的數值賦值" >&2
    exit 2
  fi
  printf '%s' "$val"
}

# 目標埠。逾時測試會把它換成停滯／慢速伺服器的埠。
TARGET_PORT="$PORT"

run_call() {
  # $1 = 呼叫語句的檔案
  local call_file="$1"
  local harness="$WORK/harness.sh"
  local def_connect def_stall
  def_connect="$(read_default CF_CONNECT_TIMEOUT "$SRC_FILE")"
  def_stall="$(read_default CF_STALL_TIMEOUT "$SRC_FILE")"
  {
    echo 'set -u'
    echo "CF_API=\"http://127.0.0.1:$TARGET_PORT\""
    echo "CF_API_TOKEN='$TOKEN'"
    echo 'CF_ACCOUNT_ID=acct123'
    echo 'D1_DATABASE_ID=db123'
    echo 'KV_NAMESPACE_ID=kv123'
    # 等待上限取受測檔案的預設值，但允許以環境變數覆寫 ——
    # 逾時測試靠這個把 60 秒換成 2 秒，否則跑一次要等一分鐘。
    echo "CF_CONNECT_TIMEOUT=${CF_CONNECT_TIMEOUT_OVERRIDE:-$def_connect}"
    echo "CF_STALL_TIMEOUT=${CF_STALL_TIMEOUT_OVERRIDE:-$def_stall}"
    # 逐位元照抄受測檔案裡的 cf_config_stdin，不是另外寫一份
    sed -n '/^cf_config_stdin() {/,/^}/p' "$SRC_FILE"
    # 各站點會用到的變數，一律先給安全的假值
    echo 'method=POST'
    echo 'path=/x'
    echo 'body={"a":1}'
    echo "out=\"$WORK/out.bin\""
    echo 'key=k1'
    echo "in=\"$WORK/in.bin\""
    echo 'query=domain=example.com'
    echo "gz=\"$WORK/out.gz\""
    echo 'set +u'
    cat "$call_file"
  } > "$harness"
  printf 'x' > "$WORK/in.bin"
  : > "$LOG"
  bash "$harness" >/dev/null 2>&1
  sleep 0.15
}

PASS=0; FAIL=0
check_site() {
  # $1 = 顯示名稱, $2 = 呼叫語句檔, $3 = 額外要求收到的標頭（可省略）
  local name="$1" call_file="$2" extra="${3:-}"
  run_call "$call_file"
  if [[ ! -s "$LOG" ]]; then
    echo "  ❌ $name —— 伺服器完全沒有收到請求"
    FAIL=$((FAIL + 1))
    return
  fi
  if ! grep -qi "\"authorization\":\"Bearer $TOKEN\"" "$LOG"; then
    echo "  ❌ $name —— 收到請求，但 Authorization 標頭不是預期值（token 沒有送達）"
    FAIL=$((FAIL + 1))
    return
  fi
  if [[ -n "$extra" ]] && ! grep -qi "$extra" "$LOG"; then
    echo "  ❌ $name —— Authorization 正確，但少了 $extra"
    FAIL=$((FAIL + 1))
    return
  fi
  echo "  ✅ $name"
  PASS=$((PASS + 1))
}

# ══════════════════════════════════════════════════════════
# 結構：每一個帶憑證的呼叫都要有等待上限
# ══════════════════════════════════════════════════════════
#
# 執行期斷言只會挑幾個站點實際發請求，所以「某個站點漏了旗標」抓不到。
# 這一段用數量比對把全部站點蓋住：三個旗標各自的出現次數都必須等於管線數。
#
# --speed-limit 不可以省：curl 的低速門檻預設是 0，而 0 代表**不啟用**低速中止 ——
# 只有 --speed-time 而沒有 --speed-limit 的站點，停滯時照樣無限等待。
check_structure() {
  # $1 = 檔案, $2 = 預期的呼叫點數量
  local file="$1" want="$2" name pipes ct sl st
  name="$(basename "$file")"
  pipes=$(grep -c 'cf_config_stdin | curl' "$file")
  ct=$(grep -c -- '--connect-timeout "\$CF_CONNECT_TIMEOUT"' "$file")
  # 註解裡也會提到這些旗標，所以只數非註解行
  sl=$(grep -n -- '--speed-limit 1' "$file" | grep -cv ':[[:space:]]*#')
  st=$(grep -c -- '--speed-time "\$CF_STALL_TIMEOUT"' "$file")
  if [[ "$pipes" -ne "$want" ]]; then
    echo "  ❌ $name 的呼叫點數量是 $pipes，預期 $want（站點有增減就要同步更新這支測試）"
    FAIL=$((FAIL + 1))
    return
  fi
  if [[ "$ct" -eq "$want" && "$sl" -eq "$want" && "$st" -eq "$want" ]]; then
    echo "  ✅ $name：$want 個呼叫點都帶 connect-timeout、speed-limit、speed-time"
    PASS=$((PASS + 1))
  else
    echo "  ❌ $name：$want 個呼叫點中，connect-timeout=$ct、speed-limit=$sl、speed-time=$st"
    FAIL=$((FAIL + 1))
  fi
}

check_var_defined() {
  # $1 = 檔案, $2.. = 變數名。設定區必須有數值賦值，
  # 否則「引用了變數但從未定義」的版本會在 set -u 下當場中止，而測試自備變數看不出來。
  local file="$1"; shift
  local name v ok=1
  name="$(basename "$file")"
  for v in "$@"; do
    if ! grep -q "^$v=[0-9]" "$file"; then
      echo "  ❌ $name 的設定區沒有 $v 的數值賦值"
      ok=0
    fi
  done
  if [[ "$ok" -eq 1 ]]; then
    echo "  ✅ $name：等待上限的變數都有定義"
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
  fi
}

PASS=0; FAIL=0
echo "等待上限的結構檢查"
check_structure "$SYNC" 8
check_structure "$MANAGE" 3
check_var_defined "$SYNC" CF_CONNECT_TIMEOUT CF_STALL_TIMEOUT CF_STALL_TIMEOUT_BULK
check_var_defined "$MANAGE" CF_CONNECT_TIMEOUT CF_STALL_TIMEOUT

echo "Cloudflare 呼叫的 Authorization 標頭（伺服器：127.0.0.1:$PORT）"

echo "sync.sh（8 個站點）"
SRC_FILE="$SYNC"
i=1
while [[ $i -le 8 ]]; do
  f="$WORK/sync_calls/call_$i.sh"
  # D1 批次寫入那一處原本把 Authorization 與 Content-Type 寫在同一行，
  # 整行刪掉是最可能的機械性改寫錯誤，所以額外斷言 Content-Type 有送到。
  #
  # 條件**只能看站點（打到 d1/database）**，絕對不能加上「呼叫文字裡還有
  # application/json」這種條件 —— 那樣一來，刪掉標頭的同時條件也不成立，斷言會
  # 自己消失，缺陷反而變成通過。第一版就是這樣寫的，反事實測試當場抓到。
  if grep -q 'd1/database' "$f"; then
    check_site "sync.sh 呼叫 #$i（D1，額外驗 Content-Type）" "$f" '"content-type":"application/json"'
  else
    check_site "sync.sh 呼叫 #$i" "$f"
  fi
  i=$((i + 1))
done

echo "manage.sh（3 個站點）"
SRC_FILE="$MANAGE"
i=1
while [[ $i -le 3 ]]; do
  f="$WORK/manage_calls/call_$i.sh"
  if grep -q 'd1/database' "$f"; then
    check_site "manage.sh 呼叫 #$i（D1，額外驗 Content-Type）" "$f" '"content-type":"application/json"'
  else
    check_site "manage.sh 呼叫 #$i" "$f"
  fi
  i=$((i + 1))
done


# ══════════════════════════════════════════════════════════
# 等待上限：掛住要中止，慢但有進展不可以被中止
# ══════════════════════════════════════════════════════════
#
# 判準是「停滯」而不是「總時間」。這個區別很重要：分類快取的 D1 全表讀取是單一次查詢
# 取回約 46 萬列，用總時間上限會誤殺它，而那是 KV 未設定時（fork 的預設）的路徑。
#
# 停滯判準有一個必須被記錄下來的性質，而且它**取決於請求有沒有上傳內容**（實測）：
#   無 body 的請求：首位元組延遲會被直接算成停滯，門檻一到就中止。
#   帶 --data 的請求：上傳活動會讓計時重新起算，同樣的延遲反而撐得過去；
#                     但伺服器若完全不回應，最終仍會中止（只是比門檻晚一些）。
# 下面第三、四組就是在釘住這兩種行為。這也是那條取回約 46 萬列的重量級路徑
# （它是帶 body 的 POST）需要另一個刻意取高的上限的背景。

cat > "$WORK/modes.mjs" <<'MODEEOF'
import { createServer } from "node:http";
const mode = process.argv[2];
const arg = Number(process.argv[3] || "0");
const server = createServer((req, res) => {
  if (mode === "stall") {
    return;                                   // 接受連線後永遠不回應
  }
  if (mode === "slow") {                      // 每 500ms 送 1 byte，共 20 次
    res.writeHead(200, { "Content-Type": "text/plain" });
    let n = 0;
    const t = setInterval(() => {
      res.write("x");
      if (++n >= 20) { clearInterval(t); res.end(); }
    }, 500);
    return;
  }
  if (mode === "delay") {                     // 靜默 arg 毫秒後一次送完
    setTimeout(() => {
      res.writeHead(200, { "Content-Type": "application/json" });
      res.end(JSON.stringify({ success: true, result: [] }));
    }, arg);
    return;
  }
  if (mode === "deny") {                      // Cloudflare 拒絕
    res.writeHead(403, { "Content-Type": "application/json" });
    res.end(JSON.stringify({ success: false, errors: [{ code: 10000, message: "Authentication error" }] }));
    return;
  }
  res.writeHead(200, { "Content-Type": "application/json" });
  res.end(JSON.stringify({ success: true, result: [] }));
});
server.listen(0, "127.0.0.1", () => {
  process.stdout.write(String(server.address().port) + "\n");
});
MODEEOF

MODE_PID=""
start_mode() {
  # $1 = 模式, $2 = 參數（可省略）。埠號回傳在 MODE_PORT。
  [[ -n "$MODE_PID" ]] && kill "$MODE_PID" 2>/dev/null
  : > "$WORK/mode_port.txt"
  node "$WORK/modes.mjs" "$1" "${2:-0}" > "$WORK/mode_port.txt" &
  MODE_PID=$!
  MODE_PORT=""
  for _ in $(seq 1 50); do
    MODE_PORT="$(cat "$WORK/mode_port.txt" 2>/dev/null | tr -d '\r\n')"
    [[ -n "$MODE_PORT" ]] && break
    sleep 0.1
  done
  [[ -n "$MODE_PORT" ]] || { echo "❌ $1 伺服器沒有起來" >&2; exit 2; }
}

timed_call() {
  # $1 = 呼叫語句檔。輸出「結束碼 耗時秒數」。
  local s e rc
  s=$(date +%s)
  bash "$WORK/harness.sh" >/dev/null 2>&1
  rc=$?
  e=$(date +%s)
  echo "$rc $((e - s))"
}

SRC_FILE="$SYNC"
CALL="$WORK/sync_calls/call_1.sh"

echo "等待上限"

# ── 1. 停滯必須被中止 ──
start_mode stall
TARGET_PORT="$MODE_PORT"
CF_STALL_TIMEOUT_OVERRIDE=2 run_call "$CALL" >/dev/null 2>&1
read -r rc secs <<< "$(CF_STALL_TIMEOUT_OVERRIDE=2 timed_call)"
if [[ "$rc" -ne 0 && "$secs" -le 10 ]]; then
  echo "  ✅ 接了連線但不回應 → 第 $secs 秒中止（結束碼 $rc）"
  PASS=$((PASS + 1))
else
  echo "  ❌ 接了連線但不回應 → 沒有在期限內中止（結束碼 $rc，耗時 $secs 秒）"
  FAIL=$((FAIL + 1))
fi

# ── 2. 慢但有進展不可以被誤殺 ──
# 這一項直接對應「總時間上限會誤殺大回應」那個回歸風險：
# 傳輸總長 10 秒，遠超過 2 秒的停滯門檻，但因為一直有進展，必須正常完成。
start_mode slow
TARGET_PORT="$MODE_PORT"
CF_STALL_TIMEOUT_OVERRIDE=2 run_call "$CALL" >/dev/null 2>&1
read -r rc secs <<< "$(CF_STALL_TIMEOUT_OVERRIDE=2 timed_call)"
if [[ "$rc" -eq 0 && "$secs" -ge 8 ]]; then
  echo "  ✅ 每 500ms 送 1 byte 共 10 秒 → 正常完成（耗時 $secs 秒，遠超過 2 秒門檻）"
  PASS=$((PASS + 1))
else
  echo "  ❌ 慢但有進展的傳輸被誤殺了（結束碼 $rc，耗時 $secs 秒）"
  FAIL=$((FAIL + 1))
fi

# ── 3. 無 body 的請求：首位元組延遲會被直接算成停滯 ──
# call_2 是 cf_curl 的無 body 分支。這一組釘住「門檻一到就中止」。
CALL_NOBODY="$WORK/sync_calls/call_2.sh"
start_mode delay 6000
TARGET_PORT="$MODE_PORT"
CF_STALL_TIMEOUT_OVERRIDE=2 run_call "$CALL_NOBODY" >/dev/null 2>&1
read -r rc secs <<< "$(CF_STALL_TIMEOUT_OVERRIDE=2 timed_call)"
if [[ "$rc" -ne 0 && "$secs" -le 5 ]]; then
  echo "  ✅ 無 body 的請求 + 靜默 6 秒 → 第 $secs 秒被當成停滯中止"
  PASS=$((PASS + 1))
else
  echo "  ❌ 無 body 請求的首位元組行為與記錄不符（結束碼 $rc，耗時 $secs 秒）"
  FAIL=$((FAIL + 1))
fi

# ── 4. 帶 body 的請求：上傳活動讓計時重新起算，同樣的延遲撐得過去 ──
# 這一組不是在驗「比較好」，是在**記錄實測到的差異**。取回約 46 萬列的那條路徑正是
# 帶 body 的 POST，所以它對長組裝時間的容忍度比無 body 的請求高 —— 但因為沒有那條
# 路徑的實際量測值，設定區仍給它一個刻意取高的專屬上限，寧可太大也不要誤殺。
start_mode delay 6000
TARGET_PORT="$MODE_PORT"
CF_STALL_TIMEOUT_OVERRIDE=2 run_call "$CALL" >/dev/null 2>&1
read -r rc secs <<< "$(CF_STALL_TIMEOUT_OVERRIDE=2 timed_call)"
if [[ "$rc" -eq 0 ]]; then
  echo "  ✅ 帶 body 的請求 + 同樣靜默 6 秒 → 正常完成（耗時 $secs 秒，門檻只有 2 秒）"
  PASS=$((PASS + 1))
else
  echo "  ❌ 帶 body 請求的行為與記錄不符（結束碼 $rc，耗時 $secs 秒）"
  FAIL=$((FAIL + 1))
fi

TARGET_PORT="$PORT"
[[ -n "$MODE_PID" ]] && kill "$MODE_PID" 2>/dev/null

# ══════════════════════════════════════════════════════════
# 刪除空清單：Cloudflare 拒絕時不可以印成成功
# ══════════════════════════════════════════════════════════
#
# 舊寫法是 `if cf_curl DELETE ...; then log "已刪除"; else warn "失敗"; fi`。
# curl 沒有 -f/--fail，HTTP 403/404/500 一律回 0，所以那個 if 幾乎永遠走成功分支。

DEL_BLOCK="$WORK/del_block.sh"
grep -n 'cf_curl DELETE "/accounts/' "$SYNC" > "$WORK/del_anchor.txt"
n_anchor=$(wc -l < "$WORK/del_anchor.txt" | tr -d ' ')
if [[ "$n_anchor" -ne 1 ]]; then
  echo "❌ 抽取失敗：預期 sync.sh 裡恰有 1 處 cf_curl DELETE，實際 $n_anchor 處" >&2
  exit 2
fi
anchor_line=$(cut -d: -f1 "$WORK/del_anchor.txt")
# 從 `local del_resp`（錨點前一行）抓到 `fi`。
# 注意不要多抓一行：再下一行是外層 while 迴圈的 `done`，抓進來會讓函式語法失效
# 而 harness 靜靜吐出空輸出 —— 第一版就是這樣，兩個案例都變成「沒有輸出」。
sed -n "$((anchor_line - 1)),$((anchor_line + 5))p" "$SYNC" > "$DEL_BLOCK"
grep -q 'is_valid_json' "$DEL_BLOCK" || {
  echo "❌ 抽取失敗：抽出來的 DELETE 區塊裡沒有 .success 判定" >&2
  exit 2
}
if grep -q '^\s*done' "$DEL_BLOCK" || ! grep -q '^\s*fi\s*$' "$DEL_BLOCK"; then
  echo "❌ 抽取失敗：DELETE 區塊的範圍不對（應該以 fi 結尾且不含 done）" >&2
  exit 2
fi

run_delete_case() {
  # $1 = 伺服器模式。輸出 log/warn 標記。
  start_mode "$1"
  local h="$WORK/del_harness.sh"
  {
    echo 'set -uo pipefail'
    echo "CF_API=\"http://127.0.0.1:$MODE_PORT\""
    echo "CF_API_TOKEN='$TOKEN'"
    echo 'CF_ACCOUNT_ID=acct123'
    echo "CF_CONNECT_TIMEOUT=$(read_default CF_CONNECT_TIMEOUT "$SYNC")"
    echo "CF_STALL_TIMEOUT=$(read_default CF_STALL_TIMEOUT "$SYNC")"
    echo 'log() { echo "LOG:$*"; }'
    echo 'warn() { echo "WARN:$*"; }'
    sed -n '/^cf_config_stdin() {/,/^}/p' "$SYNC"
    sed -n '/^is_valid_json() {/,/^}/p' "$SYNC"
    sed -n '/^cf_curl() {/,/^}/p' "$SYNC"
    echo 'run_del() {'
    echo '  local eidx=7 eid=list123'
    cat "$DEL_BLOCK"
    echo '}'
    echo 'run_del'
  } > "$h"
  bash "$h" 2>/dev/null
}

echo "刪除空清單的成敗判定"

# 這一組需要 jq（被測的判定式本身就用 jq 讀 .success）。
# 缺 jq 時必須**明確跳過**，不能讓兩個案例都因為 jq 失敗而走 warn 分支 ——
# 那樣「拒絕時走失敗分支」會因為錯誤的理由而通過，是假綠燈。
# CI 的 runner 有 jq，所以這一組在 CI 上是真的有跑到。
if ! command -v jq >/dev/null 2>&1; then
  echo "  ⏭  跳過：這台機器沒有 jq，被測的判定式無法執行（CI 上會實際執行）"
  SKIPPED=$((${SKIPPED:-0} + 2))
else

out_deny="$(run_delete_case deny)"
if echo "$out_deny" | grep -q '^WARN:'; then
  echo "  ✅ Cloudflare 回 403 + success:false → 走失敗分支"
  PASS=$((PASS + 1))
else
  echo "  ❌ Cloudflare 回 403 卻被當成成功：$out_deny"
  FAIL=$((FAIL + 1))
fi

out_ok="$(run_delete_case ok)"
if echo "$out_ok" | grep -q '^LOG:'; then
  echo "  ✅ 回 200 + success:true → 走成功分支"
  PASS=$((PASS + 1))
else
  echo "  ❌ 正常回應卻沒有走成功分支：$out_ok"
  FAIL=$((FAIL + 1))
fi

fi

[[ -n "$MODE_PID" ]] && kill "$MODE_PID" 2>/dev/null

# ══════════════════════════════════════════════════════════
# upload_failures 的寫入端
# ══════════════════════════════════════════════════════════
#
# 這條路徑是「上傳已經失敗之後」的診斷寫入，所以驗收要同時證明兩件事：
#   (a) 真的寫得出可用的紀錄（欄位順序、每一格的值、error_detail 有內容）；
#   (b) 故障時不會讓事情更糟（狀態表不可用就不寫、第一次失敗就放棄、不會空轉）。
#
# 只驗 (a) 是不夠的：一個「永遠寫空字串」或「把受影響筆數和重試次數綁反」的實作，
# 在寬鬆的驗收下能全綠，而使用者看到的仍然是沒用的東西。

echo "upload_failures 的寫入端"

# ── 呼叫點必須落在失敗分支裡 ──
# 移到 case 外面的話，每一份**成功**上傳也會寫一列假的失敗紀錄。
n_def=$(grep -c '^record_upload_failure() {' "$SYNC")
n_call=$(grep -c '^\s*record_upload_failure "' "$SYNC")
if [[ "$n_def" -ne 1 || "$n_call" -ne 1 ]]; then
  echo "  ❌ record_upload_failure 的定義應為 1 個、呼叫應為 1 個，實際 $n_def / $n_call"
  FAIL=$((FAIL + 1))
else
  fail_anchor=$(grep -n 'n_fail=$((n_fail + 1))' "$SYNC" | head -1 | cut -d: -f1)
  # 從錨點往後抓到該分支的 ;; 為止
  awk -v start="$fail_anchor" 'NR >= start { print; if ($0 ~ /^[[:space:]]*;;[[:space:]]*$/) exit }' \
    "$SYNC" > "$WORK/fail_branch.sh"
  in_branch=$(grep -c 'record_upload_failure "' "$WORK/fail_branch.sh")
  if [[ "$in_branch" -eq 1 ]]; then
    echo "  ✅ 呼叫落在上傳失敗分支內（定義 1、呼叫 1）"
    PASS=$((PASS + 1))
  else
    echo "  ❌ 呼叫不在失敗分支內（分支內找到 $in_branch 次）—— 成功上傳也會寫失敗紀錄"
    FAIL=$((FAIL + 1))
  fi
fi

# ── 引數順序 ──
# $resp_raw 仍帶著 __HTTP_STATUS__NNN 的尾巴，傳錯會讓 error_detail 混進狀態碼。
if grep -q 'record_upload_failure "\$name" "\$http_status" "\$affected" "\$attempt" "\$resp"' "$SYNC"; then
  echo "  ✅ 呼叫的引數順序正確（用 \$resp 而不是 \$resp_raw）"
  PASS=$((PASS + 1))
else
  echo "  ❌ 呼叫的引數順序不符預期"
  FAIL=$((FAIL + 1))
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "  ⏭  跳過執行期斷言：這台機器沒有 jq（CI 上會實際執行）"
  SKIPPED=$((${SKIPPED:-0} + 7))
else

uf_harness() {
  # $1 = STATE_AVAILABLE, $2 = 目標埠, $3.. = 額外的行
  local state="$1" port="$2"; shift 2
  local h="$WORK/uf.sh"
  {
    echo 'set -uo pipefail'
    echo "CF_API=\"http://127.0.0.1:$port\""
    echo "CF_API_TOKEN='$TOKEN'"
    echo 'CF_ACCOUNT_ID=acct123'
    echo 'D1_DATABASE_ID=db123'
    echo "STATE_AVAILABLE=$state"
    echo 'D1_WRITES_ADDED=0'
    echo "CF_CONNECT_TIMEOUT=$(read_default CF_CONNECT_TIMEOUT "$SYNC")"
    echo "CF_STALL_TIMEOUT=$(read_default CF_STALL_TIMEOUT "$SYNC")"
    echo "UPLOAD_FAILURE_LOG_MAX=${UF_MAX_OVERRIDE:-$(read_default UPLOAD_FAILURE_LOG_MAX "$SYNC")}"
    echo "UPLOAD_FAILURE_STALL_TIMEOUT=${UF_STALL_OVERRIDE:-$(read_default UPLOAD_FAILURE_STALL_TIMEOUT "$SYNC")}"
    echo "UPLOAD_FAILURE_DETAIL_MAX=$(read_default UPLOAD_FAILURE_DETAIL_MAX "$SYNC")"
    echo 'UPLOAD_FAILURE_LOGGED=0'
    echo 'UPLOAD_FAILURE_LOG_GAVE_UP=0'
    echo 'log() { :; }'
    echo 'warn() { :; }'
    sed -n '/^cf_config_stdin() {/,/^}/p' "$SYNC"
    sed -n '/^is_valid_json() {/,/^}/p' "$SYNC"
    sed -n '/^cf_curl() {/,/^}/p' "$SYNC"
    sed -n '/^d1_query() {/,/^}/p' "$SYNC"
    sed -n '/^record_upload_failure() {/,/^}/p' "$SYNC"
    for line in "$@"; do echo "$line"; done
  } > "$h"
  : > "$LOG"
  bash "$h" >/dev/null 2>&1
  UF_RC=$?
  sleep 0.2
}

body_of_last() { tail -1 "$LOG" | jq -r '.body'; }

# ── 欄位順序與每一格的值 ──
TARGET_PORT="$PORT"
uf_harness 1 "$PORT" 'record_upload_failure "Block ads - 042" "502" "777" "3" "{\"errors\":[{\"code\":10001,\"message\":\"ZQXJ-detail\"}]}"'
b="$(body_of_last)"
sql="$(jq -r '.sql' <<< "$b" 2>/dev/null)"
if [[ "$sql" == *"INSERT INTO upload_failures (run_at, list_name, http_status, error_detail, domain_count_affected, attempt_count) VALUES (?, ?, ?, ?, ?, ?)"* ]]; then
  echo "  ✅ SQL 的欄位清單與順序正確"
  PASS=$((PASS + 1))
else
  echo "  ❌ SQL 的欄位清單或順序不符：$sql"
  FAIL=$((FAIL + 1))
fi

p0="$(jq -r '.params[0]' <<< "$b" 2>/dev/null)"
p1="$(jq -r '.params[1]' <<< "$b" 2>/dev/null)"
p2="$(jq -r '.params[2]' <<< "$b" 2>/dev/null)"
p3="$(jq -r '.params[3]' <<< "$b" 2>/dev/null)"
p4="$(jq -r '.params[4]' <<< "$b" 2>/dev/null)"
p5="$(jq -r '.params[5]' <<< "$b" 2>/dev/null)"
now="$(date +%s)"
ok=1
[[ "$p0" =~ ^[0-9]+$ ]] && [[ $((now - p0)) -ge 0 && $((now - p0)) -le 120 ]] || ok=0
[[ "$p1" == "Block ads - 042" ]] || ok=0
[[ "$p2" == "502" ]] || ok=0
[[ "$p4" == "777" ]] || ok=0
[[ "$p5" == "3" ]] || ok=0
if [[ "$ok" -eq 1 ]]; then
  echo "  ✅ 六格參數逐格正確（run_at 是接近當下的整數、受影響筆數與重試次數沒有綁反）"
  PASS=$((PASS + 1))
else
  echo "  ❌ 參數逐格比對失敗：[$p0, $p1, $p2, ..., $p4, $p5]"
  FAIL=$((FAIL + 1))
fi

# error_detail 必須真的有內容 —— 一個永遠送空字串的實作在別的斷言下全都能過。
if [[ "$p3" == *"ZQXJ-detail"* ]]; then
  echo "  ✅ error_detail 那一格確實帶著錯誤內容"
  PASS=$((PASS + 1))
else
  echo "  ❌ error_detail 那一格沒有內容：[$p3]"
  FAIL=$((FAIL + 1))
fi

# ── 控制字元：原始位元組與 jq 的轉義形式都不可以出現 ──
# 只驗「原始位元組不在」是不夠的：jq --arg 本來就會把它們編碼成 ，
# 所以那種斷言在「完全沒有剝除」的實作上也會通過。
uf_harness 1 "$PORT" 'evil=$(printf "AAA\033[31mRED\007BBB")' 'record_upload_failure "L" "500" "1" "1" "$evil"'
b="$(body_of_last)"
# 兩種形式都要檢查。第一版只比對了原始位元組，結果「完全拿掉剝除步驟」的版本
# 照樣綠燈 —— 因為 jq --arg 會把控制位元組編碼成 \u001b 這種**純 ASCII 轉義文字**，
# 原始位元組當然就不在 body 裡了。這個洞是把缺陷推上 CI 實跑才發現的。
if [[ "$b" == *$'\033'* || "$b" == *$'\007'* ]]; then
  echo "  ❌ 控制字元沒有被剝除：body 裡仍有原始控制位元組"
  FAIL=$((FAIL + 1))
elif printf '%s' "$b" | grep -q '\\u00'; then
  echo "  ❌ 控制字元沒有被剝除：被 jq 編成 \\u00XX 轉義後寫進去了"
  FAIL=$((FAIL + 1))
else
  echo "  ✅ 控制字元已在寫入前剝除（原始位元組與 \\u00XX 轉義形式都不存在）"
  PASS=$((PASS + 1))
fi

# ── UTF-8 安全：截斷不可以把多位元組序列切半 ──
long_cjk="$(python -c "print('中文錯誤訊息' * 120)" 2>/dev/null || printf '中文錯誤訊息%.0s' $(seq 1 120))"
uf_harness 1 "$PORT" "long='$long_cjk'" 'record_upload_failure "L" "500" "1" "1" "$long"'
n_req=$(wc -l < "$LOG" | tr -d ' ')
b="$(body_of_last)"
if [[ "$n_req" -eq 1 ]] && jq -e . >/dev/null 2>&1 <<< "$b" && printf '%s' "$b" | iconv -f UTF-8 -t UTF-8 >/dev/null 2>&1; then
  echo "  ✅ 跨過截斷邊界的中文內容：仍是合法 JSON 且是合法 UTF-8"
  PASS=$((PASS + 1))
else
  echo "  ❌ 截斷把 UTF-8 切半了（請求數 $n_req）"
  FAIL=$((FAIL + 1))
fi

# ── 狀態表不可用時完全不寫 ──
uf_harness 0 "$PORT" 'record_upload_failure "L" "500" "1" "1" "{}"'
n_req=$(wc -l < "$LOG" | tr -d ' ')
if [[ "$n_req" -eq 0 && "$UF_RC" -eq 0 ]]; then
  echo "  ✅ STATE_AVAILABLE=0 時一個請求都不送（結束碼 0）"
  PASS=$((PASS + 1))
else
  echo "  ❌ 狀態表不可用時仍送了 $n_req 個請求（結束碼 $UF_RC）"
  FAIL=$((FAIL + 1))
fi

# ── 故障時不空轉：第一次寫入失敗就放棄 ──
# 這是這一片最重要的一項。大量上傳失敗最典型的原因就是 Cloudflare 不可用，
# 若每一列都等到停滯上限才放棄，會把「有失敗但完成」的執行推成被 job timeout 砍掉。
start_mode stall
calls=""
i=1
while [[ $i -le 22 ]]; do
  calls="$calls"$'\n''record_upload_failure "L'"$i"'" "500" "1" "1" "{}"'
  i=$((i + 1))
done
printf '%s' "$calls" > "$WORK/uf_calls.txt"
s=$(date +%s)
UF_STALL_OVERRIDE=2 uf_harness 1 "$MODE_PORT" "$(cat "$WORK/uf_calls.txt")"
e=$(date +%s)
n_req=$(wc -l < "$LOG" | tr -d ' ')
if [[ "$n_req" -le 1 && $((e - s)) -lt 10 && "$UF_RC" -eq 0 ]]; then
  echo "  ✅ 伺服器不回應時：只送出 $n_req 個請求、$((e - s)) 秒內結束、結束碼 0（不會空轉）"
  PASS=$((PASS + 1))
else
  echo "  ❌ 故障時空轉了：送出 $n_req 個請求、耗時 $((e - s)) 秒、結束碼 $UF_RC"
  FAIL=$((FAIL + 1))
fi

# ── 上限 ──
TARGET_PORT="$PORT"
UF_MAX_OVERRIDE=3 uf_harness 1 "$PORT" "$(cat "$WORK/uf_calls.txt")"
n_req=$(wc -l < "$LOG" | tr -d ' ')
if [[ "$n_req" -eq 3 ]]; then
  echo "  ✅ 達到上限（3）之後不再寫入：實際送出 $n_req 個請求"
  PASS=$((PASS + 1))
else
  echo "  ❌ 上限沒有生效：送出 $n_req 個請求，預期 3"
  FAIL=$((FAIL + 1))
fi

[[ -n "$MODE_PID" ]] && kill "$MODE_PID" 2>/dev/null

fi
if [[ "${SKIPPED:-0}" -gt 0 ]]; then
  echo "通過 $PASS / 失敗 $FAIL / 跳過 ${SKIPPED}（缺少 jq）"
else
  echo "通過 $PASS / 失敗 $FAIL"
fi
[[ $FAIL -eq 0 ]]
