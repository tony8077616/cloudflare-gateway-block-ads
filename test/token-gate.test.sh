#!/usr/bin/env bash
# CF_API_TOKEN 格式閘門的測試。
#
# 這道閘門有兩個目的：
#   1. 格式不對的 token 在一秒內中止，而不是讓每個 Cloudflare 呼叫都 401、被沿路的
#      best-effort 處理器逐一吞掉、跑滿數十分鐘才紅燈。
#   2. token 會被放進 curl 設定檔的 `header = "..."` 字串裡，而設定檔語法會解譯引號與
#      反斜線 —— 值裡有 " 或 \ 或換行就能跳出字串、多塞一個設定項目（output =、proxy =）。
#
# 另外驗一件同樣重要的事：**訊息裡不能出現 token 的任何片段**。日誌的 secret 遮蔽是
# 精確字串比對，任何遮罩或裁切都會產生一個與 secret 不同的字串，因而不會被遮成 ***，
# 會明文寫進公開 repo 的執行日誌。
#
# 用法：bash test/token-gate.test.sh [sync.sh 的路徑]
set -uo pipefail

SYNC="${1:-$(dirname "$0")/../sync.sh}"
[[ -f "$SYNC" ]] || { echo "找不到 $SYNC" >&2; exit 2; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# 抽出正在跑的 trim 與 validate_api_token，不抄平行實作。
{
  echo 'warn() { echo "WARN: $*" >&2; }'
  sed -n '/^trim() {/,/^}/p' "$SYNC"
  sed -n '/^validate_api_token() {/,/^}/p' "$SYNC"
  echo 'validate_api_token'
  echo 'printf "TOKEN_AFTER=[%s]\n" "$CF_API_TOKEN"'
} > "$WORK/gate.sh"

# 抽取自我驗證：兩個函式都要抽到，否則整組測試會變成在測一個空殼。
for fn in 'trim()' 'validate_api_token()'; do
  grep -q "^$fn {" "$WORK/gate.sh" || {
    echo "❌ 抽取失敗：$SYNC 裡找不到 $fn" >&2
    exit 2
  }
done

PASS=0; FAIL=0

run_gate() {
  # $1 = token 值。輸出寫進 $WORK/out、$WORK/err，回傳結束碼。
  CF_API_TOKEN="$1" bash "$WORK/gate.sh" > "$WORK/out" 2> "$WORK/err"
}

expect_accept() {
  # $1 = 名稱, $2 = token, $3 = 預期 trim 後的值
  local name="$1"
  if run_gate "$2" && grep -qF "TOKEN_AFTER=[$3]" "$WORK/out"; then
    echo "  ✅ $name"
    PASS=$((PASS + 1))
  else
    echo "  ❌ $name（結束碼 $?，實際：$(cat "$WORK/out")）"
    FAIL=$((FAIL + 1))
  fi
}

expect_reject() {
  local name="$1"
  if run_gate "$2"; then
    echo "  ❌ $name —— 閘門放行了，應該要拒絕"
    FAIL=$((FAIL + 1))
  else
    echo "  ✅ $name"
    PASS=$((PASS + 1))
  fi
}

GOOD="ZQXJVBWKPMTRNDGHFLSYCUAEIOZQXJVBWKPMTRNDG"

echo "CF_API_TOKEN 格式閘門（來源：$SYNC）"

expect_accept '正常 token 原樣通過' "$GOOD" "$GOOD"
expect_accept '尾端換行 → 修剪後通過' "$GOOD
" "$GOOD"
expect_accept '前後空白 → 修剪後通過' "  $GOOD  " "$GOOD"
expect_reject '含雙引號 → 拒絕（能跳出 curl 設定檔的字串）' "${GOOD}\"x"
expect_reject '含反斜線 → 拒絕' "${GOOD}\\x"
expect_reject '中段換行 → 拒絕（trim 只修頭尾，中段換行能多塞設定項目）' "ZQXJVB
KPMTRNDGHFLSYCUAEIOZQXJVBWKPMTRNDGHFLSY"
expect_reject '太短 → 拒絕' "ZQXJ"

# ── 訊息不得含 token 的任何片段 ──────────────────────────
# 逐一檢查 token 的每一個長度 4 的子字串都沒有出現在 stderr 裡。
echo "訊息不得洩漏 token"
run_gate "${GOOD}\"x"
leaked=""
i=0
len=${#GOOD}
while [[ $i -le $((len - 4)) ]]; do
  frag="${GOOD:$i:4}"
  if grep -qF "$frag" "$WORK/err"; then
    leaked="$frag"
    break
  fi
  i=$((i + 1))
done
if [[ -z "$leaked" ]]; then
  echo "  ✅ 拒絕訊息裡沒有 token 的任何 4 字元片段"
  PASS=$((PASS + 1))
else
  echo "  ❌ 拒絕訊息裡出現了 token 片段：$leaked"
  FAIL=$((FAIL + 1))
fi

# 同時確認訊息真的有印出「長度」這個允許的資訊，否則等於什麼都沒說
if grep -q '長度' "$WORK/err"; then
  echo "  ✅ 訊息有指出長度（允許的資訊）"
  PASS=$((PASS + 1))
else
  echo "  ❌ 訊息沒有指出長度，排查時等於什麼線索都沒有"
  FAIL=$((FAIL + 1))
fi

echo "通過 $PASS / 失敗 $FAIL"
[[ $FAIL -eq 0 ]]
