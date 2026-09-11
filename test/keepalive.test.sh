#!/usr/bin/env bash
# 選用式保活（.github/workflows/keepalive.yml）的守門與行為測試。
#
# 那支 workflow 是整個 repo 裡唯一持有寫入權限 token 的 job。它能改 sync.sh，而 sync.sh
# 每小時會帶著 Cloudflare token 執行 —— 所以它的樣子不能只靠約定，必須由這支測試釘死。
#
# 兩部分：
#   (a) 守門（用 Python，不用 awk / sed）：先驗位元組，再逐行比對整份骨架。
#       位元組這一步不能用 awk 做：這台開發機上的 MSYS awk 讀檔時就把 CR 剝掉了，
#       而一個夾在行中間的 CR 正是能讓 GitHub 的 YAML 解析器看到「多一個 job」、
#       這支守門卻只看到「一行註解」的繞過方式。
#   (b) 行為：從 keepalive.yml 抽出正在跑的那段腳本（不抄平行實作），對著一個只綁
#       127.0.0.1 的 GitHub API 模擬伺服器實際執行。全程離線，不需要任何憑證。
#
# 每一條防護都配一個反事實：把缺陷故意放進暫存副本，確認這支測試真的會失敗。
#
# 用法：bash test/keepalive.test.sh [repo 根目錄]
set -uo pipefail

ROOT="${1:-$(dirname "$0")/..}"
YML="$ROOT/.github/workflows/keepalive.yml"
README="$ROOT/README.md"
[[ -f "$YML" ]] || { echo "找不到 $YML" >&2; exit 2; }
[[ -f "$README" ]] || { echo "找不到 $README" >&2; exit 2; }

PY="$(command -v python3 || command -v python || true)"
[[ -n "$PY" ]] || { echo "需要 python3 才能跑守門檢查" >&2; exit 2; }

WORK="$(mktemp -d)"
MOCK_PID=""
cleanup() {
  [[ -n "$MOCK_PID" ]] && kill "$MOCK_PID" 2>/dev/null
  rm -rf "$WORK"
}
trap cleanup EXIT

PASS=0; FAIL=0; SKIPPED=0
ok()  { echo "  ✅ $1"; PASS=$((PASS + 1)); }
bad() { echo "  ❌ $1"; FAIL=$((FAIL + 1)); }

# ══════════════════════════════════════════════════════════
# 守門程式
# ══════════════════════════════════════════════════════════
cat > "$WORK/guard.py" <<'PYEOF'
"""keepalive.yml 的守門。以位元組讀檔，失敗即拒絕。

輸出第一行為 "OK threshold=<N>" 或 "FAIL <原因>"，結束碼 0 / 1。
第二個參數若給，把 run 本體（去掉縮排）寫到該路徑，供行為測試使用。
"""
import re
import sys

# run 本體以外、每一條非空白非註解的行，必須逐行、依序、一對一符合這份清單。
# None 那一格是門檻那一行，用 THRESH_RE 比對並另外檢查上界。
EXPECTED = [
    'name: Keepalive (optional)',
    'on:',
    '  schedule:',
    '    - cron: "17 4 * * 1"',
    '  workflow_dispatch:',
    'permissions: {}',
    'concurrency:',
    '  group: keepalive',
    '  cancel-in-progress: false',
    'jobs:',
    '  keepalive:',
    "    if: vars.KEEPALIVE_ENABLED == 'true' && github.repository != 'tony8077616/cloudflare-gateway-block-ads'",
    '    runs-on: ubuntu-24.04',
    '    timeout-minutes: 5',
    '    permissions:',
    '      contents: write',
    '    steps:',
    '      - name: Keep repository activity alive',
    '        shell: bash',
    '        env:',
    '          GH_TOKEN: ${{ github.token }}',
    '          REPO: ${{ github.repository }}',
    None,
    '        run: |',
]
THRESH_RE = re.compile(r'^          SKIP_IF_RECENT_DAYS: "([0-9]+)"$')
RUN_LINE = '        run: |'
RUN_KEY_INDENT = 8
BODY_INDENT = 10
MARKER = '# keepalive-script-marker'

