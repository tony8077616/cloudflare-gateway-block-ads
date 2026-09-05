#!/bin/bash
# ============================================================
# setup.sh —— 安裝前置檢查（預設）與資源自建（--provision）
#
# 兩種模式，語意刻意分得很開：
#
#   ./setup.sh              等同 --check。**唯讀**：工具檢查、token 唯讀探測、
#                           六處上游預設值健檢、抓一個來源解析印筆數。
#                           對你的 Cloudflare 帳戶零變更、對 GitHub 零變更。
#
#   ./setup.sh --provision  先把 --check 完整跑一遍，全部通過而且你逐項確認之後，
#                           才會建立 D1／KV namespace、寫 GitHub secret 與 variable。
#                           這些動作會產生**會計費**的資源，而且 secret 一旦覆寫，
#                           舊值永遠取不回來。
#
# ── 為什麼這支用 set -Eeuo pipefail，而 sync.sh 刻意不用 -e ──────
# sync.sh 是 best effort 的同步器：單一來源抓失敗、單一批次上傳失敗，都應該印個警告
# 然後把其餘的做完，所以它在檔頭寫了「刻意不用 -e」。setup.sh 的語意正好相反 ——
# 它在幫你建立會計費的資源、寫入無法復原的 secret。任何一步沒成功還硬往下走，
# 結果是一份半套的設定：資源建了一半、secret 只寫了一個，然後把錯誤留到第一次
# 真正同步時才爆出來，那時候要查「到底哪一步沒做」比現在停下來難得多。
# 所以這裡一失敗就停，並在停下來的地方印出「已完成到哪、還有什麼沒做、怎麼回頭」。
#
# ── 憑證處理（硬約束，不是建議）──────────────────────────
#   * API token 絕不寫入任何檔案。.setup.local 只存非機密 ID
#     （帳戶 ID / D1 資料庫 ID / KV namespace ID —— 這些本來就會出現在每一個 API 路徑裡）。
#   * 不提供任何「接受 token」的命令列旗標。互動輸入一律 read -rs（不回顯）。
#   * 每一次 Cloudflare 呼叫的 Authorization 都經 `curl --config -` 由 stdin 餵進去，
#     不會出現在 argv，所以 `ps -eo args` / /proc/*/cmdline 看不到它。
#   * 寫 GitHub secret 時，值一律經 stdin 餵給 gh（`gh secret set NAME` 不加 --body
#     就是從標準輸入讀值）。不用 --body，因為那會把 token 放進 gh 的 argv。
#   * 不用 set -x、不用 curl -v。任何需要顯示 token 的地方只顯示前後 4 碼。
#   * 這支腳本不會寫 $GITHUB_STEP_SUMMARY，也不會在 CI 上執行（見下面的 CI 檢查）。
#
# ── 這支腳本刻意「不做」的事 ──────────────────────────────
#   * 不 source sync.sh。sync.sh 檔尾直接 `main "$@"`、檔頭又有
#     `: "${CF_API_TOKEN:?}"`，source 進來會立刻啟動整套同步（建 7 張表、寫幾十萬列
#     D1、上傳兩百多份清單、啟用一條 action: block 的 Policy）。
#     所以下面自帶一份最小的來源解析，只夠印出筆數。
#   * 不用「建立一個測試用的 Gateway list 再刪掉」去證明 Edit 權限 ——
#     那本身就是一次帳戶變更，跟 --check 的承諾直接衝突。
# ============================================================

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCES_FILE="$SCRIPT_DIR/sources.conf"
LOCAL_CONF="$SCRIPT_DIR/.setup.local"
WRANGLER_TOML="$SCRIPT_DIR/worker/wrangler.toml"

CF_API="https://api.cloudflare.com/client/v4"

# .github/workflows/sync.yml 讀的名字，改這裡就要一起改那邊
SECRET_NAME_TOKEN="CF_API_TOKEN_ADBLOCK"
SECRET_NAME_ACCOUNT="CF_ACCOUNT_ID"
SECRET_NAME_D1="CF_D1_DATABASE_ID"
VAR_NAME_KV="KV_NAMESPACE_ID"

# 本 template 的上游。指到這裡代表使用者還沒 fork 就在跑 --provision，
# 那些 secret 會寫到別人的 repo 上（或直接失敗），一律中止。
TEMPLATE_UPSTREAM="tony8077616/cloudflare-gateway-block-ads"
# 這個 repo 在改成「預設空字串」之前，sync.sh / manage.sh 寫死的作者自己的 namespace。
# 健檢要抓的就是「有人把它留著」。
UPSTREAM_KV_DEFAULT="8b033b48486e45909750175222437f05"
# worker/wrangler.toml 上游的 Worker 名稱。沿用會覆寫掉別人（或你自己另一支）同名的 Worker。
UPSTREAM_WORKER_NAME="adblock-dashboard"

MODE="check"
BLOCKERS=0
WARNINGS=0

CF_TOKEN=""
ACCOUNT_ID="${CF_ACCOUNT_ID:-}"
D1_ID="${D1_DATABASE_ID:-}"
KV_ID="${KV_NAMESPACE_ID:-}"

TOKEN_SOURCE=""          # env / prompt
JSON_TOOL=""             # python3 / jq
PROVISION_CONFIRMED=0    # 只有這個是 1 的時候才允許送出任何寫入型請求
GH_REPO=""               # owner/repo
TMP_DIR=""

# --provision 實際建立了什麼，結尾摘要要逐項列出（含撤銷指令）
CREATED_KIND=()
CREATED_NAME=()
CREATED_ID=()

# ── 輸出小工具 ────────────────────────────────────────────
section() { printf '\n── %s ──────────────────────────────\n' "$1" >&2; }
info()    { printf '   %s\n' "$*" >&2; }
ok()      { printf '✓  %s\n' "$*" >&2; }
soft()    { printf '⚠  %s\n' "$*" >&2; WARNINGS=$((WARNINGS + 1)); }
bad()     { printf '✗  %s\n' "$*" >&2; BLOCKERS=$((BLOCKERS + 1)); }
undet()   { printf '?  %s\n' "$*" >&2; BLOCKERS=$((BLOCKERS + 1)); }
# 刻意的中止。先解掉 ERR trap：bash 會把 `exit 1` 本身也算成一次失敗，
# 不解掉的話，使用者在看到明確原因之後還會再收到一段「第幾行失敗」的雜訊。
die()     { printf '\n✗  中止：%s\n' "$*" >&2; trap - ERR; exit 1; }

cleanup() {
  local code=$?
  # token 只活在這個行程的記憶體裡，這裡順手清掉（行程結束本來也就沒了，
  # 但萬一之後有人在 EXIT 之後加東西，這一行讓意圖是明確的）。
  unset CF_TOKEN
  [[ -n "$TMP_DIR" && -d "$TMP_DIR" ]] && rm -rf "$TMP_DIR"
  return $code
}
trap cleanup EXIT

on_error() {
  local code=$?
  printf '\n' >&2
  printf '✗  第 %s 行失敗（exit %s），已停止。\n' "${BASH_LINENO[0]}" "$code" >&2
  printf '   這支腳本刻意一失敗就停，不會半套地繼續往下做。\n' >&2
  print_progress_on_abort
  return $code
}
trap on_error ERR

