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
    appendFileSync(log, JSON.stringify({ method: req.method, url: req.url, headers: req.headers }) + "\n");
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
run_call() {
  # $1 = 呼叫語句的檔案
  local call_file="$1"
  local harness="$WORK/harness.sh"
  {
    echo 'set -u'
    echo "CF_API=\"http://127.0.0.1:$PORT\""
    echo "CF_API_TOKEN='$TOKEN'"
    echo 'CF_ACCOUNT_ID=acct123'
    echo 'D1_DATABASE_ID=db123'
    echo 'KV_NAMESPACE_ID=kv123'
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

echo "通過 $PASS / 失敗 $FAIL"
[[ $FAIL -eq 0 ]]