# 門檻上界：門檻 + 兩次漏跑的每週週期 + 排程延遲的餘裕，不能超過 GitHub 的 60 天。
CADENCE_DAYS = 7
MISSED_RUNS = 2
MARGIN_DAYS = 10
LIMIT_DAYS = 60


def fail(reason):
    print('FAIL ' + reason)
    sys.exit(1)


path = sys.argv[1]
emit = sys.argv[2] if len(sys.argv) > 2 else None
raw = open(path, 'rb').read()

# 1. 位元組：CRLF 的 CR 先拿掉，之後只准 0x20-0x7E 與 LF。
data = raw.replace(b'\r\n', b'\n')
line_no = 1
for b in data:
    if b == 0x0A:
        line_no += 1
        continue
    if 0x20 <= b <= 0x7E:
        continue
    if b == 0x0D:
        cls = 'CR (0x0d)'
    elif b == 0x09:
        cls = 'TAB (0x09)'
    elif b == 0x00:
        cls = 'NUL (0x00)'
    elif b < 0x20 or b == 0x7F:
        cls = 'control byte (0x%02x)' % b
    else:
        cls = 'non-ASCII byte (0x%02x)' % b
    fail('disallowed-byte: %s at line %d' % (cls, line_no))

lines = data.decode('ascii').split('\n')
if lines and lines[-1] == '':
    lines.pop()

# 2. 找出 run 本體。
run_idx = [i for i, l in enumerate(lines) if l == RUN_LINE]
if len(run_idx) != 1:
    fail('run-line: expected exactly one "run: |" line at indent %d, found %d' % (RUN_KEY_INDENT, len(run_idx)))
r = run_idx[0]
body = []
j = r + 1
while j < len(lines):
    l = lines[j]
    if l.strip() == '':
        body.append('')
        j += 1
        continue
    ind = len(l) - len(l.lstrip(' '))
    if ind <= RUN_KEY_INDENT:
        break
    if ind < BODY_INDENT:
        fail('body-indentation: line %d is indented %d, expected at least %d' % (j + 1, ind, BODY_INDENT))
    body.append(l[BODY_INDENT:])
    j += 1

# 3. 骨架：run 本體以外的非空白、非註解行。
skeleton = []
for idx in list(range(0, r + 1)) + list(range(j, len(lines))):
    s = lines[idx].strip()
    if s == '' or s.startswith('#'):
        continue
    skeleton.append((idx + 1, lines[idx]))

thresh = None
for k, exp in enumerate(EXPECTED):
    if k >= len(skeleton):
        fail('skeleton-missing-line: expected "%s"' % (exp if exp is not None else 'SKIP_IF_RECENT_DAYS'))
    ln, got = skeleton[k]
    if exp is None:
        m = THRESH_RE.match(got)
        if not m:
            fail('skeleton-mismatch at line %d: got "%s", expected SKIP_IF_RECENT_DAYS: "<integer>"' % (ln, got))
        thresh = int(m.group(1))
    elif got != exp:
        fail('skeleton-mismatch at line %d: got "%s", expected "%s"' % (ln, got, exp))
if len(skeleton) > len(EXPECTED):
    ln, got = skeleton[len(EXPECTED)]
    fail('skeleton-extra-line at line %d: "%s"' % (ln, got))

# 4. 門檻上界。
if thresh < 1 or thresh + CADENCE_DAYS * MISSED_RUNS + MARGIN_DAYS > LIMIT_DAYS:
    fail('threshold-bound: SKIP_IF_RECENT_DAYS=%d, need 1 <= N and N + %d + %d <= %d'
         % (thresh, CADENCE_DAYS * MISSED_RUNS, MARGIN_DAYS, LIMIT_DAYS))

# 5. run 本體。
if not any(l.strip() == MARKER for l in body):
    fail('body-marker: "%s" not found in run body' % MARKER)