print_progress_on_abort() {
  printf '\n   目前狀態：\n' >&2
  if [[ ${#CREATED_ID[@]} -eq 0 ]]; then
    printf '     已建立的資源：無（沒有任何東西需要你回頭清理）\n' >&2
  else
    printf '     已建立的資源（**不會自動刪除**，要清理請照下面的指令手動做）：\n' >&2
    print_created_resources
  fi
  printf '     還沒做的：從上面失敗的那一步開始，全部都還沒做。\n' >&2
  printf '     怎麼回頭：先修掉上面那個錯誤，然後重跑 ./setup.sh（唯讀）確認全綠，\n' >&2
  printf '               再決定要不要重跑 ./setup.sh --provision。\n' >&2
  printf '               重跑 --provision 預設會「再建立一份新的」資源，不會沿用上面那些，\n' >&2
  printf '               除非你在提示時明確選擇沿用並貼上 ID。\n' >&2
}

mask_token() {
  # 只顯示前後各 4 碼。這是這支腳本裡唯一會把 token 的任何一部分印出來的地方。
  local n=${#CF_TOKEN}
  if [[ "$n" -lt 12 ]]; then
    printf '(太短，不顯示)'
  else
    printf '%s…%s（共 %s 碼）' "${CF_TOKEN:0:4}" "${CF_TOKEN: -4}" "$n"
  fi
}

confirm() {
  # $1 = 提示文字。必須輸入完整的 yes 才算數（y 不算）——
  # 這些確認後面接的是會計費／不可復原的動作，不該是一個鍵就過。
  local answer=""
  printf '\n?  %s\n   輸入 yes 繼續，其他任何輸入都會中止：' "$1" >&2
  if ! [[ -t 0 ]]; then
    printf '\n' >&2
    die "需要互動確認，但標準輸入不是終端機。請在互動的終端機裡執行。"
  fi
  read -r answer
  [[ "$answer" == "yes" ]]
}

# ── JSON 讀取 ─────────────────────────────────────────────
# 只讀不寫，而且只需要四種操作。優先用 python3（標準函式庫就有嚴格的 JSON parser），
# 沒有的話退回 jq。刻意不用 grep/sed 硬拆 JSON —— 判定層要靠 success 布林，
# 用字串比對去猜一個布林值，錯的時候會錯成「以為通過了」。
json_py() {
  # $1 op, $2 檔案, $3 參數
  python3 -c '
import json, sys
op, path = sys.argv[1], sys.argv[2]
arg = sys.argv[3] if len(sys.argv) > 3 else ""
try:
    with open(path, "rb") as f:
        data = json.load(f)
except Exception:
    sys.exit(3)
def walk(d, dotted):
    cur = d
    for part in dotted.split("."):
        if isinstance(cur, dict) and part in cur:
            cur = cur[part]
        else:
            return None
    return cur
if op == "success":
    v = data.get("success") if isinstance(data, dict) else None
    if v is True:
        print("true")
    elif v is False:
        print("false")
    else:
        sys.exit(4)
elif op == "str":
    v = walk(data, arg)
    if v is None or isinstance(v, (dict, list)):
        sys.exit(4)
    print(v if not isinstance(v, bool) else ("true" if v else "false"))
elif op == "count":
    v = walk(data, arg)
    if not isinstance(v, list):
        sys.exit(4)
    print(len(v))
elif op == "field_list":
    dotted, field = arg.split("::", 1)
    v = walk(data, dotted)
    if not isinstance(v, list):
        sys.exit(4)
    for item in v:
        if isinstance(item, dict):
            print(item.get(field, ""))
elif op == "errors":
    v = data.get("errors") if isinstance(data, dict) else None
    if not isinstance(v, list):
        sys.exit(4)
    for e in v:
        if isinstance(e, dict):
            print("%s\t%s" % (e.get("code", ""), e.get("message", "")))
else:
    sys.exit(5)
' "$@"
}

json_jq() {
  local op="$1" path="$2" arg="${3:-}"
  case "$op" in
    success)    jq -er 'if .success == true then "true" elif .success == false then "false" else error end' "$path" ;;
    str)        jq -er --arg p "$arg" 'getpath($p | split(".")) | if . == null or (type|test("object|array")) then error else (.|tostring) end' "$path" ;;
    count)      jq -er --arg p "$arg" 'getpath($p | split(".")) | if type == "array" then length else error end' "$path" ;;
    field_list) jq -er --arg p "${arg%%::*}" --arg f "${arg##*::}" 'getpath($p | split(".")) | if type == "array" then (.[] | (.[$f] // "")) else error end' "$path" ;;
    errors)     jq -er '.errors | if type == "array" then (.[] | "\(.code // "")\t\(.message // "")") else error end' "$path" ;;
    *) return 5 ;;
  esac
}

json() {
  case "$JSON_TOOL" in
    python3) json_py "$@" ;;
    jq)      json_jq "$@" ;;
    *)       return 9 ;;
  esac
}

# ── Cloudflare API 呼叫 ───────────────────────────────────
# Authorization 一律經 --config - 由 stdin 進去。printf 是 bash 內建指令，
# 不會產生新行程，所以 token 從頭到尾沒有進過任何 argv。
#
# curl 旗標：
#   -q                     不讀 ~/.curlrc（別人的設定檔不能替我們加 proxy 或改輸出位置）
#   --proto '=https'       只准 https
#   --proto-redir '=https' 轉址也只准 https
#   --                     結束旗標解析（URL 由本檔組出來，但保持同一個習慣）
CF_HTTP_CODE=""
CF_RESP=""

cf_config_stdin() {
  # 這個函式的輸出只會接到 curl 的 stdin，絕不落地成檔案。
  printf 'header = "Authorization: Bearer %s"\n' "$CF_TOKEN"
}

cf_get() {
  # $1 = 路徑（含 query string）。回應寫進 $CF_RESP，HTTP 狀態碼寫進 $CF_HTTP_CODE。
  local path="$1"
  CF_RESP="$TMP_DIR/resp.json"
  : > "$CF_RESP"
  CF_HTTP_CODE="$(
    cf_config_stdin | curl -q -sS --max-time 30 \
      --proto '=https' --proto-redir '=https' \
      --config - -o "$CF_RESP" -w '%{http_code}' -- "$CF_API$path"
  )" || CF_HTTP_CODE="000"
  [[ -n "$CF_HTTP_CODE" ]] || CF_HTTP_CODE="000"
}

cf_post() {
  # $1 = 路徑, $2 = 內含 JSON 的檔案（那個檔案裡沒有 token，只有資源名稱）。
  # 這裡有一道硬閘門：--check 模式下，任何寫入型請求都是 bug，不是「順手做一下」。
  local path="$1" body_file="$2"
  if [[ "$MODE" != "provision" || "$PROVISION_CONFIRMED" != "1" ]]; then
    die "內部錯誤：在非 provision 模式（或尚未取得確認）下嘗試送出寫入型請求 $path。這是 bug，請回報。"
  fi
  CF_RESP="$TMP_DIR/resp.json"
  : > "$CF_RESP"
  CF_HTTP_CODE="$(
    cf_config_stdin | curl -q -sS --max-time 60 -X POST \
      --proto '=https' --proto-redir '=https' \
      -H 'Content-Type: application/json' \
      --data-binary "@$body_file" \
      --config - -o "$CF_RESP" -w '%{http_code}' -- "$CF_API$path"
  )" || CF_HTTP_CODE="000"
  [[ -n "$CF_HTTP_CODE" ]] || CF_HTTP_CODE="000"
}

cf_errors_brief() {
  # 只擷取 .errors[].code 與 .errors[].message。刻意不整包回顯 API 回應 ——
  # 回應裡可能夾帶帳戶結構之類的東西，而且整包貼出來對排查沒有比較有用。
  local line
  while IFS=$'\t' read -r code message; do
    [[ -n "$code$message" ]] || continue
    info "API 回報：code=$code message=$message"
  done < <(json errors "$CF_RESP" 2>/dev/null || true)
}

# 判定層：只看 HTTP 狀態碼 + success 布林。
# 錯誤碼（9109 / 10000 …）只在提示層用，用來幫忙分辨「範圍不對」跟「少勾權限」，
# 永遠不參與「通過與否」的判定。對不上的錯誤碼一律降級為「無法判定」。
#
# 回傳：0 = 可存取, 1 = 不可存取, 2 = 無法判定
cf_classify() {
  local body_success=""
  body_success="$(json success "$CF_RESP" 2>/dev/null || true)"
  case "$CF_HTTP_CODE" in
    200)
      [[ "$body_success" == "true" ]] && return 0
      # 200 但 success 不是布林 true —— 可能是被中間設備改寫過的回應。不當成通過。
      return 2 ;;
    401|403)
      [[ "$body_success" == "false" ]] && return 1
      return 2 ;;
    404)
      # 資源不存在跟沒權限在 Cloudflare 上會長得很像，交給呼叫端自己判斷語意
      [[ "$body_success" == "false" ]] && return 1
      return 2 ;;
    *)
      return 2 ;;
  esac
}

cf_denial_hint() {
  # 提示層。只在「已經判定為不可存取」之後才呼叫，用來多講一句可能的原因。
  local codes=""
  codes="$(json errors "$CF_RESP" 2>/dev/null | cut -f1 | tr '\n' ' ' || true)"
  case " $codes " in
    *" 9109 "*) info "提示：錯誤碼 9109 通常代表 token 的**範圍**沒有涵蓋這個帳戶／資源（scope 選錯帳戶）。" ;;
    *" 10000 "*) info "提示：錯誤碼 10000 通常代表 token 本身有效，但**少勾了這一項權限**。" ;;
    *)
      info "提示：回應的錯誤碼（${codes:-無}）不在已知對照表裡，所以「為什麼被拒」這一項是**無法判定**，"
      info "      不要把它當成「只是少勾一個權限」就略過。" ;;
  esac
}

# ── 0. 執行環境的前置閘門 ─────────────────────────────────
refuse_ci() {
  # 這支腳本在 CI 上跑沒有任何好處，只有壞處：
  #   * 它的設計前提是「有人坐在終端機前面逐項確認」，CI 上沒有人可以確認；
  #   * --provision 會建立會計費的資源、覆寫不可復原的 secret，那不該由一次
  #     誰都能觸發的 workflow run 決定；
  #   * token 要用 read -rs 互動輸入，CI 上只能從環境變數來，等於把憑證處理的
  #     假設整個換掉。
  # 所以偵測到 CI 就直接拒絕，而不是「降級成非互動模式」。
  local reason=""
  case "${CI:-}" in
    ""|"0"|"false") : ;;
    *) reason="環境變數 CI=${CI}" ;;
  esac
  if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
    reason="${reason:+$reason，}環境變數 GITHUB_ACTIONS=${GITHUB_ACTIONS}"
  fi
  if [[ -n "$reason" ]]; then
    printf '✗  偵測到 CI 環境（%s），拒絕執行。\n' "$reason" >&2
    printf '   理由：\n' >&2
    printf '     1. 這支腳本每一個有後果的步驟都要人在終端機前面打 yes 確認，CI 上沒有人可以確認。\n' >&2
    printf '     2. --provision 會建立會計費的 Cloudflare 資源、覆寫無法復原的 GitHub secret，\n' >&2
    printf '        那不該由一次 workflow run 決定。\n' >&2
    printf '     3. token 的取得方式是互動輸入（read -rs），CI 上只能改成從環境變數讀，\n' >&2
    printf '        等於把整套憑證處理的假設換掉。\n' >&2
    printf '   要在 CI 上跑同步請直接用 .github/workflows/sync.yml；setup.sh 只在你自己的機器上跑一次。\n' >&2
    trap - ERR
    exit 1
  fi
}

usage() {
  cat >&2 <<'USAGE'
用法：
  ./setup.sh                安裝前置檢查（唯讀）。對 Cloudflare 帳戶與 GitHub 零變更。
  ./setup.sh --check        同上，把預設模式寫出來而已。
  ./setup.sh --provision    先跑完整的檢查，全過且逐項確認後，才建立 D1／KV、寫 GitHub secret。
  ./setup.sh --help         這段說明。

關於 API token：
  這支腳本**沒有**任何接受 token 的命令列旗標，也不會把 token 寫進任何檔案。
  執行到需要的時候會用不回顯的方式請你貼上（read -rs）。
  如果你想從密碼管理器取值，請先在互動的 shell 裡 export 好再執行本腳本；
  注意「在指令列同一行前面臨時指定變數」的寫法會連同 token 一起被寫進 shell history。

要申請什麼樣的 token：
  Cloudflare Dashboard → My Profile → API Tokens → Create Token → Custom token
  權限（全部選 Account 範圍，**只挑你自己那一個帳戶**，不要選 All accounts）：
    Account │ Zero Trust                    │ Edit
    Account │ Account Firewall Access Rules │ Read      （Intel 網域分類查詢要用）
    Account │ D1                            │ Edit
    Account │ Workers KV Storage            │ Edit
  不要用 Global API Key。它等於你整個帳戶的萬能鑰匙，而且沒有辦法限制範圍。
USAGE
}

parse_args() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --check)     MODE="check" ;;
      --provision) MODE="provision" ;;
      -h|--help)   usage; exit 0 ;;
      # 明確地把「用旗標傳 token」這件事擋掉並解釋原因，而不是丟一句 unknown option。
      --token*|--api-token*|--cf-token*|-t)
        printf '✗  這支腳本刻意不提供任何接受 token 的旗標。\n' >&2
        printf '   命令列引數會出現在 ps 的輸出裡，也會被寫進 shell history。\n' >&2
        printf '   請直接執行 ./setup.sh，需要的時候會用不回顯的方式請你貼上。\n' >&2
        trap - ERR
        exit 1 ;;
      *)
        printf '✗  不認得的參數：%s\n\n' "$arg" >&2
        usage
        trap - ERR
        exit 1 ;;
    esac
  done
}

# ── 1. 工具檢查 ───────────────────────────────────────────
check_tools() {
  section "1. 工具檢查"
  local missing_hard=0

  if command -v curl >/dev/null 2>&1; then
    ok "curl —— $(curl --version 2>/dev/null | head -1 | cut -d' ' -f1-2)"
  else
    bad "curl 沒安裝。setup.sh 與 sync.sh 都靠它，沒有它什麼都做不了。"
    missing_hard=1
  fi

  if command -v python3 >/dev/null 2>&1; then
    JSON_TOOL="python3"
    ok "python3 —— 用它解析 API 回應的 JSON"
  elif command -v jq >/dev/null 2>&1; then
    JSON_TOOL="jq"
    ok "jq —— 用它解析 API 回應的 JSON（沒找到 python3，退回 jq）"
  else
    bad "python3 與 jq 都沒有。至少要有一個才能解析 Cloudflare 的 JSON 回應。"
    missing_hard=1
  fi

  if command -v jq >/dev/null 2>&1; then
    ok "jq —— $(jq --version 2>/dev/null)（sync.sh / manage.sh 需要它）"
  else
    bad "jq 沒安裝。setup.sh 本身可以不用，但 sync.sh 與 manage.sh 從頭到尾都在用 jq，沒有它同步跑不起來。"
  fi

  local t
  for t in git gzip sha256sum; do
    if command -v "$t" >/dev/null 2>&1; then
      ok "$t"
    else
      bad "$t 沒安裝（sync.sh 需要）。"
    fi
  done

  if command -v gh >/dev/null 2>&1; then
    ok "gh —— $(gh --version 2>/dev/null | head -1)"
  else
    if [[ "$MODE" == "provision" ]]; then
      bad "gh（GitHub CLI）沒安裝。--provision 要靠它寫 repo secret 與 variable。"
    else
      soft "gh（GitHub CLI）沒安裝。--check 用不到；--provision 需要它來寫 GitHub secret。"
    fi
  fi

  [[ "$missing_hard" == "0" ]] || die "缺少 setup.sh 自己就跑不下去的工具（見上），請先安裝。"
}

# ── 2. 目標 repo ──────────────────────────────────────────
detect_repo() {
  section "2. 目標 GitHub repo"
  local url=""
  url="$(git -C "$SCRIPT_DIR" remote get-url origin 2>/dev/null || true)"
  if [[ -z "$url" ]]; then
    GH_REPO=""
    soft "這個目錄沒有 git remote origin，無法推導要寫哪個 repo 的 secret。"
    info "--provision 會退化成「印出你要手動設定的 secret 名稱」，不會嘗試自己寫。"
    return 0
  fi
  info "git remote origin：$url"

  # 支援 https://github.com/owner/repo(.git) 與 git@github.com:owner/repo(.git)
  local path=""
  case "$url" in
    https://github.com/*) path="${url#https://github.com/}" ;;
    http://github.com/*)  path="${url#http://github.com/}" ;;
    git@github.com:*)     path="${url#git@github.com:}" ;;
    ssh://git@github.com/*) path="${url#ssh://git@github.com/}" ;;
    *)
      GH_REPO=""
      soft "remote origin 不是 github.com 的位址，無法可靠推導 owner/repo。"
      info "--provision 會退化成「印出你要手動設定的 secret 名稱」，不會亂猜。"
      return 0 ;;
  esac
  path="${path%.git}"
  path="${path%/}"
  if [[ ! "$path" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]]; then
    GH_REPO=""
    soft "從 remote 推導出來的 '$path' 不像 owner/repo，不採用。"
    return 0
  fi
  GH_REPO="$path"
  ok "推導出的目標 repo：$GH_REPO"

  if [[ "$GH_REPO" == "$TEMPLATE_UPSTREAM" ]]; then
    if [[ "$MODE" == "provision" ]]; then
      bad "這個 clone 指向的是本 template 的上游 $TEMPLATE_UPSTREAM。"
      info "你要先在 GitHub 上按 Use this template（或 fork）建立自己的 repo，把 origin 換成它，再跑 --provision。"
      info "直接對上游寫 secret 不是你想做的事（多半也會因為沒有權限而失敗）。"
    else
      soft "這個 clone 指向本 template 的上游 $TEMPLATE_UPSTREAM。--check 沒問題，但 --provision 會拒絕執行。"
    fi
  fi
}