for k, l in enumerate(body):
    # ${{ }} 在 run 裡連 shell 註解都會被 Actions 展開，所以註解行也要檢查。
    if '${{' in l:
        fail('body-expression: "${{" in run body line %d' % (k + 1))
    s = l.strip()
    if s.startswith('#'):
        continue
    if 'secrets.' in l:
        fail('body-secret: "secrets." in run body line %d' % (k + 1))
    if 'force' in l.lower():
        fail('body-force: "force" in run body line %d' % (k + 1))
    if '-H "Authorization' in l or "-H 'Authorization" in l:
        fail('body-auth-header: Authorization passed as a curl argument in run body line %d' % (k + 1))

if emit:
    with open(emit, 'w', encoding='ascii', newline='\n') as fh:
        fh.write('\n'.join(body) + '\n')

print('OK threshold=%d' % thresh)
PYEOF

# ══════════════════════════════════════════════════════════
# 反事實產生器：每一種都是一個「必須被擋下」的壞版本
# ══════════════════════════════════════════════════════════
cat > "$WORK/mutate.py" <<'PYEOF'
"""把 keepalive.yml 改成指定的壞版本。錨點找不到就失敗，
避免檔案改動之後反事實悄悄變成「沒改到東西」的假測試。"""
import re
import sys

src, dst, name = sys.argv[1], sys.argv[2], sys.argv[3]
text = open(src, 'rb').read().replace(b'\r\n', b'\n').decode('ascii')

MARKER = '          # keepalive-script-marker\n'
STEPS = '    steps:\n'
REPO = '          REPO: ${{ github.repository }}\n'
ON = 'on:\n  schedule:\n    - cron: "17 4 * * 1"\n  workflow_dispatch:\n'
JOBPERM = '    permissions:\n      contents: write\n'
THRESH = re.compile(r'(          SKIP_IF_RECENT_DAYS: ")([0-9]+)(")')


def once(t, old, new):
    n = t.count(old)
    if n != 1:
        sys.exit('anchor not unique (%d): %r' % (n, old))
    return t.replace(old, new)


out = None
if name == 'crlf':
    out = text.replace('\n', '\r\n').encode('ascii')
elif name == 'add-uses-step':
    out = once(text, STEPS, STEPS + '      - uses: evil/a@v1\n')
elif name == 'add-secret-env':
    out = once(text, REPO, REPO + '          EVIL: ${{ secrets.X }}\n')
elif name == 'force-in-body':
    out = once(text, MARKER, MARKER + '          git push --force origin HEAD\n')
elif name == 'expr-in-body':
    out = once(text, MARKER, MARKER + '          echo "${{ github.actor }}"\n')
elif name == 'add-pr-trigger':
    out = once(text, '  workflow_dispatch:\n', '  workflow_dispatch:\n  pull_request:\n')
elif name == 'flow-on':
    out = once(text, ON, 'on: [schedule, workflow_dispatch, pull_request_target]\n')
elif name == 'write-all':
    out = once(text, 'permissions: {}\n', 'permissions: write-all\n')
elif name == 'job-flow-perms':
    out = once(text, JOBPERM, '    permissions: { contents: write, actions: write }\n')
elif name == 'flow-uses':
    out = once(text, STEPS, STEPS + '      - { uses: x/y@v1 }\n')
elif name == 'quoted-key':
    out = once(text, STEPS, STEPS + '      - "uses": x\n')
elif name == 'merge-key':
    out = once(text, '  keepalive:\n', '  keepalive:\n    <<: *x\n')
elif name == 'monthly-cron':
    out = once(text, '"17 4 * * 1"', '"17 4 1 * *"')
elif name in ('thresh-3650', 'thresh-60'):
    val = name.split('-')[1]
    out, n = THRESH.subn(lambda m: m.group(1) + val + m.group(3), text)
    if n != 1:
        sys.exit('threshold anchor not found')
elif name == 'cr-in-comment':
    out = once(text, ON, '# x\r  other-job:\r    permissions: write-all\r    steps:\r      - uses: evil/a@v1\n' + ON).encode('ascii')
elif name == 'cr-in-body':
    out = once(text, MARKER, MARKER + '          echo a\r  other-job:\r    runs-on: ubuntu-24.04\n').encode('ascii')
elif name == 'u2028-in-comment':
    out = once(text, ON, '# x\u2028  other-job:\n' + ON).encode('utf-8')