# ── 3. 六處上游預設值健檢 ─────────────────────────────────
# 這個 template 有六個地方原本寫著「作者自己帳戶的識別碼」。fork 的人沒換掉的話，
# 症狀都不是明顯的錯誤訊息，而是「悄悄地不對」：
#   * 沿用作者的 KV namespace → 每次讀 404，靜靜退回 D1 全表掃描（慢，但看起來是好的）
#   * 沿用作者的 Worker 名稱   → wrangler deploy 會直接覆寫同名 Worker，沒有確認提示
# 所以這裡不管有沒有問題都把六項全部列出來，讓「我檢查過了」是看得見的。
toml_value() {
  # $1 = 檔案, $2 = 鍵的 ERE。取 `key = "value"` 裡的 value；找不到就輸出空字串。
  [[ -f "$1" ]] || return 0
  grep -E "^[[:space:]]*$2[[:space:]]*=" "$1" 2>/dev/null \
    | head -1 \
    | sed -E 's/^[^=]*=[[:space:]]*"?([^"]*)"?[[:space:]]*$/\1/' \
    | tr -d '\r'
}

check_one_default() {
  # $1 = 顯示名稱, $2 = 狀態(ok|todo|upstream|missing), $3 = 補充說明
  case "$2" in
    ok)       ok       "$1 —— $3" ;;
    todo)     soft     "$1 —— $3" ;;
    upstream) bad      "$1 —— $3" ;;
    missing)  soft     "$1 —— $3" ;;
  esac
}

check_upstream_defaults() {
  section "3. 六處上游預設值健檢"
  local v

  # (1)(2) sync.sh / manage.sh 的 KV_NAMESPACE_ID 預設值
  local f
  for f in sync.sh manage.sh; do
    if [[ ! -f "$SCRIPT_DIR/$f" ]]; then
      check_one_default "$f 的 KV_NAMESPACE_ID 預設值" missing "找不到 $f"
    elif grep -q "$UPSTREAM_KV_DEFAULT" "$SCRIPT_DIR/$f" 2>/dev/null; then
      check_one_default "$f 的 KV_NAMESPACE_ID 預設值" upstream \
        "還是上游作者的 namespace（$UPSTREAM_KV_DEFAULT）。拿別人的 namespace 配你的 token，每次讀都會 404，然後靜靜退回讀 D1 全表。必須改掉。"
    else
      check_one_default "$f 的 KV_NAMESPACE_ID 預設值" ok \
        "已經是空字串。沒設定 KV_NAMESPACE_ID 就是不用快取、直接讀 D1：結果正確，只是比較慢。"
    fi
  done

  # (3) worker/wrangler.toml 的 Worker 名稱
  if [[ ! -f "$WRANGLER_TOML" ]]; then
    check_one_default "worker/wrangler.toml 的 name（Worker 名稱）" missing "沒有 worker/wrangler.toml（沒要部署儀表板的話可以不管）"
    check_one_default "worker/wrangler.toml 的 CF_ACCOUNT_ID" missing "同上"
    check_one_default "worker/wrangler.toml 的 database_id（D1）" missing "同上"
    check_one_default "worker/wrangler.toml 的 id（KV namespace）" missing "同上"
    return 0
  fi

  v="$(toml_value "$WRANGLER_TOML" 'name')"
  if [[ "$v" == "$UPSTREAM_WORKER_NAME" ]]; then
    check_one_default "worker/wrangler.toml 的 name（Worker 名稱）" todo \
      "還是上游的 '$UPSTREAM_WORKER_NAME'。wrangler deploy 會**直接覆寫同名的既有 Worker，沒有任何確認提示**，部署前請先改成你自己的名字。"
  else
    check_one_default "worker/wrangler.toml 的 name（Worker 名稱）" ok "已改成 '$v'"
  fi

  # (4)(5)(6) wrangler.toml 裡三個資源識別碼
  local key label
  for key in 'CF_ACCOUNT_ID:CF_ACCOUNT_ID' 'database_id:database_id（D1）' 'id:id（KV namespace）'; do
    label="${key#*:}"
    v="$(toml_value "$WRANGLER_TOML" "${key%%:*}")"
    if [[ -z "$v" ]]; then
      check_one_default "worker/wrangler.toml 的 $label" missing "檔案裡找不到這個鍵"
    elif [[ "$v" == *"$UPSTREAM_KV_DEFAULT"* ]]; then
      check_one_default "worker/wrangler.toml 的 $label" upstream "還是上游作者的識別碼（$v），必須換成你自己的。"
    elif [[ "$v" =~ ^[0-9a-f]{32}$ ]]; then
      check_one_default "worker/wrangler.toml 的 $label" ok "已填入識別碼 $v"
    else
      check_one_default "worker/wrangler.toml 的 $label" todo "還是待填的佔位字串（'$v'）。只影響 Worker 儀表板，不影響同步本身。"
    fi
  done
}

# ── 4. 取得 API token ─────────────────────────────────────
acquire_token() {
  section "4. Cloudflare API token"

  # Global API Key 的形式（X-Auth-Email + X-Auth-Key）一律拒絕：
  # 它等於整個帳戶的萬能鑰匙，沒有辦法限制範圍，也沒有辦法只給這個專案要的四項權限。
  # 這支腳本從頭到尾不會組出那兩個標頭；這裡再擋一次「使用者以為可以用」的入口。
  local k
  for k in CF_API_KEY CF_API_EMAIL CLOUDFLARE_API_KEY CLOUDFLARE_EMAIL; do
    if [[ -n "${!k:-}" ]]; then
      bad "偵測到環境變數 $k —— 那是 Global API Key（X-Auth-Email + X-Auth-Key）的用法。"
      info "本專案不接受 Global API Key：它是整個帳戶的萬能鑰匙，範圍無法限制，"
      info "外洩的後果跟「密碼被偷」一樣大。請改申請 account-scoped 的 API Token（./setup.sh --help 有權限清單）。"
      info "這支腳本不會使用 $k，也不會把它送出去。"
    fi
  done

  if [[ -n "${CF_API_TOKEN:-}" ]]; then
    CF_TOKEN="${CF_API_TOKEN}"
    TOKEN_SOURCE="env"
    info "沿用環境中已有的 CF_API_TOKEN。"
    info "提醒：如果這個值是在指令列同一行的前面臨時指定的，那一整行（連同 token）"
    info "      會被寫進 shell history。比較安全的做法是在互動的 shell 裡先 export，"
    info "      或什麼都不設，讓下面的提示用不回顯的方式請你貼上。"
  else
    if ! [[ -t 0 ]]; then
      die "需要互動輸入 API token，但標準輸入不是終端機。請在互動的終端機裡執行 ./setup.sh。"
    fi
    TOKEN_SOURCE="prompt"
    printf '\n   請貼上 Cloudflare API Token（不會回顯、不會寫進任何檔案、不會進 history）：' >&2
    read -rs CF_TOKEN
    printf '\n' >&2
  fi

  [[ -n "$CF_TOKEN" ]] || die "沒有拿到 token。"

  # 這個值等一下會被放進 curl 的設定檔內容（由 stdin 餵）。設定檔的語法是
  #   header = "Authorization: Bearer <值>"
  # 所以值裡面如果有引號、反斜線、換行，就能跳出這個字串去多加一個設定項目。
  # Cloudflare 的 API token 只會用 [A-Za-z0-9_-]，這裡直接把其他東西擋掉。
  if [[ ! "$CF_TOKEN" =~ ^[A-Za-z0-9_-]+$ ]]; then
    die "這個 token 含有預期外的字元。Cloudflare 的 API token 只會由英數字、底線、連字號組成。請確認你貼上的內容沒有多帶空白、引號或換行。"
  fi
  if [[ "${#CF_TOKEN}" -lt 20 ]]; then
    die "這個 token 只有 ${#CF_TOKEN} 碼，短得不像 Cloudflare 的 API token（一般是 40 碼）。"
  fi
  # Global API Key 是 37 碼的十六進位字串，跟 API Token 長得不一樣，先擋掉。
  if [[ "$CF_TOKEN" =~ ^[0-9a-f]{32,37}$ ]]; then
    die "這串看起來是 Global API Key（純十六進位、37 碼），不是 API Token。本專案不接受 Global API Key，請改申請 account-scoped 的 API Token（./setup.sh --help 有權限清單）。"
  fi

  info "已取得 token：$(mask_token)（來源：$TOKEN_SOURCE）"
  info "接下來每一次呼叫，Authorization 都會經 curl --config - 由標準輸入餵進去，不會出現在 ps 看得到的地方。"
}