else:
    sys.exit('unknown mutation: ' + name)

if isinstance(out, str):
    out = out.encode('ascii')
open(dst, 'wb').write(out)
PYEOF

# ══════════════════════════════════════════════════════════
# (a) 守門
# ══════════════════════════════════════════════════════════
echo "keepalive.yml 的守門"

guard_out="$("$PY" "$WORK/guard.py" "$YML" "$WORK/body.sh")"
guard_rc=$?
if [[ $guard_rc -eq 0 && "$guard_out" == "OK threshold="* ]]; then
  ok "正式檔案通過（位元組、骨架、門檻上界、run 本體）"
else
  bad "正式檔案沒有通過守門：$guard_out"
fi

# 門檻由 keepalive.yml 決定，這支測試不另外寫死一份。
THRESH="${guard_out#OK threshold=}"
if [[ ! "$THRESH" =~ ^[0-9]+$ ]]; then
  echo "❌ 抽取失敗：讀不到 keepalive.yml 的 SKIP_IF_RECENT_DAYS" >&2
  exit 2
fi

"$PY" "$WORK/mutate.py" "$YML" "$WORK/crlf.yml" crlf
crlf_out="$("$PY" "$WORK/guard.py" "$WORK/crlf.yml")"
if [[ $? -eq 0 && "$crlf_out" == "OK threshold=$THRESH" ]]; then
  ok "CRLF 版本也通過（Windows checkout）"
else
  bad "CRLF 版本沒有通過：$crlf_out"
fi

check_rejected() {
  # $1 = 反事實名稱, $2 = 必須出現的原因字首
  local name="$1" want="$2" out rc
  if ! "$PY" "$WORK/mutate.py" "$YML" "$WORK/m.yml" "$name" > "$WORK/mut.txt" 2>&1; then
    bad "反事實 $name 產生失敗：$(cat "$WORK/mut.txt")"
    return
  fi
  out="$("$PY" "$WORK/guard.py" "$WORK/m.yml")"
  rc=$?
  if [[ $rc -ne 0 && "$out" == "FAIL $want"* ]]; then
    ok "反事實 $name → 擋下（$want）"
  else
    bad "反事實 $name 沒有被正確擋下（rc=$rc，輸出：$out）"
  fi
}

check_rejected add-uses-step    skeleton
check_rejected add-secret-env   skeleton
check_rejected force-in-body    body-force
check_rejected expr-in-body     body-expression
check_rejected add-pr-trigger   skeleton
check_rejected flow-on          skeleton
check_rejected write-all        skeleton
check_rejected job-flow-perms   skeleton
check_rejected flow-uses        skeleton
check_rejected quoted-key       skeleton
check_rejected merge-key        skeleton
check_rejected monthly-cron     skeleton
check_rejected thresh-3650      threshold-bound
check_rejected thresh-60        threshold-bound
check_rejected cr-in-comment    disallowed-byte
check_rejected cr-in-body       disallowed-byte
check_rejected u2028-in-comment disallowed-byte

# 抽出來的 run 本體必須真的是那段腳本，不是一個空殼。
if [[ -s "$WORK/body.sh" ]] && grep -q '^# keepalive-script-marker$' "$WORK/body.sh" && bash -n "$WORK/body.sh"; then
  ok "run 本體抽取成功（非空、含標記、bash -n 通過）"
else
  echo "❌ 抽取失敗：run 本體是空的、缺標記，或語法錯誤" >&2
  exit 2
fi

# ══════════════════════════════════════════════════════════
# README 與 workflow 的數字必須一致
# ══════════════════════════════════════════════════════════
echo "README 的說明"
readme_ok=1
for phrase in \
  "KEEPALIVE_ENABLED" \
  "超過 ${THRESH} 天" \
  "官方文件沒有說明這種空 commit 算不算" \
  "keepalive 本身也是排程 workflow" \
  "Workers Builds" \
  "不要為了讓它通過而改給它 PAT" \
  "上游這個 template repo 本身永遠不會執行"; do
  if ! grep -qF -- "$phrase" "$README"; then
    bad "README 缺少：$phrase"
    readme_ok=0
  fi