# ── 5. Token 唯讀探測 ─────────────────────────────────────
# 重要且反覆強調：以下每一項都是唯讀（GET）探測。
# 唯讀探測能回答的只有「這個 token 對這個 scope 讀得到東西嗎」，
# 回答不了「它寫得進去嗎」。所以綠燈的措辭一律是「可存取」，不會是「權限正確」。
probe_scope() {
  # $1 = 顯示名稱, $2 = 路徑
  cf_get "$2"
  local rc=0
  cf_classify || rc=$?
  case "$rc" in
    0) ok "$1 —— Token 對此 scope 可存取（HTTP $CF_HTTP_CODE、success=true）" ;;
    1) bad "$1 —— Token 對此 scope 不可存取（HTTP $CF_HTTP_CODE、success=false）"
       cf_denial_hint ;;
    *) undet "$1 —— **無法判定**（HTTP $CF_HTTP_CODE，回應的 success 欄位不是可用的布林值）"
       info "無法判定不等於通過，也不等於失敗。在弄清楚之前不要往下做。"
       cf_errors_brief ;;
  esac
}

probe_token() {
  section "5. Token 唯讀探測（全部是 GET，對帳戶零變更）"

  # (a) token 本身有效嗎
  cf_get "/user/tokens/verify"
  local rc=0
  cf_classify || rc=$?
  case "$rc" in
    0) ok "Token 驗證通過（HTTP 200、success=true），而且它是一個 API Token 而不是 Global API Key。" ;;
    1) bad "Token 驗證失敗（HTTP $CF_HTTP_CODE、success=false）—— 這個 token 無效、已過期或已被撤銷。"
       cf_denial_hint
       die "token 連自我驗證都過不了，後面的探測沒有意義。" ;;
    *) undet "Token 驗證**無法判定**（HTTP $CF_HTTP_CODE）。"
       cf_errors_brief
       die "連不上 Cloudflare 或回應不是預期格式，先確認網路再重試。" ;;
  esac

  # (b) 過度權限：這個 token 讀得到「使用者本人」的資料嗎？
  #     account-scoped 的 token 應該讀不到 /user。讀得到代表它是 user-scoped
  #     或 Global 等級，範圍遠大於這個專案需要的四項權限。
  cf_get "/user"
  rc=0
  cf_classify || rc=$?
  case "$rc" in
    0) bad "過度權限：這個憑證讀得到 GET /user（你的個人帳號資料）。"
       info "這個專案只需要「單一 account 範圍」的四項權限。讀得到 /user 代表它是 user-scoped"
       info "或 Global 等級的憑證 —— 一旦外洩，影響範圍遠大於這個專案。"
       info "請重新申請一個 account-scoped 的 API Token（./setup.sh --help 有完整權限清單），"
       info "並把現在這一個撤銷掉。" ;;
    1) ok "範圍檢查：這個 token 讀不到 GET /user，符合「account-scoped」的預期。" ;;
    *) undet "範圍檢查**無法判定**（GET /user 回應 HTTP $CF_HTTP_CODE）。"
       info "在確認它不是 user-scoped 憑證之前，不要當成通過。"
       cf_errors_brief ;;
  esac

  # (c) 這個 token 看得到幾個帳戶？看得到超過一個就是範圍開太大。
  cf_get "/accounts"
  rc=0
  cf_classify || rc=$?
  if [[ "$rc" == "0" ]]; then
    local n_acc=0
    n_acc="$(json count "$CF_RESP" result 2>/dev/null || echo 0)"
    if [[ "$n_acc" -gt 1 ]]; then
      soft "過度權限：這個 token 看得到 $n_acc 個帳戶。"
      info "這個專案只需要對「一個」帳戶的權限。建立 token 時 Account Resources 請只挑目標帳戶，"
      info "不要選 All accounts —— 否則 token 外洩會一次波及全部 $n_acc 個帳戶。"
      info "可見的帳戶："
      local id name
      while read -r id; do [[ -n "$id" ]] && info "  - $id"; done < <(json field_list "$CF_RESP" 'result::id' 2>/dev/null || true)
    elif [[ "$n_acc" -eq 1 ]]; then
      ok "範圍檢查：這個 token 只看得到 1 個帳戶，符合預期。"
    else
      bad "這個 token 看不到任何帳戶，後面所有 account 範圍的探測都會失敗。"
    fi
    if [[ -z "$ACCOUNT_ID" && "$n_acc" -ge 1 ]]; then
      ACCOUNT_ID="$(json field_list "$CF_RESP" 'result::id' 2>/dev/null | head -1 || true)"
      [[ -n "$ACCOUNT_ID" ]] && info "採用帳戶 ID：$ACCOUNT_ID（來自 GET /accounts 的第一筆）"
    fi
  else
    soft "讀不到帳戶清單（HTTP $CF_HTTP_CODE），無法自動判斷帳戶數量與帳戶 ID。"
    [[ "$rc" == "1" ]] && cf_denial_hint
  fi

  if [[ -z "$ACCOUNT_ID" ]]; then
    bad "沒有帳戶 ID，account 範圍的 scope 探測全部跳過。"
    info "請先 export CF_ACCOUNT_ID=<你的帳戶 ID>（這不是機密，它會出現在每一個 API 路徑裡）再重跑。"
    return 0
  fi
  info "以下探測針對帳戶 $ACCOUNT_ID"

  probe_scope "Zero Trust / Gateway 清單（Gateway Lists）" "/accounts/$ACCOUNT_ID/gateway/lists"
  probe_scope "Zero Trust / Gateway 規則（Policies）"      "/accounts/$ACCOUNT_ID/gateway/rules"
  probe_scope "D1 資料庫清單"                              "/accounts/$ACCOUNT_ID/d1/database"
  probe_scope "Workers KV namespace 清單"                  "/accounts/$ACCOUNT_ID/storage/kv/namespaces"
  probe_scope "Intel 網域分類查詢"                          "/accounts/$ACCOUNT_ID/intel/domain?domain=example.com"

  # 已經指定的資源 ID 存不存在（也是唯讀）
  if [[ -n "$D1_ID" ]]; then
    probe_scope "指定的 D1 資料庫（$D1_ID）" "/accounts/$ACCOUNT_ID/d1/database/$D1_ID"
  else
    info "尚未指定 D1_DATABASE_ID。--provision 可以幫你建立一個；同步一定要有它。"
  fi
  if [[ -n "$KV_ID" ]]; then
    probe_scope "指定的 KV namespace（$KV_ID）" "/accounts/$ACCOUNT_ID/storage/kv/namespaces/$KV_ID"
  else
    info "尚未指定 KV_NAMESPACE_ID。這一項是選用的：沒有它就是不用讀取側快取、每次直接讀 D1，"
    info "結果完全正確，只是每次同步要多掃約 46 萬列。"
  fi

  # 這一段是這個小節的重點，不是註腳。
  printf '\n' >&2
  info "── 關於「權限」這件事，把話講清楚 ──────────────"
  info "上面每一項都是唯讀（GET）探測。唯讀探測能證明的只有一件事："
  info "「Token 對這個 scope 讀得到東西」。"
  info "它**證明不了 Edit（寫入）權限**。這個專案真正要用到的寫入動作是："
  info "  * 建立／更新 Gateway Lists（Zero Trust: Edit）"
  info "  * 寫入 D1（D1: Edit）"
  info "  * 寫入 KV 快照（Workers KV Storage: Edit）"
  info "這三項的 Edit 權限，只有在**第一次真正執行同步**的時候才會被證明。"
  info "本腳本刻意不用「建立一個測試用的清單再刪掉」去試寫 —— 那本身就是一次帳戶變更，"
  info "跟「--check 對你的帳戶零變更」這個承諾直接衝突。"
}

# ── 6. 抓一個來源、解析、印筆數 ───────────────────────────
# 自帶最小解析：不 source sync.sh（它檔尾直接 main "$@"，source 進來會啟動整套同步）。
# 這裡只驗證「抓得到、解析得出東西」，所以只做 adblock/domains/hosts 三種格式的骨架，
# 權威的解析邏輯仍然在 sync.sh 裡。
SETUP_DOMAIN_REGEX='^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)+$'
SETUP_IPV4_REGEX='^([0-9]{1,3}\.){3}[0-9]{1,3}$'

setup_parse() {
  # $1 = format。吃 stdin，吐網域到 stdout。
  case "$1" in
    domains)
      grep -vE '^[[:space:]]*(#|!|$)' | sed -E 's/^\*\.//' ;;
    adblock)
      grep -E '^\|\|[a-zA-Z0-9.*_-]+\^(\$[a-zA-Z0-9_,.=~|-]*)?$' \
        | grep -v '^@@' | grep -vE '\$[a-zA-Z0-9_,.=~|-]*=' \
        | sed -E 's/^\|\|([a-zA-Z0-9.*_-]+)\^.*/\1/' | sed -E 's/^\*\.//' ;;
    hosts)
      grep -E '^(0\.0\.0\.0|127\.0\.0\.1|::1|::)[[:space:]]+' | awk '{print $2}' ;;
    *) return 1 ;;
  esac | tr 'A-Z' 'a-z' | grep -E "$SETUP_DOMAIN_REGEX" | grep -vE "$SETUP_IPV4_REGEX"
}

check_one_source() {
  section "6. 抓一個來源、解析、印筆數"
  if [[ ! -f "$SOURCES_FILE" ]]; then
    bad "找不到 $SOURCES_FILE"
    return 0
  fi

  local line name url format
  line="$(grep -vE '^[[:space:]]*(#|$)' "$SOURCES_FILE" | head -1 || true)"
  if [[ -z "$line" ]]; then
    bad "sources.conf 裡沒有任何來源。"
    return 0
  fi
  IFS='|' read -r name url format <<< "$line"
  name="$(printf '%s' "$name" | xargs)"
  url="$(printf '%s' "$url" | xargs)"
  format="$(printf '%s' "$format" | xargs)"
  info "取 sources.conf 的第一個來源：$name（$format）"
  info "$url"

  local out="$TMP_DIR/one_source.txt" code=""
  # 跟 sync.sh 的 curl_source 同一套硬化旗標：-q 不讀 ~/.curlrc、只准 https、
  # -- 結束旗標解析（所以像 -o/tmp/pwned 這種值會被當成網址而不是旗標）。
  code="$(curl -q -sSL --retry 2 --retry-all-errors --max-time 60 \
    --proto '=https' --proto-redir '=https' \
    -A "cloudflare-gateway-block-ads-sync/1.0 (setup check)" \
    -o "$out" -w '%{http_code}' -- "$url" 2>/dev/null)" || code="000"

  if [[ "$code" != "200" ]]; then
    soft "抓取失敗（HTTP $code）。單一來源抓不到不會擋住同步（sync.sh 是 best effort，會略過並記警告），但這代表你的網路或這個來源現在有問題。"
    return 0
  fi

  local n=0
  n="$(setup_parse "$format" < "$out" | sort -u | wc -l | xargs)" || n=0
  if [[ "$n" -gt 0 ]]; then
    ok "抓取並解析成功：$name 解析出 $n 筆去重後的網域。"
    info "（這只是一個來源。完整同步會處理 sources.conf 裡全部的來源再合併去重。）"
  else
    bad "抓到了內容（HTTP 200，$(wc -c < "$out" | xargs) 位元組），但解析出 0 筆網域 —— 格式欄可能寫錯了。"
  fi
}

# ── .setup.local ──────────────────────────────────────────
# 只存**非機密**的資源 ID：帳戶 ID、D1 資料庫 ID、KV namespace ID。
# 這三個東西會出現在每一個 Cloudflare API 路徑裡，本來就不是祕密。
# token 永遠不會出現在這個檔案裡（也不會出現在任何檔案裡）。
# 即使如此還是列進 .gitignore：它們是「你的帳戶的」ID，不該跟著 template 散出去。
load_local_conf() {
  [[ -f "$LOCAL_CONF" ]] || return 0
  # 刻意不 source 這個檔案：source 等於執行它，一個被動過手腳的 .setup.local
  # 就能在這裡跑任意指令。改成逐行嚴格比對。
  local key value line
  while IFS= read -r line; do
    line="${line%$'\r'}"
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ "$line" =~ ^[A-Z0-9_]+=[A-Za-z0-9_-]*$ ]] || continue
    key="${line%%=*}"
    value="${line#*=}"
    case "$key" in
      CF_ACCOUNT_ID)    [[ -z "$ACCOUNT_ID" ]] && ACCOUNT_ID="$value" ;;
      D1_DATABASE_ID)   [[ -z "$D1_ID" ]] && D1_ID="$value" ;;
      KV_NAMESPACE_ID)  [[ -z "$KV_ID" ]] && KV_ID="$value" ;;
    esac
  done < "$LOCAL_CONF"
  info "已讀取 $LOCAL_CONF（只含非機密 ID）"
}

save_local_conf() {
  umask 077
  {
    printf '# 由 setup.sh --provision 產生。**只存非機密的資源 ID**，這裡不會有 API token。\n'
    printf '# 這些 ID 會出現在每一個 Cloudflare API 路徑裡，本來就不是祕密；\n'
    printf '# 列進 .gitignore 是因為它們是「你的帳戶的」ID，不該跟著 template 散出去。\n'
    printf 'CF_ACCOUNT_ID=%s\n' "$ACCOUNT_ID"
    printf 'D1_DATABASE_ID=%s\n' "$D1_ID"
    printf 'KV_NAMESPACE_ID=%s\n' "$KV_ID"
  } > "$LOCAL_CONF"
  ok "已寫入 $LOCAL_CONF（只有上面三個非機密 ID）"
}

# ── 檢查結果總結 ──────────────────────────────────────────
summary() {
  section "檢查結果"
  info "模式：--$MODE"
  if [[ "$MODE" == "check" ]]; then
    ok "本次執行**沒有對你的 Cloudflare 帳戶或 GitHub repo 做任何變更**（全部都是 GET）。"
  fi
  if [[ "$BLOCKERS" -gt 0 ]]; then
    printf '\n✗  有 %s 項是「不可存取」或「無法判定」，另有 %s 項提醒。\n' "$BLOCKERS" "$WARNINGS" >&2
    info "請先把上面標 ✗ 或 ? 的項目處理掉。「無法判定」不要當成通過 —— 它只代表這次沒問出答案。"
    return 1
  fi
  printf '\n✓  檢查項目全部通過，另有 %s 項提醒（標 ⚠）。\n' "$WARNINGS" >&2
  info "再說一次，因為這件事很容易被誤讀："
  info "  上面全綠的意思是「Token 對這些 scope 可存取」，"
  info "  **不是**「權限都設好了、可以開始同步了」。"
  info "  Edit（寫入）權限沒有被證明，也不可能用唯讀探測證明 —— 它只會在第一次真正同步時被證明。"
  return 0
}

# ── 7. --provision ────────────────────────────────────────
add_created() {
  CREATED_KIND+=("$1"); CREATED_NAME+=("$2"); CREATED_ID+=("$3")
}

print_created_resources() {
  local i
  for i in "${!CREATED_ID[@]}"; do
    printf '       [%s] %s ＝ %s\n' "${CREATED_KIND[$i]}" "${CREATED_NAME[$i]}" "${CREATED_ID[$i]}" >&2
    case "${CREATED_KIND[$i]}" in
      D1)     printf '           撤銷：npx wrangler d1 delete %s\n' "${CREATED_NAME[$i]}" >&2 ;;
      KV)     printf '           撤銷：npx wrangler kv namespace delete --namespace-id %s\n' "${CREATED_ID[$i]}" >&2 ;;
      SECRET) printf '           撤銷：gh secret delete %s -R %s\n' "${CREATED_NAME[$i]}" "$GH_REPO" >&2 ;;
      VAR)    printf '           撤銷：gh variable delete %s -R %s\n' "${CREATED_NAME[$i]}" "$GH_REPO" >&2 ;;
    esac
  done
}