done
[[ $readme_ok -eq 1 ]] && ok "README 的啟用方式與每一項風險說明都在，門檻數字與 workflow 一致（${THRESH} 天）"

# ══════════════════════════════════════════════════════════
# (b) 行為：對著模擬的 GitHub API 實際執行
# ══════════════════════════════════════════════════════════
echo "keepalive 腳本的行為"

if ! command -v jq >/dev/null 2>&1 || ! command -v node >/dev/null 2>&1; then
  echo "  ⏭  跳過：這台機器缺 jq 或 node，被測的腳本無法執行（CI 上會實際執行）"
  SKIPPED=$((SKIPPED + 14))
else

cat > "$WORK/mock.mjs" <<'MOCKEOF'
// 模擬 GitHub 的 git data API。只綁 127.0.0.1。
// 每個請求都記下來；並且由伺服器自己檢查「新 commit 的 tree 必須等於它所列 parent 的 tree」，
// 違反就記一筆 —— 這樣測的是「實際送出了什麼」，而不是腳本自己宣稱做了什麼。
import { createServer } from "node:http";
import { appendFileSync, writeFileSync } from "node:fs";
import { createHash } from "node:crypto";

const [, , logPath, statePath, mode, defaultBranch, headDate] = process.argv;
const h = (s) => createHash("sha1").update(s).digest("hex");
const T0 = h("tree0"), T1 = h("tree1");
const H0 = h("head0"), H1 = h("head1");
const commits = {
  [H0]: { tree: T0, parent: null, date: headDate },
  [H1]: { tree: T1, parent: H0, date: new Date().toISOString() },
};
let head = H0;
let refGets = 0;
let posts = 0;
const state = { h0: H0, h1: H1, violations: [], forceSeen: false };
const save = () => writeFileSync(statePath, JSON.stringify({ ...state, head }));
save();

const server = createServer((req, res) => {
  let body = "";
  req.on("data", (c) => { body += c; });
  req.on("end", () => {
    appendFileSync(logPath, JSON.stringify({
      method: req.method, url: req.url, auth: req.headers["authorization"] || "", body,
    }) + "\n");
    const send = (code, obj) => {
      res.writeHead(code, { "Content-Type": "application/json" });
      res.end(JSON.stringify(obj));
      save();
    };
    const url = req.url;
    const base = "/repos/o/r";
    if (req.method === "GET" && url === base) {
      return send(200, { default_branch: defaultBranch });
    }
    if (req.method === "GET" && url === `${base}/git/ref/heads/${defaultBranch}`) {
      const served = head;
      refGets += 1;
      // 模擬「讀完分支之後，有人剛好推了一個 commit」
      if (mode === "concurrent" && refGets === 1) head = H1;
      return send(200, { object: { sha: served } });
    }
    let m = url.match(/^\/repos\/o\/r\/git\/commits\/([0-9a-f]{40})$/);
    if (req.method === "GET" && m) {
      const c = commits[m[1]];
      if (!c) return send(404, { message: "Not Found" });
      return send(200, { sha: m[1], tree: { sha: c.tree }, committer: { date: c.date } });
    }
    if (req.method === "POST" && url === `${base}/git/commits`) {
      const b = JSON.parse(body || "{}");
      const parent = (b.parents || [])[0];
      if (!commits[parent] || commits[parent].tree !== b.tree) {
        state.violations.push({ parent, tree: b.tree });
      }
      posts += 1;
      const sha = h("new" + posts);
      commits[sha] = { tree: b.tree, parent, date: new Date().toISOString() };
      const replyTree = mode === "tree-mismatch" ? h("other-tree") : b.tree;
      return send(201, { sha, tree: { sha: replyTree }, parents: [{ sha: parent }] });
    }
    if (req.method === "PATCH" && url === `${base}/git/refs/heads/${defaultBranch}`) {
      const b = JSON.parse(body || "{}");
      if (Object.prototype.hasOwnProperty.call(b, "force")) state.forceSeen = true;
      if (mode === "patch422") return send(422, { message: "Protected branch update failed" });
      const target = commits[b.sha];
      if (!target || target.parent !== head) return send(422, { message: "Update is not a fast forward" });
      head = b.sha;
      return send(200, { object: { sha: head } });
    }
    return send(404, { message: "Not Found" });
  });
});
server.listen(0, "127.0.0.1", () => process.stdout.write(String(server.address().port) + "\n"));
MOCKEOF

# curl 包裝：記下每一次呼叫的完整 argv，再交給真正的 curl。
# 這才是「token 沒有進 argv」的直接證據；只驗標頭有沒有送到，證明不了這件事。
REAL_CURL="$(command -v curl)"
mkdir -p "$WORK/bin"
cat > "$WORK/bin/curl" <<'WRAPEOF'
#!/usr/bin/env bash
# %q 而不是 %s：--data 送出的 JSON 會含換行。用 %s 的話一次呼叫會佔好幾行，
# 下面「用行數算呼叫次數」就會算錯 —— 第一版就是這樣，CI 上 5 次呼叫被算成 13 行。
# %q 把換行寫成 $'\n' 這種跳脫形式，一次呼叫固定只佔一行；--config、- 與 token
# 本身都沒有需要跳脫的字元，所以另外兩條斷言不受影響。
printf '%q\037' "$@" >> "$CURL_ARGV_LOG"
printf '\n' >> "$CURL_ARGV_LOG"
exec "$REAL_CURL" "$@"
WRAPEOF
chmod +x "$WORK/bin/curl"

FAKE="ghs_FAKEkeepaliveTOKEN0123456789abcdef"
LOG="$WORK/requests.log"
STATE="$WORK/state.json"
ARGV_LOG="$WORK/argv.log"

run_case() {
  # $1 = 模式, $2 = HEAD 的 committer 日期, $3 = GITHUB_REF, $4 = 預設分支, $5 = 要執行的腳本
  : > "$LOG"; : > "$ARGV_LOG"; rm -f "$STATE"
  node "$WORK/mock.mjs" "$LOG" "$STATE" "$1" "$4" "$2" > "$WORK/port.txt" &
  MOCK_PID=$!
  local port="" _
  for _ in $(seq 1 50); do
    port="$(tr -d '\r\n' < "$WORK/port.txt" 2>/dev/null)"
    [[ -n "$port" ]] && break
    sleep 0.1
  done
  [[ -n "$port" ]] || { echo "❌ 模擬伺服器沒有起來" >&2; exit 2; }
  env PATH="$WORK/bin:$PATH" CURL_ARGV_LOG="$ARGV_LOG" REAL_CURL="$REAL_CURL" \
    GH_TOKEN="$FAKE" REPO="o/r" GITHUB_API_URL="http://127.0.0.1:$port" \
    GITHUB_REF="$3" SKIP_IF_RECENT_DAYS="$THRESH" \
    bash "$5" > "$WORK/out.txt" 2>&1
  RC=$?
  kill "$MOCK_PID" 2>/dev/null; wait "$MOCK_PID" 2>/dev/null; MOCK_PID=""
  N_REQ=$(wc -l < "$LOG" | tr -d ' ')
  N_POST=$(jq -s '[.[] | select(.method == "POST")] | length' "$LOG")
  N_PATCH=$(jq -s '[.[] | select(.method == "PATCH")] | length' "$LOG")
  N_BADAUTH=$(jq -s --arg a "Bearer $FAKE" '[.[] | select(.auth != $a)] | length' "$LOG")
  N_VIOL=$(jq '.violations | length' "$STATE")
  FORCE=$(jq -r '.forceSeen' "$STATE")
  HEAD_NOW=$(jq -r '.head' "$STATE")
  H0=$(jq -r '.h0' "$STATE"); H1=$(jq -r '.h1' "$STATE")
  N_INVOC=$(wc -l < "$ARGV_LOG" | tr -d ' ')
  N_TOKEN_IN_ARGV=$(grep -cF -- "$FAKE" "$ARGV_LOG")
  N_WITH_CONFIG=$(grep -cF -- $'--config\037-\037' "$ARGV_LOG")
}

iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }
NOW=$(date -u +%s)
STALE=$(iso $((NOW - (THRESH + 5) * 86400)))
RECENT=$(iso $((NOW - (THRESH - 5) * 86400)))
FUTURE=$(iso $((NOW + 30 * 86400)))
BODY="$WORK/body.sh"

# ── 正常：HEAD 已經超過門檻 ──
run_case normal "$STALE" refs/heads/main main "$BODY"
if [[ $RC -eq 0 && $N_POST -eq 1 && $N_PATCH -eq 1 && $N_VIOL -eq 0 && "$FORCE" == "false" && $N_BADAUTH -eq 0 && "$HEAD_NOW" != "$H0" ]]; then
  ok "HEAD 超過門檻 → 建一個 tree 與 parent 相同的空 commit 並推進分支，沒有 force，每個請求都帶 Authorization"
else
  bad "HEAD 超過門檻的情境不符（rc=$RC post=$N_POST patch=$N_PATCH 違規=$N_VIOL force=$FORCE 缺授權=$N_BADAUTH）：$(tail -3 "$WORK/out.txt")"
fi
if [[ $N_TOKEN_IN_ARGV -eq 0 && $N_WITH_CONFIG -eq $N_INVOC && $N_INVOC -eq $N_REQ && $N_INVOC -gt 0 ]]; then
  ok "token 從未出現在 curl 的 argv；$N_INVOC 次呼叫都用 --config -，且與伺服器收到的請求數相同"
else
  bad "argv 檢查失敗（token 出現 $N_TOKEN_IN_ARGV 次、帶 --config - 的 $N_WITH_CONFIG/$N_INVOC 次、伺服器收到 $N_REQ 個請求）"
fi

# ── 讀完分支後有人剛好推了 commit ──
run_case concurrent "$STALE" refs/heads/main main "$BODY"
if [[ $RC -ne 0 && $N_POST -eq 1 && $N_VIOL -eq 0 && "$HEAD_NOW" == "$H1" ]]; then
  ok "並行推送 → 更新被拒、腳本以非零結束，別人推的那個 commit 沒有被蓋掉"
else
  bad "並行推送的情境不符（rc=$RC post=$N_POST 違規=$N_VIOL head=$HEAD_NOW）"
fi

# ── HEAD 很新 ──
run_case normal "$RECENT" refs/heads/main main "$BODY"
if [[ $RC -eq 0 && $N_POST -eq 0 && $N_PATCH -eq 0 ]]; then
  ok "HEAD 還在門檻內 → 什麼都不做"
else
  bad "HEAD 很新卻做了事（rc=$RC post=$N_POST patch=$N_PATCH）"
fi

# ── 未來日期、無法解析的日期：偏向 commit，不能永遠跳過 ──
for d in "$FUTURE" "not-a-date"; do
  run_case normal "$d" refs/heads/main main "$BODY"
  if [[ $RC -eq 0 && $N_POST -eq 1 && $N_PATCH -eq 1 ]]; then
    ok "committer 日期為「$d」→ 視為過期，照樣 commit"
  else
    bad "committer 日期為「$d」時沒有 commit（rc=$RC post=$N_POST patch=$N_PATCH）"
  fi
done

# ── 不是從預設分支觸發 ──
run_case normal "$STALE" refs/heads/side main "$BODY"
if [[ $RC -ne 0 && $N_POST -eq 0 ]]; then
  ok "從非預設分支觸發 → 拒絕執行"
else
  bad "從非預設分支觸發卻沒有拒絕（rc=$RC post=$N_POST）"
fi

# ── 預設分支名稱含不允許的字元 ──
run_case normal "$STALE" 'refs/heads/main#x' 'main#x' "$BODY"
if [[ $RC -ne 0 && $N_POST -eq 0 ]]; then
  ok "預設分支名稱含 # → 拒絕執行"
else
  bad "預設分支名稱含 # 卻沒有拒絕（rc=$RC post=$N_POST）"
fi