gh_secret_exists() {
  # $1 = secret 名稱。存在就回傳 0 並把 updatedAt 印到 stdout。
  local found
  found="$(gh secret list -R "$GH_REPO" --json name,updatedAt \
    --jq ".[] | select(.name == \"$1\") | .updatedAt" 2>/dev/null || true)"
  [[ -n "$found" ]] || return 1
  printf '%s' "$found"
}

set_gh_secret() {
  # $1 = 名稱, $2 = 值。值一律經 stdin 餵給 gh：
  # gh secret set NAME 在沒有 --body 的時候就是從標準輸入讀值。
  # 絕對不用 --body —— 那會把值（其中一個是即時可用的 Cloudflare token）放進 gh 的 argv，
  # 於是 ps 看得到，某些 shell 的 history 也會留下。
  local name="$1" value="$2" existing=""
  if existing="$(gh_secret_exists "$name")"; then
    soft "repo 上已經有同名的 secret：$name（上次更新 $existing）"
    info "覆寫之後，**舊的值永久取不回來**（GitHub 沒有任何方式讀回既有 secret 的值）。"
    info "如果那個舊值是你在別處還在用的憑證，請先確認你手上另有備份。"
    if ! confirm "要覆寫 $name 嗎？（預設不覆寫）"; then
      info "跳過 $name，維持原值不動。"
      return 0
    fi
  fi
  printf '%s' "$value" | gh secret set "$name" -R "$GH_REPO"
  ok "已寫入 secret：$name"
  add_created SECRET "$name" "(值不顯示)"
}

set_gh_variable() {
  local name="$1" value="$2"
  printf '%s' "$value" | gh variable set "$name" -R "$GH_REPO"
  ok "已寫入 variable：$name = $value"
  add_created VAR "$name" "$value"
}

# SQL 字串裡要有單引號（type = 'table'），所以這裡用雙引號括、把 JSON 的引號逃脫掉。
D1_TABLE_SQL="{\"sql\":\"SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name\"}"

provision_d1() {
  local answer="" name="" resp_id="" rc=0
  printf '\n?  D1 資料庫：建立新的，還是沿用既有的？\n' >&2
  printf '   直接按 Enter＝建立新的（預設）。要沿用就貼上既有資料庫的 ID：' >&2
  read -r answer
  if [[ -n "$answer" ]]; then
    if [[ ! "$answer" =~ ^[0-9a-f-]{36}$ ]]; then
      die "'$answer' 不像 D1 資料庫 ID（36 碼的 UUID）。"
    fi
    cf_get "/accounts/$ACCOUNT_ID/d1/database/$answer"
    rc=0; cf_classify || rc=$?
    [[ "$rc" == "0" ]] || { cf_errors_brief; die "讀不到這個 D1 資料庫（HTTP $CF_HTTP_CODE）。"; }
    info "資料庫名稱：$(json str "$CF_RESP" result.name 2>/dev/null || echo '(讀不到)')"
    info "建立時間：$(json str "$CF_RESP" result.created_at 2>/dev/null || echo '(讀不到)')"
    # 沿用之前先看清楚裡面有什麼。SELECT 是唯讀，只是走 POST /query 這個端點。
    printf '%s' "$D1_TABLE_SQL" > "$TMP_DIR/q.json"
    cf_post "/accounts/$ACCOUNT_ID/d1/database/$answer/query" "$TMP_DIR/q.json"
    rc=0; cf_classify || rc=$?
    if [[ "$rc" == "0" ]]; then
      info "現有資料表："
      local t
      while read -r t; do [[ -n "$t" ]] && info "  - $t"; done \
        < <(json field_list "$CF_RESP" 'result.0.results::name' 2>/dev/null || true)
    else
      soft "讀不到資料表清單（HTTP $CF_HTTP_CODE），沒辦法讓你確認裡面原本是什麼。"
    fi
    confirm "確定要沿用這個既有的 D1 資料庫？sync.sh 會在裡面建立並寫入它自己的 7 張表。" \
      || die "你選擇不沿用。"
    D1_ID="$answer"
    ok "沿用既有的 D1 資料庫：$D1_ID"
    return 0
  fi

  name="dns-blocklist-$(date -u +%Y%m%d%H%M%S)"
  confirm "要建立**新的** D1 資料庫 '$name' 嗎？D1 是會計費的資源（免費額度用完之後開始收費）。" \
    || die "你選擇不建立 D1。"
  printf '{"name":"%s"}' "$name" > "$TMP_DIR/body.json"
  cf_post "/accounts/$ACCOUNT_ID/d1/database" "$TMP_DIR/body.json"
  rc=0; cf_classify || rc=$?
  [[ "$rc" == "0" ]] || { cf_errors_brief; die "建立 D1 失敗（HTTP $CF_HTTP_CODE）。沒有建立任何東西。"; }
  resp_id="$(json str "$CF_RESP" result.uuid 2>/dev/null || true)"
  [[ "$resp_id" =~ ^[0-9a-f-]{36}$ ]] || die "建立 D1 的回應裡沒有看起來合法的 uuid，不繼續。"
  D1_ID="$resp_id"
  add_created D1 "$name" "$D1_ID"
  ok "已建立 D1 資料庫 $name ＝ $D1_ID"
}

provision_kv() {
  local answer="" title="" resp_id="" rc=0
  printf '\n?  KV namespace（選用的讀取側快取）：建立新的，還是沿用既有的？\n' >&2
  printf '   直接按 Enter＝建立新的（預設）。輸入 skip＝不用快取（同步照樣正確，只是每次多讀 46 萬列）。\n' >&2
  printf '   要沿用就貼上既有 namespace 的 ID：' >&2
  read -r answer
  if [[ "$answer" == "skip" ]]; then
    info "略過 KV。sync.sh 收到空的 KV_NAMESPACE_ID 就會直接讀 D1。"
    return 0
  fi
  if [[ -n "$answer" ]]; then
    if [[ ! "$answer" =~ ^[0-9a-f]{32}$ ]]; then
      die "'$answer' 不像 KV namespace ID（32 碼十六進位）。"
    fi
    if [[ "$answer" == "$UPSTREAM_KV_DEFAULT" ]]; then
      die "那是本 template 上游作者的 namespace ID，不是你的。請建立你自己的。"
    fi
    cf_get "/accounts/$ACCOUNT_ID/storage/kv/namespaces/$answer"
    rc=0; cf_classify || rc=$?
    [[ "$rc" == "0" ]] || { cf_errors_brief; die "讀不到這個 KV namespace（HTTP $CF_HTTP_CODE）。"; }
    info "namespace 標題：$(json str "$CF_RESP" result.title 2>/dev/null || echo '(讀不到)')"
    # read-before-write：沿用之前先確認目標 key 不會被我們蓋掉。
    local keyfile="$TMP_DIR/kvkey.bin"
    CF_HTTP_CODE="$(
      cf_config_stdin | curl -q -sS --max-time 30 --proto '=https' --proto-redir '=https' \
        --config - -o "$keyfile" -w '%{http_code}' \
        -- "$CF_API/accounts/$ACCOUNT_ID/storage/kv/namespaces/$answer/values/category-cache-v1"
    )" || CF_HTTP_CODE="000"
    case "$CF_HTTP_CODE" in
      404) ok "目標 key category-cache-v1 不存在，沿用不會蓋掉任何東西。" ;;
      200)
        info "目標 key category-cache-v1 已經存在（$(wc -c < "$keyfile" | xargs) 位元組），檢查格式……"
        if gzip -t "$keyfile" 2>/dev/null \
           && [[ "$(gzip -dc "$keyfile" 2>/dev/null | head -1 | awk -F'\t' '{print NF}')" == "3" ]]; then
          soft "格式符合本專案的快照（gzip + 三欄 TSV）。沿用的話下次同步會**覆寫**它。"
          confirm "確定要沿用並覆寫這個既有的快照嗎？" || die "你選擇不沿用。"
        else
          die "目標 key 已經存在，但內容不是本專案的格式（gzip + 三欄 TSV）。拒絕沿用 —— 那是別的東西，蓋掉它不會是你想做的事。"
        fi ;;
      *) die "讀取目標 key 時得到 HTTP $CF_HTTP_CODE，無法確認會不會蓋到東西，拒絕沿用。" ;;
    esac
    KV_ID="$answer"
    ok "沿用既有的 KV namespace：$KV_ID"
    return 0
  fi

  title="adblock-category-cache-$(date -u +%Y%m%d%H%M%S)"
  confirm "要建立**新的** KV namespace '$title' 嗎？KV 也是會計費的資源。" \
    || die "你選擇不建立 KV。"
  printf '{"title":"%s"}' "$title" > "$TMP_DIR/body.json"
  cf_post "/accounts/$ACCOUNT_ID/storage/kv/namespaces" "$TMP_DIR/body.json"
  rc=0; cf_classify || rc=$?
  [[ "$rc" == "0" ]] || { cf_errors_brief; die "建立 KV namespace 失敗（HTTP $CF_HTTP_CODE）。"; }
  resp_id="$(json str "$CF_RESP" result.id 2>/dev/null || true)"
  [[ "$resp_id" =~ ^[0-9a-f]{32}$ ]] || die "建立 KV 的回應裡沒有看起來合法的 id，不繼續。"
  KV_ID="$resp_id"
  add_created KV "$title" "$KV_ID"
  ok "已建立 KV namespace $title ＝ $KV_ID"
}

provision_gh_preflight() {
  # 回傳 0 = 可以寫 GitHub secret；回傳 1 = 降級成「印出要你手動設定的東西」。
  if ! command -v gh >/dev/null 2>&1; then
    soft "沒有 gh（GitHub CLI），無法自動寫 secret。"
    return 1
  fi
  if ! gh auth status >/dev/null 2>&1; then
    soft "gh 還沒登入（gh auth login），無法自動寫 secret。"
    return 1
  fi
  if [[ -z "$GH_REPO" ]]; then
    soft "推導不出 owner/repo，不猜。"
    return 1
  fi
  local is_admin=""
  is_admin="$(gh api "repos/$GH_REPO" --jq '.permissions.admin' 2>/dev/null || true)"
  if [[ "$is_admin" != "true" ]]; then
    soft "你對 $GH_REPO 沒有 admin 權限（讀到的值：${is_admin:-讀不到}），寫 secret 一定會失敗。"
    return 1
  fi
  ok "gh 前置檢查通過：已登入，且你對 $GH_REPO 有 admin 權限。"
  return 0
}

provision_manual_instructions() {
  printf '\n' >&2
  info "需要你自己到 GitHub 上設定的東西（Settings → Secrets and variables → Actions）："
  info "  Secrets："
  info "    $SECRET_NAME_TOKEN   ＝ 你剛才貼給這支腳本的 Cloudflare API Token"
  info "    $SECRET_NAME_ACCOUNT ＝ $ACCOUNT_ID"
  info "    $SECRET_NAME_D1      ＝ ${D1_ID:-（還沒有 D1 資料庫 ID）}"
  info "  Variables（不是 secret，namespace ID 不是機密）："
  info "    $VAR_NAME_KV         ＝ ${KV_ID:-（留空＝不用 KV 快取，直接讀 D1）}"
}

provision() {
  section "7. --provision：建立資源並寫入 GitHub"

  if [[ "$BLOCKERS" -gt 0 ]]; then
    die "上面的檢查有 $BLOCKERS 項沒過（✗ 或 ?）。--provision 會建立會計費的資源、寫入不可復原的 secret，
    所以只有在檢查全過的情況下才會往下做。請先處理掉那些項目，再重跑一次。"
  fi
  if [[ "$GH_REPO" == "$TEMPLATE_UPSTREAM" ]]; then
    die "這個 clone 指向本 template 的上游 $TEMPLATE_UPSTREAM。
    請先在 GitHub 上用 Use this template（或 fork）建立你自己的 repo、把 origin 換成它，再跑 --provision。"
  fi

  printf '\n' >&2
  info "接下來會做的事（每一步都會再問你一次）："
  info "  1. 在 Cloudflare 帳戶 $ACCOUNT_ID 建立（或沿用）一個 D1 資料庫 —— **會計費的資源**"
  info "  2. 建立（或沿用、或略過）一個 KV namespace —— **會計費的資源**"
  info "  3. 把 $SECRET_NAME_TOKEN / $SECRET_NAME_ACCOUNT / $SECRET_NAME_D1 寫進 ${GH_REPO:-（推導不出來的 repo）} 的 secret"
  info "     —— 同名 secret 一旦覆寫，**舊值永久取不回來**"
  info "  4. 把 $VAR_NAME_KV 寫進同一個 repo 的 variable"
  info "  5. 把三個非機密 ID 寫進 $LOCAL_CONF（不含 token）"
  info "任何一步失敗都會停下來，而且**不會自動刪除已經建立的資源** ——"
  info "自動刪除在這種情境下太危險（萬一失敗的原因只是網路斷了，刪掉才是真的損失）。"
  info "停下來的時候會印出已建立的資源 ID 與逐項撤銷指令，由你決定要不要清掉。"

  confirm "了解以上內容，要開始建立資源嗎？" || die "你選擇不繼續。到這裡為止什麼都還沒建立。"
  PROVISION_CONFIRMED=1

  provision_d1
  provision_kv

  if provision_gh_preflight; then
    set_gh_secret "$SECRET_NAME_ACCOUNT" "$ACCOUNT_ID"
    set_gh_secret "$SECRET_NAME_D1" "$D1_ID"
    set_gh_secret "$SECRET_NAME_TOKEN" "$CF_TOKEN"
    if [[ -n "$KV_ID" ]]; then
      set_gh_variable "$VAR_NAME_KV" "$KV_ID"
    else
      info "沒有 KV namespace，不設定 $VAR_NAME_KV。sync.sh 會直接讀 D1。"
    fi
  else
    soft "自動寫入 GitHub 的部分降級為「印出要你手動設定的內容」，其餘步驟照常完成。"
    provision_manual_instructions
  fi

  save_local_conf

  section "--provision 完成"
  if [[ ${#CREATED_ID[@]} -eq 0 ]]; then
    info "本次沒有建立任何新資源（你全部選了沿用或略過）。"
  else
    info "本次建立的每一項資源，以及逐項的人工撤銷指令："
    print_created_resources
    printf '\n' >&2
    info "**這些資源會計費。** D1 與 KV 都有免費額度，超過之後照 Cloudflare 的價目表收費；"
    info "即使用量在免費額度內，它們也會一直存在於你的帳戶上，直到你自己刪除。"
    info "這支腳本不會、也不應該替你刪任何東西 —— 撤銷請照上面的指令自己執行。"
  fi
  printf '\n' >&2
  info "下一步：到 GitHub Actions 手動觸發一次 sync workflow（或等排程）。"
  info "第一次真正同步的時候，Edit（寫入）權限才會被證明 —— 在那之前，"
  info "上面所有的綠燈都只代表「讀得到」。"
}

# ── main ──────────────────────────────────────────────────
main() {
  refuse_ci
  parse_args "$@"

  TMP_DIR="$(mktemp -d)"
  chmod 700 "$TMP_DIR" 2>/dev/null || true

  printf '\n' >&2
  printf '   cloudflare-gateway-block-ads — setup.sh（模式：--%s）\n' "$MODE" >&2
  if [[ "$MODE" == "check" ]]; then
    printf '   這個模式是唯讀的：只會發 GET 請求，對你的 Cloudflare 帳戶與 GitHub repo 零變更。\n' >&2
  else
    printf '   這個模式會建立會計費的資源、寫入無法復原的 secret —— 每一步都會先問你。\n' >&2
  fi

  load_local_conf
  check_tools
  detect_repo
  check_upstream_defaults
  acquire_token
  probe_token
  check_one_source

  local check_ok=0
  summary || check_ok=$?

  if [[ "$MODE" == "provision" ]]; then
    provision
  fi

  return "$check_ok"
}

# 用 || 承接回傳值：在 || 左邊失敗不會觸發 ERR trap，
# 所以「檢查沒過」只會印出檢查結果，不會再多印一段「第幾行失敗」的現場。
SETUP_RC=0
main "$@" || SETUP_RC=$?
trap - ERR
exit "$SETUP_RC"