# ── 伺服器回的新 commit 與釘住的 tree 不符 ──
run_case tree-mismatch "$STALE" refs/heads/main main "$BODY"
if [[ $RC -ne 0 && $N_POST -eq 1 && $N_PATCH -eq 0 ]]; then
  ok "建出來的 commit 與釘住的 tree 不符 → 不更新分支"
else
  bad "tree 不符卻更新了分支（rc=$RC post=$N_POST patch=$N_PATCH）"
fi

# ── 分支保護擋下 ──
run_case patch422 "$STALE" refs/heads/main main "$BODY"
if [[ $RC -ne 0 && $N_PATCH -eq 1 ]]; then
  ok "分支更新被拒（例如分支保護）→ 以非零結束，執行會顯示紅燈"
else
  bad "分支更新被拒時沒有失敗（rc=$RC patch=$N_PATCH）"
fi

# ── 行為的反事實：每一個都必須被上面的某條斷言抓到 ──
mutate_body() {
  # $1 = 名稱, $2 = 輸出。只改抽出來的本體副本。
  "$PY" - "$BODY" "$2" "$1" <<'PYEOF'
import sys
src, dst, name = sys.argv[1], sys.argv[2], sys.argv[3]
t = open(src, encoding='ascii').read()
def once(old, new, allow_many=False):
    global t
    n = t.count(old)
    if n == 0 or (n != 1 and not allow_many):
        sys.exit('anchor problem (%d): %r' % (n, old))
    t = t.replace(old, new)
if name == 'double-read':
    once('payload="$(jq -n',
         'head_sha="$(jq -r \'.object.sha // empty\' <<< "$(api GET "/repos/$REPO/git/ref/heads/$default_branch")")"\npayload="$(jq -n')
elif name == 'send-force':
    once("'{sha: $s}'", "'{sha: $s, force: true}'")
elif name == 'no-readback':
    once('if [[ ! "$new_sha" =~', 'if false && [[ ! "$new_sha" =~')
elif name == 'token-in-header':
    once('-H "Accept: application/vnd.github+json"',
         '-H "Accept: application/vnd.github+json" --header "Authorization: Bearer $GH_TOKEN"', allow_many=True)
else:
    sys.exit('unknown: ' + name)
open(dst, 'w', encoding='ascii', newline='\n').write(t)
PYEOF
}

mutate_body double-read "$WORK/cf1.sh" && run_case concurrent "$STALE" refs/heads/main main "$WORK/cf1.sh"
if [[ $N_VIOL -gt 0 ]]; then
  ok "反事實：分支讀兩次 → 伺服器記到「tree 與 parent 不符」（這正是會悄悄還原別人推送的那種 commit）"
else
  bad "反事實：分支讀兩次沒有被抓到（違規=$N_VIOL rc=$RC）"
fi

mutate_body send-force "$WORK/cf2.sh" && run_case normal "$STALE" refs/heads/main main "$WORK/cf2.sh"
if [[ "$FORCE" == "true" ]]; then
  ok "反事實：送出 force → 被抓到"
else
  bad "反事實：送出 force 沒有被抓到"
fi

mutate_body no-readback "$WORK/cf3.sh" && run_case tree-mismatch "$STALE" refs/heads/main main "$WORK/cf3.sh"
if [[ $N_PATCH -gt 0 ]]; then
  ok "反事實：拿掉讀回核對 → tree 不符時仍去更新分支，被抓到"
else
  bad "反事實：拿掉讀回核對沒有被抓到（patch=$N_PATCH）"
fi

mutate_body token-in-header "$WORK/cf4.sh" && run_case normal "$STALE" refs/heads/main main "$WORK/cf4.sh"
if [[ $N_TOKEN_IN_ARGV -gt 0 ]]; then
  ok "反事實：token 改用 --header 傳 → argv 紀錄裡出現 token，被抓到"
else
  bad "反事實：token 改用 --header 傳沒有被抓到"
fi

fi

if [[ $SKIPPED -gt 0 ]]; then
  echo "通過 $PASS / 失敗 $FAIL / 跳過 $SKIPPED（缺少 jq 或 node）"
else
  echo "通過 $PASS / 失敗 $FAIL"
fi
[[ $FAIL -eq 0 ]]
