// Worker 的邏輯測試。把 global fetch 換成樁，不需要真的 Cloudflare 憑證。
// 重點在兩件事：認證不能有破口，以及判定分類不能把「允許」算成「拒絕」。

import { readFileSync } from "node:fs";
import { inspect } from "node:util";
import worker from "../src/index.js";
import { APP_JS } from "../src/page.js";

let pass = 0, fail = 0;
function t(desc, got, want) {
  const g = JSON.stringify(got), w = JSON.stringify(want);
  if (g === w) { console.log("    ✓ " + desc + "：" + g); pass++; }
  else { console.log("    ✗ " + desc + "：得到 " + g + " 預期 " + w); fail++; }
}
function tt(desc, cond) {
  if (cond) { console.log("    ✓ " + desc); pass++; }
  else { console.log("    ✗ " + desc); fail++; }
}

// 測試用的假 aud。真實部署時由 wrangler.toml 的 ACCESS_AUD 決定。
const AUD = "deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef";
const baseEnv = { ACCESS_AUD: AUD, CF_API_TOKEN: "cf-token", CF_ACCOUNT_ID: "acct123" };

// ── fetch 樁：依網址分流 ─────────────────────────────────
// GraphQL 網址回可設定的列；certsRoutes 裡登記的網址（Access certs 端點、攻擊者的 JWKS）
// 交給各自的處理函式；其他網址一律當成網路錯誤。每一次 fetch 都記進 fetched，
// 測試用它確認「某個網址從未被抓取」與 certs 請求帶了哪些選項。
const GRAPHQL_URL = "https://api.cloudflare.com/client/v4/graphql";
let captured = [];
const fetched = [];
const certsRoutes = new Map();
function stubGraphQL(seriesRows, topRows) {
  captured = [];
  const routed = async (input, init = {}) => {
    const url = typeof input === "string" ? input : input instanceof Request ? input.url : String(input);
    fetched.push({ url, init });
    if (url === GRAPHQL_URL) {
      const body = JSON.parse(init.body);
      captured.push(body);
      const isSeries = /datetimeHour|datetimeFiveMinutes|datetimeFifteenMinutes|date_ASC|\bdate\b/.test(body.query)
        && !body.query.includes("queryName");
      const rows = isSeries ? seriesRows : topRows;
      return new Response(JSON.stringify({
        data: { viewer: { accounts: [{ gatewayResolverQueriesAdaptiveGroups: rows }] } },
        errors: null,
      }), { status: 200, headers: { "Content-Type": "application/json" } });
    }
    const route = certsRoutes.get(url);
    if (!route) throw new TypeError("樁：沒有登記的網址");
    const resp = await route(init);
    // 模擬 fetch 的預設行為：redirect 不是 manual（或 error）就跟著 Location 走
    if (resp.status >= 300 && resp.status < 400 && init.redirect !== "manual" && init.redirect !== "error") {
      return routed(resp.headers.get("Location"), init);
    }
    return resp;
  };
  globalThis.fetch = routed;
}

const req = (path, opts = {}) => new Request("https://dash.example.com" + path, opts);

// Worker-level Cloudflare Access 驗過的請求，執行環境會把結果放進 ctx.access；
// 沒驗過就根本沒有 ctx.access。這兩個小工具就是在模擬這兩種情況。
const ctxAud = (aud) => ({ access: { aud, email: "me@example.com" } });
const ctxNone = () => ({});

/** 已經通過本應用 Access 的請求（aud 用字串形式） */
const ok = (path, env = baseEnv) => worker.fetch(req(path), env, ctxAud(AUD));

// 樁裡塞一眼認得出的字串：只要任何一條未驗證的路徑漏出資料，
// 下面的「不含 DNS 資料」斷言就會抓到。
function stubLeakCanary() {
  stubGraphQL(
    [{ count: 1, dimensions: { datetimeHour: "2026-08-30T10:00:00Z", resolverDecision: 9 } }],
    [{ count: 1, dimensions: { queryName: "leaked-canary.example", resolverDecision: 9, policyName: "Block ads" } }],
  );
}

console.log("情境 A：沒有設定 ACCESS_AUD 時必須 fail closed");
{
  stubLeakCanary();
  const env = { CF_API_TOKEN: "x", CF_ACCOUNT_ID: "y" };

  const r = await worker.fetch(req("/"), env, ctxAud(AUD));
  t("回傳 503", r.status, 503);
  const body = await r.text();
  tt("說明要怎麼設定", body.includes("ACCESS_AUD"));
  tt("本文不含任何 DNS 資料", !body.includes("leaked-canary.example") && !body.includes("resolverDecision"));
  tt("也沒有把儀表板頁面吐出來", !body.includes("擋廣告觀測儀表板"));

  const r2 = await worker.fetch(req("/api/data?range=24h"), env, ctxAud(AUD));
  t("API 也一樣擋住", r2.status, 503);
  tt("API 回應不含任何 DNS 資料", !(await r2.text()).includes("leaked-canary.example"));

  const r3 = await worker.fetch(req("/"), { ...env, ACCESS_AUD: "" }, ctxAud(AUD));
  t("ACCESS_AUD 是空字串也算沒設定", r3.status, 503);

  // /app.js 和 / 走同一道關卡，ACCESS_AUD 沒設定時一樣什麼都不給
  const r4 = await worker.fetch(req("/app.js"), env, ctxAud(AUD));
  t("/app.js 也一樣 fail closed", r4.status, 503);
  const r5 = await worker.fetch(req("/app.js"), { ...env, ACCESS_AUD: "" }, ctxAud(AUD));
  t("ACCESS_AUD 是空字串時 /app.js 也是 503", r5.status, 503);
}

console.log("\n情境 B：Cloudflare Access 沒驗過的請求一律擋下");
{
  stubLeakCanary();

  const r = await worker.fetch(req("/"), baseEnv, ctxNone());
  t("ctx 沒有 access → / 回 403", r.status, 403);
  const body = await r.text();
  tt("說明要透過 Cloudflare Access 進入", body.includes("Cloudflare Access"));
  tt("沒有洩漏 DNS 資料", !body.includes("leaked-canary.example"));

  const r2 = await worker.fetch(req("/api/data?range=24h"), baseEnv, ctxNone());
  t("ctx 沒有 access → /api/data 回 403", r2.status, 403);
  t("API 回的是 JSON 錯誤", (await r2.json()).error, "未通過驗證");

  const r3 = await worker.fetch(req("/"), baseEnv, ctxAud("aud-of-another-app"));
  t("aud 不符 → 403", r3.status, 403);
  const r4 = await worker.fetch(req("/api/data?range=24h"), baseEnv, ctxAud("aud-of-another-app"));
  t("aud 不符的 API → 403", r4.status, 403);
  const r5 = await worker.fetch(req("/"), baseEnv, ctxAud(["aud-of-another-app"]));
  t("陣列 aud 但不含正確值 → 403", r5.status, 403);

  // 以下三條是「不可以用子字串比對」的迴歸測試 ——
  // 換成 String(aud).includes(expected) 的話，後兩條會變成 200。
  t("aud 只是正確值的前綴 → 403",
    (await worker.fetch(req("/"), baseEnv, ctxAud(AUD.slice(0, 32)))).status, 403);
  t("aud 把正確值包在裡面 → 403",
    (await worker.fetch(req("/"), baseEnv, ctxAud(AUD + "-and-more"))).status, 403);
  t("aud 陣列字串化之後含有正確值 → 403",
    (await worker.fetch(req("/"), baseEnv, ctxAud(["x", AUD + "y"]))).status, 403);

  // 認證擋在所有路由之前，其他方法與未知路徑一樣不放行
  const r6 = await worker.fetch(req("/api/data", { method: "OPTIONS" }), baseEnv, ctxNone());
  tt("未驗證的 OPTIONS /api/data 不是 200", r6.status !== 200);
  t("未驗證的 OPTIONS /api/data 回 403", r6.status, 403);
  const r7 = await worker.fetch(req("/nope"), baseEnv, ctxNone());
  tt("未驗證的未知路徑不是 200", r7.status !== 200);
  t("未驗證的未知路徑回 403 而不是 404", r7.status, 403);
  const r8 = await worker.fetch(req("/", { method: "HEAD" }), baseEnv, ctxNone());
  tt("未驗證的 HEAD 不是 200", r8.status !== 200);

  // /app.js 必須被同一道關卡涵蓋 —— 路由若被搬到關卡之前，下面四條會全部變紅
  const gqlBefore = captured.length;
  const r9 = await worker.fetch(req("/app.js"), baseEnv, ctxNone());
  t("ctx 沒有 access → /app.js 回 403", r9.status, 403);
  const body9 = await r9.text();
  tt("/app.js 的 403 本文與 / 的 403 本文逐位元組相同", body9 === body);
  tt("/app.js 未驗證時沒有吐出腳本", !body9.includes("loadStatus"));
  t("/app.js 未驗證時 GraphQL 沒有被呼叫", captured.length - gqlBefore, 0);

  const r10 = await worker.fetch(req("/app.js", { method: "HEAD" }), baseEnv, ctxNone());
  t("未驗證的 HEAD /app.js 回 403", r10.status, 403);

  const r11 = await worker.fetch(req("/app.js"), baseEnv, ctxAud("aud-of-another-app"));
  t("aud 不符的 /app.js → 403", r11.status, 403);
}

console.log("\n情境 C：通過 Cloudflare Access 之後才提供內容");
{
  stubGraphQL([], []);
  const r = await worker.fetch(req("/"), baseEnv, ctxAud(AUD));
  t("aud 字串相等 → 200", r.status, 200);
  tt("回的是儀表板頁面", (await r.text()).includes("擋廣告觀測儀表板"));

  // Access JWT 原始的 aud 是陣列，而 ctx.access.aud 的型別官方文件沒有保證，
  // 所以陣列形式一定要通 —— 這是 audMatches 的迴歸測試。
  stubGraphQL([], []);
  const r2 = await worker.fetch(req("/"), baseEnv, ctxAud(["aud-of-another-app", AUD]));
  t("aud 陣列包含正確值 → 200", r2.status, 200);

  stubGraphQL([], []);
  const r3 = await worker.fetch(req("/api/data?range=24h"), baseEnv, ctxAud(AUD));
  t("/api/data → 200", r3.status, 200);

  stubGraphQL([], []);
  const r4 = await worker.fetch(req("/api/data?range=24h"), baseEnv, ctxAud([AUD]));
  t("aud 陣列形式的 /api/data 也是 200", r4.status, 200);

  const r5 = await worker.fetch(req("/api/status"), baseEnv, ctxAud(AUD));
  t("/api/status → 200", r5.status, 200);
}

console.log("\n情境 D：判定分類 —— 未知代碼不可以被算成允許或拒絕");
{
  const series = [
    { count: 100, dimensions: { datetimeHour: "2026-08-30T10:00:00Z", resolverDecision: 5 } },
    { count: 30,  dimensions: { datetimeHour: "2026-08-30T10:00:00Z", resolverDecision: 9 } },
    { count: 20,  dimensions: { datetimeHour: "2026-08-30T10:00:00Z", resolverDecision: 10 } },
    { count: 7,   dimensions: { datetimeHour: "2026-08-30T10:00:00Z", resolverDecision: 99 } },
  ];
  stubGraphQL(series, []);
  const r = await ok("/api/data?range=24h");
  const d = await r.json();
  t("允許 = 代碼 5 + 代碼 10", d.totals.allowed, 120);
  t("拒絕 = 代碼 9", d.totals.blocked, 30);
  t("未知代碼 99 歸到其他", d.totals.other, 7);
  tt("未知代碼沒有被混進允許或拒絕", d.totals.allowed === 120 && d.totals.blocked === 30);
  t("時間桶合併成一根柱子", d.series.length, 1);
}

console.log("\n情境 E：篩選條件要正確翻成 GraphQL filter");
{
  stubGraphQL([], []);
  await ok("/api/data?range=24h&decision=blocked");
  const f = captured[0].variables.filter;
  t("僅拒絕 → resolverDecision_in=[9]", f.resolverDecision_in, [9]);

  stubGraphQL([], []);
  await ok("/api/data?range=24h&decision=allowed");
  t("僅允許 → resolverDecision_in=[5,10]", captured[0].variables.filter.resolverDecision_in, [5, 10]);

  stubGraphQL([], []);
  await ok("/api/data?range=24h&decision=all");
  tt("全部 → 不帶 resolverDecision_in", captured[0].variables.filter.resolverDecision_in === undefined);

  // 這一項是實測踩過的坑：queryName_like 不帶 % 的話永遠回 0 筆
  stubGraphQL([], []);
  await ok("/api/data?range=24h&q=doubleclick");
  t("搜尋要包成 %pattern%", captured[0].variables.filter.queryName_like, "%doubleclick%");

  stubGraphQL([], []);
  await ok("/api/data?range=1h");
  tt("1 小時用 5 分鐘分桶", captured[0].query.includes("datetimeFiveMinutes"));
  stubGraphQL([], []);
  await ok("/api/data?range=7d");
  tt("7 天用日期分桶", /dimensions \{ date resolverDecision \}/.test(captured[0].query));

  stubGraphQL([], []);
  await ok("/api/data?range=24h&range=bogus");
  tt("無效的 range 退回 24h", captured[0].query.includes("datetimeHour"));
}

console.log("\n情境 F：點選柱狀圖只縮小明細的時間範圍，趨勢圖仍是完整範圍");
{
  stubGraphQL([], []);
  await ok("/api/data?range=24h&bucket=2026-08-30T10:00:00Z");
  const seriesFilter = captured[0].variables.filter;
  const topFilter = captured[1].variables.filter;
  t("明細起點 = 被點的時間桶", topFilter.datetime_geq, "2026-08-30T10:00:00Z");
  tt("明細終點在該桶之內（未滿一小時）", topFilter.datetime_leq.startsWith("2026-08-30T10:59:59"));
  tt("趨勢圖不受時間桶影響", seriesFilter.datetime_geq !== topFilter.datetime_geq);

  stubGraphQL([], []);
  await ok("/api/data?range=24h&bucket=not-a-time");
  tt("無效的 bucket 被忽略而不是炸掉", captured[1].variables.filter.datetime_leq.length > 0);
}

console.log("\n情境 G：網域明細的合併");
{
  const top = [
    { count: 50, dimensions: { queryName: "a.com", resolverDecision: 9, policyName: "Block ads" } },
    { count: 5,  dimensions: { queryName: "a.com", resolverDecision: 5, policyName: null } },
    { count: 80, dimensions: { queryName: "b.com", resolverDecision: 5, policyName: null } },
  ];
  stubGraphQL([], top);
  const d = await (await ok("/api/data?range=24h")).json();
  const a = d.topDomains.find(x => x.domain === "a.com");
  t("同網域不同判定合併成一列", d.topDomains.length, 2);
  t("a.com 總計", a.total, 55);
  t("a.com 拒絕", a.blocked, 50);
  t("a.com 允許", a.allowed, 5);
  t("記下命中的政策", a.policies, ["Block ads"]);
  t("依總計由大到小排序", d.topDomains.map(x => x.domain), ["b.com", "a.com"]);
}

console.log("\n情境 H：GraphQL 錯誤要如實回報，不要假裝成空資料");
{
  globalThis.fetch = async () => new Response(JSON.stringify({
    data: null,
    errors: [{ message: "Authentication error" }],
  }), { status: 200, headers: { "Content-Type": "application/json" } });
  const r = await ok("/api/data?range=24h");
  t("回 500", r.status, 500);
  const j = await r.json();
  tt("帶出原始錯誤訊息", j.error.includes("Authentication error"));
}

console.log("\n情境 I：安全標頭、/app.js 與未知路徑");
{
  // CSP 整串逐字比對。收緊 script-src 的重點就是「不可以有第二個來源溜進去」，
  // 所以除了整串比對，還把 script-src 指令單獨拆出來精確比對一次。
  const CSP = "default-src 'none'; style-src 'unsafe-inline'; script-src 'self'; "
    + "connect-src 'self'; img-src data:; form-action 'self'; base-uri 'none'";
  const scriptSrcOf = (csp) => (csp || "").split(";").map((d) => d.trim()).filter((d) => /^script-src\b/.test(d));

  stubGraphQL([], []);
  const r = await ok("/");
  tt("有 X-Content-Type-Options", r.headers.get("X-Content-Type-Options") === "nosniff");
  tt("有 X-Frame-Options: DENY", r.headers.get("X-Frame-Options") === "DENY");
  tt("CSP 預設封死", (r.headers.get("Content-Security-Policy") || "").includes("default-src 'none'"));
  t("/ 的 CSP 整串逐字相符", r.headers.get("Content-Security-Policy"), CSP);
  t("/ 的 script-src 指令恰好是 script-src 'self'", scriptSrcOf(r.headers.get("Content-Security-Policy")), ["script-src 'self'"]);
  t("/ 帶 Cross-Origin-Resource-Policy: same-origin", r.headers.get("Cross-Origin-Resource-Policy"), "same-origin");
  tt("不快取", (r.headers.get("Cache-Control") || "").includes("no-store"));

  // /app.js：通過 Access 之後才拿得到，而且必須是完整的安全標頭 + JavaScript MIME
  stubGraphQL([], []);
  const ra = await ok("/app.js");
  t("有效 ctx.access → /app.js 200", ra.status, 200);
  t("/app.js 的 Content-Type 是 JavaScript MIME", ra.headers.get("Content-Type"), "text/javascript; charset=utf-8");
  const appBody = await ra.text();
  tt("/app.js 的本文與 APP_JS 完全相等", appBody === APP_JS);
  tt("/app.js 有 X-Content-Type-Options: nosniff", ra.headers.get("X-Content-Type-Options") === "nosniff");
  tt("/app.js 不快取", (ra.headers.get("Cache-Control") || "").includes("no-store"));
  t("/app.js 的 CSP 與 / 同一份", ra.headers.get("Content-Security-Policy"), CSP);
  t("/app.js 帶 Cross-Origin-Resource-Policy: same-origin", ra.headers.get("Cross-Origin-Resource-Policy"), "same-origin");

  // 非 JS 回應必須維持非 JS MIME + nosniff：script-src 收成 'self' 之後，
  // 同源的 /api/* 與錯誤回應理論上都能被當腳本指過來，nosniff 成為主要控制。
  const r2 = await ok("/nope");
  t("未知路徑 → 404", r2.status, 404);
  tt("404 JSON 有 nosniff", r2.headers.get("X-Content-Type-Options") === "nosniff");
  tt("404 的 Content-Type 以 application/json 開頭", (r2.headers.get("Content-Type") || "").startsWith("application/json"));
  t("404 帶 Cross-Origin-Resource-Policy", r2.headers.get("Cross-Origin-Resource-Policy"), "same-origin");

  globalThis.fetch = async () => new Response(JSON.stringify({
    data: null,
    errors: [{ message: "Authentication error" }],
  }), { status: 200, headers: { "Content-Type": "application/json" } });
  const r3 = await ok("/api/data?range=24h");
  t("GraphQL 失敗 → 500", r3.status, 500);
  tt("500 JSON 有 nosniff", r3.headers.get("X-Content-Type-Options") === "nosniff");
  tt("500 的 Content-Type 以 application/json 開頭", (r3.headers.get("Content-Type") || "").startsWith("application/json"));
  t("500 帶 Cross-Origin-Resource-Policy", r3.headers.get("Cross-Origin-Resource-Policy"), "same-origin");
}

console.log("\n情境 K：沒有 ctx.access 時，自行驗證 Access JWT（只在主機名清單內的入口）");
{
  // ── 工具 ──────────────────────────────────────────────
  // 只在 worker.fetch 執行期間接管所有 console 方法，呼叫結束立即還原，
  // 這樣擷取到的只有 Worker 自己的輸出，不會和 t/tt 的結果混在一起。
  const METHODS = ["log", "info", "debug", "warn", "error", "trace"];
  const show = (a) => (typeof a === "string" ? a : inspect(a, { depth: 10 }));
  const REASONS = ["bad_team_domain", "missing", "too_long", "malformed", "bad_header", "no_key", "certs_unavailable",
    "bad_signature", "bad_type", "bad_aud", "bad_iss", "expired", "not_yet_valid", "bad_iat", "error"];

  // 既有的兩個 403 本文（逐字取自修改前的 index.js）。回退路徑擋下的請求必須回位元組完全相同的本文。
  const DENY_HTML = `<h1>需要透過 Cloudflare Access 進入</h1><p>這個請求沒有經過 Cloudflare Access 驗證，或者驗證的是另一支 Access 應用。</p>
         <p>請從 Access 應用涵蓋的網址進入，並用政策允許的帳號登入。</p>`;
  const DENY_JSON = '{"error":"未通過驗證"}';

  // 假時鐘：Worker 每次呼叫時讀 Date.now()，這裡換掉它就能前進秒數
  const realDateNow = Date.now;
  let clockMs = realDateNow();
  Date.now = () => clockMs;
  const nowSec = () => Math.floor(clockMs / 1000);
  const advance = (sec) => { clockMs += sec * 1000; };

  // 金絲雀：每個都獨一無二，只要出現在任何回應本文或 console 輸出裡就是洩漏
  const EMAIL = "canary-email-2d8b@example.org", SUB = "canary-sub-71fa";
  const KID1 = "canary-kid-k1-4e7a", KID2 = "canary-kid-k2-b91d", KIDATK = "canary-kid-atk-02c5";
  const UNKNOWN_KID = "canary-kid-unknown-5f1c";

  // RSA-2048 金鑰：k1、k2 是 Access（輪替用），atk 是攻擊者
  const RSA = { name: "RSASSA-PKCS1-v1_5", modulusLength: 2048, publicExponent: new Uint8Array([1, 0, 1]), hash: "SHA-256" };
  const k1 = await crypto.subtle.generateKey(RSA, true, ["sign", "verify"]);
  const k2 = await crypto.subtle.generateKey(RSA, true, ["sign", "verify"]);
  const atk = await crypto.subtle.generateKey(RSA, true, ["sign", "verify"]);
  const jwkOf = async (kp, kid) => ({ ...(await crypto.subtle.exportKey("jwk", kp.publicKey)), kid, use: "sig" });
  const J1 = await jwkOf(k1, KID1), J2 = await jwkOf(k2, KID2), JATK = await jwkOf(atk, KIDATK);

  const b64u = (bytes) => Buffer.from(bytes).toString("base64url");
  const seg = (v) => b64u(Buffer.from(typeof v === "string" ? v : JSON.stringify(v), "utf8"));
  const minted = [];
  async function signSegs(kp, h, p) {
    const input = h + "." + p;
    const sig = await crypto.subtle.sign("RSASSA-PKCS1-v1_5", kp.privateKey, Buffer.from(input, "ascii"));
    const token = input + "." + b64u(new Uint8Array(sig));
    minted.push(token);
    return token;
  }
  // 值為 undefined 的欄位會被 JSON.stringify 省略，用來做「缺少某個 claim」
  const claimsFor = (domain, over = {}) => {
    const now = nowSec();
    return { type: "app", aud: [AUD], iss: domain, email: EMAIL, sub: SUB, iat: now, nbf: now, exp: now + 3600, ...over };
  };
  const mint = (kp, kid, domain, over = {}, hdr = {}) =>
    signSegs(kp, seg({ alg: "RS256", kid, typ: "JWT", ...hdr }), seg(claimsFor(domain, over)));

  const jsonResp = (obj, status = 200) =>
    new Response(JSON.stringify(obj), { status, headers: { "Content-Type": "application/json" } });
  const certsOf = (domain) => domain + "/cdn-cgi/access/certs";
  const countOf = (url) => fetched.filter((f) => f.url === url).length;

  // 攻擊者控制的 JWKS：任何測試都不應該讓 Worker 抓到這裡
  const ATTACKER_CERTS = "https://attacker.example/cdn-cgi/access/certs";
  const ATTACKER_TEAM = "https://attacker.cloudflareaccess.com";
  certsRoutes.set(ATTACKER_CERTS, () => jsonResp({ keys: [JATK] }));
  certsRoutes.set(certsOf(ATTACKER_TEAM), () => jsonResp({ keys: [JATK] }));

  // 每個需要乾淨快取的案例都用不同的 team domain（kN），不為測試匯出 Worker 內部函式
  let teamSeq = 0;
  function team(jwks = [J1]) {
    const domain = `https://k${++teamSeq}.cloudflareaccess.com`;
    const tm = { domain, url: certsOf(domain), mode: "ok", jwks };
    certsRoutes.set(tm.url, (init) => serveCerts(tm, init));
    tm.env = (over = {}) => ({ ...baseEnv, ACCESS_TEAM_DOMAIN: domain, ACCESS_JWT_HOSTNAMES: "dash.example.com", ...over });
    tm.count = () => countOf(tm.url);
    return tm;
  }
  function serveCerts(tm, init) {
    switch (tm.mode) {
      case "ok": return jsonResp({ keys: tm.jwks });
      case "500": return new Response("upstream error", { status: 500 });
      case "not-json": return new Response("<html>not json</html>", { status: 200, headers: { "Content-Type": "text/html" } });
      case "no-keys": return jsonResp({ public_cert: { kid: KID1 } });
      case "no-usable": return jsonResp({ keys: [{ ...J1, kty: "EC" }, { ...J1, alg: "HS256" }, { ...J1, use: "enc" }, { ...J1, n: 5 }, { kid: KID1 }] });
      case "throw": throw new TypeError("network down");
      case "302": return new Response(null, { status: 302, headers: { Location: ATTACKER_CERTS } });
      case "abort": return new Promise((_, reject) => {
        if (!(init.signal instanceof AbortSignal)) return reject(new TypeError("樁：沒有 signal"));
        if (init.signal.aborted) return reject(init.signal.reason);
        init.signal.addEventListener("abort", () => reject(init.signal.reason), { once: true });
      });
    }
    throw new Error("樁：未知模式");
  }

  const allLines = [], allBodies = [];
  async function call(path, { env, ctx = ctxNone(), token, headers = {}, method, request } = {}) {
    const h = { ...headers };
    if (token !== undefined) h["Cf-Access-Jwt-Assertion"] = token;
    const r = request || req(path, { method, headers: h });
    const gqlBefore = captured.length, fetchBefore = fetched.length;
    const saved = {}, lines = [];
    for (const m of METHODS) { saved[m] = console[m]; console[m] = (...a) => lines.push({ m, text: a.map(show).join(" ") }); }
    let resp = null, threw = null;
    try { resp = await worker.fetch(r, env, ctx); }
    catch (e) { threw = e; }
    finally { for (const m of METHODS) console[m] = saved[m]; }
    const body = resp ? await resp.text() : null;
    allLines.push(...lines);
    if (body !== null) allBodies.push(body);
    let reason = null;
    if (lines.length === 1) { try { reason = JSON.parse(lines[0].text).accessJwt ?? null; } catch {} }
    return { status: resp ? resp.status : null, body, threw, lines, reason,
      gql: captured.length - gqlBefore, fetches: fetched.slice(fetchBefore) };
  }
  // 被擋下的請求：不拋例外、403、本文與既有 403 位元組相同、GraphQL 沒有被呼叫
  function denied(name, c, api = false) {
    t(`${name} → [不拋例外, 403, 本文與既有${api ? " JSON" : " HTML"} 403 位元組相同, GraphQL 呼叫次數]`,
      [c.threw === null, c.status, c.body === (api ? DENY_JSON : DENY_HTML), c.gql], [true, 403, true, 0]);
  }

  stubLeakCanary();

  console.log("  K1：有效 token");
  {
    const tm = team();
    const cRoot = await call("/", { env: tm.env(), token: await mint(k1, KID1, tm.domain) });
    t("K1 / → [不拋例外, 200, console 輸出行數]", [cRoot.threw === null, cRoot.status, cRoot.lines.length], [true, 200, 0]);
    tt("K1 / 回的是儀表板頁面", (cRoot.body || "").includes("擋廣告觀測儀表板"));
    const cStatus = await call("/api/status", { env: tm.env(), token: await mint(k1, KID1, tm.domain) });
    t("K1 /api/status → [200, console 輸出行數]", [cStatus.status, cStatus.lines.length], [200, 0]);
    const cData = await call("/api/data?range=24h", { env: tm.env(), token: await mint(k1, KID1, tm.domain) });
    t("K1 /api/data → [200, GraphQL 呼叫次數, console 輸出行數]", [cData.status, cData.gql, cData.lines.length], [200, 2, 0]);
    const cStr = await call("/", { env: tm.env(), token: await mint(k1, KID1, tm.domain, { aud: AUD }) });
    t("K1 aud 為字串形式 → 200", cStr.status, 200);
    t("K1 同一個 team domain 只抓 1 次 certs", tm.count(), 1);
  }

  console.log("  K2：有 ctx.access 且 aud 相符");
  {
    const tm = team();
    const c = await call("/", { env: tm.env(), ctx: ctxAud(AUD), token: await mint(k1, KID1, tm.domain) });
    t("K2 → [200, certs 抓取次數, console 輸出行數]", [c.status, tm.count(), c.lines.length], [200, 0, 0]);
    const c2 = await call("/", { env: tm.env(), ctx: ctxAud(AUD), token: "not-a-jwt" });
    t("K2 token 無效也不影響 ctx.access 的判斷 → [200, certs 抓取次數]", [c2.status, tm.count()], [200, 0]);
  }

  console.log("  K3：有 ctx.access 但 aud 不符或是假值，即使帶有效 token 也不回退");
  for (const [label, aud] of [["不符字串", "aud-of-another-app"], ["undefined", undefined], ["null", null], ["空字串", ""]]) {
    const tm = team();
    for (const path of ["/", "/api/data?range=24h"]) {
      const api = path.startsWith("/api/");
      const c = await call(path, { env: tm.env(), ctx: { access: { aud, email: EMAIL } }, token: await mint(k1, KID1, tm.domain) });
      denied(`K3 ctx.access.aud ${label} ${path}`, c, api);
      t(`K3 ctx.access.aud ${label} ${path} [certs 抓取次數, console 輸出行數]`, [tm.count(), c.lines.length], [0, 0]);
    }
  }

  console.log("  K4：啟用條件");
  {
    const badDomains = [
      ["未設定", undefined, null], ["空字串", "", null],
      ["http://", "http://k4a.cloudflareaccess.com", "bad_team_domain"],
      ["結尾斜線", "https://k4b.cloudflareaccess.com/", "bad_team_domain"],
      ["大寫", "https://K4C.cloudflareaccess.com", "bad_team_domain"],
      ["帶路徑", "https://k4d.cloudflareaccess.com/x", "bad_team_domain"],
      ["帶埠", "https://k4e.cloudflareaccess.com:443", "bad_team_domain"],
      ["別的網域", "https://evil.example.com", "bad_team_domain"],
      ["後綴偽裝", "https://x.cloudflareaccess.com.evil.com", "bad_team_domain"],
    ];
    for (const [label, domain, reason] of badDomains) {
      // 樁在這些網址也提供 k1：少了格式檢查的話，Worker 會真的抓到金鑰並放行
      if (domain) certsRoutes.set(certsOf(domain), () => jsonResp({ keys: [J1] }));
      const env = { ...baseEnv, ACCESS_JWT_HOSTNAMES: "dash.example.com" };
      if (domain !== undefined) env.ACCESS_TEAM_DOMAIN = domain;
      const c = await call("/", { env, token: await mint(k1, KID1, domain || "https://k4z.cloudflareaccess.com") });
      denied(`K4 ACCESS_TEAM_DOMAIN ${label}`, c);
      t(`K4 ACCESS_TEAM_DOMAIN ${label} [fetch 次數, 紀錄]`, [c.fetches.length, c.reason], [0, reason]);
    }

    const tm = team();
    const hostCases = [
      ["未設定", undefined], ["空字串", ""], ["不含請求主機名", "other.example.com"],
      ["只含父網域（子字串）", "example.com"], ["請求主機名是它的子字串", "notdash.example.com"],
      ["帶埠", "dash.example.com:443"],
    ];
    for (const [label, hosts] of hostCases) {
      const env = tm.env();
      if (hosts === undefined) delete env.ACCESS_JWT_HOSTNAMES; else env.ACCESS_JWT_HOSTNAMES = hosts;
      const c = await call("/", { env, token: await mint(k1, KID1, tm.domain) });
      denied(`K4 ACCESS_JWT_HOSTNAMES ${label}`, c);
      t(`K4 ACCESS_JWT_HOSTNAMES ${label} [fetch 次數, console 輸出行數]`, [c.fetches.length, c.lines.length], [0, 0]);
    }
    const cOk = await call("/", { env: tm.env({ ACCESS_JWT_HOSTNAMES: " other.example.com , DASH.Example.com " }), token: await mint(k1, KID1, tm.domain) });
    t("K4 對照組：清單去空白、轉小寫後含請求主機名 → 200", cOk.status, 200);
  }

  console.log("  K5：簽章與 header");
  {
    const tm = team();
    const env = tm.env();
    const good = await mint(k1, KID1, tm.domain);
    const [gh, , gs] = good.split(".");
    const hsInput = seg({ alg: "HS256", kid: KID1, typ: "JWT" }) + "." + seg(claimsFor(tm.domain));
    const hmacKey = await crypto.subtle.importKey("raw", Buffer.from(J1.n, "utf8"), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
    const hs256 = hsInput + "." + b64u(new Uint8Array(await crypto.subtle.sign("HMAC", hmacKey, Buffer.from(hsInput, "ascii"))));
    minted.push(hs256);
    const noneInput = seg({ alg: "none", kid: KID1, typ: "JWT" }) + "." + seg(claimsFor(tm.domain));
    const cases = [
      ["簽後竄改 payload", gh + "." + seg(claimsFor(tm.domain, { email: "someone-else@example.org" })) + "." + gs, "bad_signature"],
      ["atk 簽但用 k1 的 kid", await mint(atk, KID1, tm.domain), "bad_signature"],
      // 用 k1 簽、kid 不存在：只要 Worker 不比對 kid、拿第一把金鑰驗，這條就會變成 200
      ["kid 不存在（k1 簽）", await mint(k1, UNKNOWN_KID, tm.domain), "no_key"],
      ["alg none、無簽章", noneInput + ".", "malformed"],
      ["alg none、有假簽章", noneInput + ".AAAA", "bad_header"],
      ["alg HS256、以 k1 公鑰 n 當 HMAC 金鑰", hs256, "bad_header"],
      ["缺 kid", await mint(k1, undefined, tm.domain), "bad_header"],
      ["含 crit", await mint(k1, KID1, tm.domain, {}, { crit: ["exp"] }), "bad_header"],
      ["jku 指向攻擊者 JWKS（atk 簽）", await mint(atk, KIDATK, tm.domain, {}, { jku: ATTACKER_CERTS }), "no_key"],
      ["x5u 指向攻擊者 JWKS（atk 簽）", await mint(atk, KIDATK, tm.domain, {}, { x5u: ATTACKER_CERTS }), "no_key"],
      ["jwk 內嵌攻擊者公鑰（atk 簽）", await mint(atk, KIDATK, tm.domain, {}, { jwk: JATK }), "no_key"],
    ];
    for (const [label, token, reason] of cases) {
      const c = await call("/", { env, token });
      denied(`K5 ${label}`, c);
      t(`K5 ${label} 紀錄`, c.reason, reason);
    }
    t("K5 攻擊者網址從未被抓取", countOf(ATTACKER_CERTS), 0);
    t("K5 對照組：同一個 team domain 的有效 token → 200", (await call("/", { env, token: good })).status, 200);
  }

  console.log("  K6：certs 網址不可以取自 token 的 iss");
  {
    const tm = team();
    const c = await call("/", { env: tm.env(), token: await mint(atk, KIDATK, ATTACKER_TEAM) });
    denied("K6 iss 為攻擊者 team domain、atk 簽", c);
    t("K6 攻擊者 team domain 的 certs 從未被抓取", countOf(certsOf(ATTACKER_TEAM)), 0);
  }

  console.log("  K7：claims");
  {
    const tm = team();
    const cases = [
      ["type 缺少", { type: undefined }, "bad_type"],
      ["type 為 org", { type: "org" }, "bad_type"],
      ["aud 為別的應用", { aud: ["aud-of-another-app"] }, "bad_aud"],
      ["aud 為 x+AUD", { aud: "x" + AUD }, "bad_aud"],
      ["aud 陣列不含本應用", { aud: ["x", AUD + "y"] }, "bad_aud"],
      ["iss 為別的 team", { iss: "https://other.cloudflareaccess.com" }, "bad_iss"],
      ["iss 多結尾斜線", { iss: tm.domain + "/" }, "bad_iss"],
      ["exp 缺少", { exp: undefined }, "expired"],
      ["exp 為字串", { exp: String(nowSec() + 3600) }, "expired"],
      ["nbf 為字串", { nbf: String(nowSec()) }, "not_yet_valid"],
      ["iat 為字串", { iat: String(nowSec()) }, "bad_iat"],
    ];
    for (const [label, over, reason] of cases) {
      const c = await call("/api/data?range=24h", { env: tm.env(), token: await mint(k1, KID1, tm.domain, over) });
      denied(`K7 ${label}`, c, true);
      t(`K7 ${label} 紀錄`, c.reason, reason);
    }
  }

  console.log("  K8：時鐘誤差邊界（60 秒）");
  {
    const tm = team();
    const cases = [
      ["exp = now−30", { exp: nowSec() - 30 }, 200],
      ["exp = now−90", { exp: nowSec() - 90 }, 403],
      ["nbf = now+30", { nbf: nowSec() + 30 }, 200],
      ["nbf = now+90", { nbf: nowSec() + 90 }, 403],
      ["iat = now+30", { iat: nowSec() + 30 }, 200],
      ["iat = now+90", { iat: nowSec() + 90 }, 403],
    ];
    for (const [label, over, want] of cases) {
      const c = await call("/", { env: tm.env(), token: await mint(k1, KID1, tm.domain, over) });
      t(`K8 ${label}`, c.status, want);
      if (want === 403) denied(`K8 ${label}`, c);
    }
  }

  console.log("  K9：格式");
  {
    const tm = team();
    const good = await mint(k1, KID1, tm.domain);
    const [gh, gp, gs] = good.split(".");
    // 長度剛好 N 的有效 token：調整 header 與 payload 裡的填充欄位，簽章長度固定 342
    async function mintLength(target) {
      for (let a = 0; a < 4; a++) {
        const h = seg({ alg: "RS256", kid: KID1, typ: "JWT", x: "y".repeat(a) });
        for (let b = 0; ; b++) {
          const p = seg(claimsFor(tm.domain, { pad: "z".repeat(b) }));
          const len = h.length + 1 + p.length + 1 + 342;
          if (len === target) return signSegs(k1, h, p);
          if (len > target) break;
        }
      }
      throw new Error("找不到長度剛好的 token");
    }
    const len8192 = await mintLength(8192), len8193 = await mintLength(8193);
    t("K9 測試 token 長度正確", [len8192.length, len8193.length], [8192, 8193]);
    t("K9 對照組：長度 8192 的有效 token → 200", (await call("/", { env: tm.env(), token: len8192 })).status, 200);

    let mod1 = gp;
    while (mod1.length % 4 !== 1) mod1 += "A";
    const notUtf8 = b64u(Uint8Array.from([0x7b, 0x22, 0xff, 0xfe, 0x22, 0x3a, 0x31, 0x7d]));   // {"\xff\xfe":1}
    const cases = [
      ["只有 2 段", gh + "." + gp, "malformed"],
      ["4 段", good + "." + gs, "malformed"],
      ["非法字元 +", gh + "." + gp + "." + gs.slice(0, -1) + "+", "malformed"],
      ["非法字元 =", good + "=", "malformed"],
      ["空的段", gh + ".." + gs, "malformed"],
      ["某段 length%4==1", await signSegs(k1, gh, mod1), "malformed"],
      ["長度 8193", len8193, "too_long"],
      ["payload 為 null", await signSegs(k1, gh, seg("null")), "malformed"],
      ["payload 為陣列", await signSegs(k1, gh, seg("[]")), "malformed"],
      ["payload 為字串", await signSegs(k1, gh, seg('"str"')), "malformed"],
      ["header 非 JSON", await signSegs(k1, seg("not json"), gp), "malformed"],
      ["payload 非 UTF-8 位元組", await signSegs(k1, gh, notUtf8), "malformed"],
      ["header 非 UTF-8 位元組", await signSegs(k1, notUtf8, gp), "malformed"],
      ["空標頭", "", "malformed"],
    ];
    for (const [label, token, reason] of cases) {
      const c = await call("/", { env: tm.env(), token });
      denied(`K9 ${label}`, c);
      t(`K9 ${label} 紀錄`, c.reason, reason);
    }
    // 讀標頭會拋錯的請求：verifyAccessJwt 必須接住，記 error，不讓 Worker 炸掉
    const badReq = { url: "https://dash.example.com/", method: "GET", headers: { get() { throw new Error("boom"); }, has() { throw new Error("boom"); } } };
    const cBad = await call("/", { env: tm.env(), request: badReq });
    denied("K9 讀標頭拋錯", cBad);
    t("K9 讀標頭拋錯 紀錄", cBad.reason, "error");
  }

  console.log("  K10：只有 cookie、沒有標頭");
  {
    const tm = team();
    const token = await mint(k1, KID1, tm.domain);
    const c = await call("/", { env: tm.env(), headers: { Cookie: `other=1; CF_Authorization=${token}` } });
    denied("K10 有效 token 只放在 CF_Authorization cookie", c);
    t("K10 [紀錄, certs 抓取次數]", [c.reason, tm.count()], ["missing", 0]);
  }

  console.log("  K11：certs 端點失敗");
  {
    for (const mode of ["500", "not-json", "no-keys", "no-usable", "throw", "302", "abort"]) {
      const tm = team();
      tm.mode = mode;
      const token1 = await mint(k1, KID1, tm.domain);
      // abort：把 setTimeout 的延遲縮成 0，確認是 Worker 自己設的逾時觸發了中止（並記下它要求的延遲）
      const realSetTimeout = globalThis.setTimeout;
      const delays = [];
      if (mode === "abort") globalThis.setTimeout = (fn, ms, ...rest) => { delays.push(ms); return realSetTimeout(fn, 0, ...rest); };
      let c1;
      try { c1 = await call("/", { env: tm.env(), token: token1 }); }
      finally { globalThis.setTimeout = realSetTimeout; }
      denied(`K11 ${mode} 第 1 次`, c1);
      t(`K11 ${mode} 第 1 次 紀錄`, c1.reason, "certs_unavailable");
      if (mode === "abort") t("K11 abort 逾時由 Worker 以 5000 毫秒設定", delays, [5000]);

      const c2 = await call("/api/data?range=24h", { env: tm.env(), token: await mint(k1, KID1, tm.domain) });
      denied(`K11 ${mode} 60 秒內第 2 次`, c2, true);
      t(`K11 ${mode} 60 秒內 [紀錄, certs 抓取次數]`, [c2.reason, tm.count()], ["certs_unavailable", 1]);

      advance(61);
      tm.mode = "ok";
      const c3 = await call("/", { env: tm.env(), token: await mint(k1, KID1, tm.domain) });
      t(`K11 ${mode} 時鐘 +61 秒且樁恢復 → [200, certs 抓取次數]`, [c3.status, tm.count()], [200, 2]);
    }
    t("K11 302 的 Location（攻擊者 JWKS）從未被抓取", countOf(ATTACKER_CERTS), 0);
    // 到這裡為止（K1–K11）每一次 certs fetch 的選項：redirect 必須是 manual、必須帶 AbortSignal
    const certsInits = fetched.filter((f) => f.url.endsWith("/cdn-cgi/access/certs"));
    tt(`K11 至少檢查了 20 次 certs fetch（${certsInits.length} 次）`, certsInits.length >= 20);
    t("K11 每次 certs fetch 的 init 都含 redirect: \"manual\" 與 signal（列出不符的次數）",
      certsInits.filter((f) => !(f.init.redirect === "manual" && f.init.signal instanceof AbortSignal)).length, 0);
  }

  console.log("  K12：快取與輪替");
  {
    const tA = team();
    for (let i = 1; i <= 3; i++) {
      t(`K12(a) 第 ${i} 個有效請求 → 200`, (await call("/", { env: tA.env(), token: await mint(k1, KID1, tA.domain) })).status, 200);
    }
    t("K12(a) 3 個有效請求只抓 1 次", tA.count(), 1);
    advance(601);
    const cb = await call("/", { env: tA.env(), token: await mint(k1, KID1, tA.domain) });
    t("K12(b) 時鐘 +601 秒 → [200, certs 抓取次數]", [cb.status, tA.count()], [200, 2]);

    // (c) 快取 [k1]，Access 輪替加入 k2；距上次嘗試滿 60 秒後，未知 kid 觸發重抓
    const tC = team([J1]);
    t("K12(c) 先建立快取 [k1] → 200", (await call("/", { env: tC.env(), token: await mint(k1, KID1, tC.domain) })).status, 200);
    tC.jwks = [J1, J2];
    advance(61);
    const cc = await call("/", { env: tC.env(), token: await mint(k2, KID2, tC.domain) });
    t("K12(c) token 用 k2 → 重抓得 [k1,k2] → [200, certs 抓取次數]", [cc.status, tC.count()], [200, 2]);

    // (d) 快取 [k1,k2]，過期後重抓只剩 [k2]：整組取代，k1 不能留下來
    const tD = team([J1, J2]);
    t("K12(d) 先建立快取 [k1,k2] → 200", (await call("/", { env: tD.env(), token: await mint(k1, KID1, tD.domain) })).status, 200);
    tD.jwks = [J2];
    advance(601);
    const cd1 = await call("/", { env: tD.env(), token: await mint(k1, KID1, tD.domain) });
    denied("K12(d) 過期後重抓得 [k2]、token 用 k1", cd1);
    t("K12(d) token 用 k1 [紀錄, certs 抓取次數]", [cd1.reason, tD.count()], ["no_key", 2]);
    const cd2 = await call("/", { env: tD.env(), token: await mint(k2, KID2, tD.domain) });
    t("K12(d) 同時段 token 用 k2 → [200, certs 抓取次數]", [cd2.status, tD.count()], [200, 2]);

    // (e) 快取有效、未知 kid 連續 5 次 → 60 秒內只重抓 1 次
    const tE = team([J1]);
    t("K12(e) 先建立快取 [k1] → 200", (await call("/", { env: tE.env(), token: await mint(k1, KID1, tE.domain) })).status, 200);
    advance(61);
    for (let i = 1; i <= 5; i++) {
      const c = await call("/", { env: tE.env(), token: await mint(k1, UNKNOWN_KID, tE.domain) });
      denied(`K12(e) 未知 kid 第 ${i} 次`, c);
    }
    t("K12(e) 未知 kid 連續 5 次只重抓 1 次", tE.count(), 2);
    t("K12(e) 之後已知 kid 仍 200、不再抓", [(await call("/", { env: tE.env(), token: await mint(k1, KID1, tE.domain) })).status, tE.count()], [200, 2]);
  }

  console.log("  K13：路由涵蓋（回退啟用、token 無效或缺少）");
  {
    const tm = team();
    const invalid = await mint(atk, KID1, tm.domain);
    const cases = [
      ["OPTIONS /api/data、token 無效", "/api/data", "OPTIONS", invalid, true],
      ["OPTIONS /api/data、沒有 token", "/api/data", "OPTIONS", undefined, true],
      ["HEAD /、token 無效", "/", "HEAD", invalid, false],
      ["HEAD /、沒有 token", "/", "HEAD", undefined, false],
      ["未知路徑、token 無效", "/nope", "GET", invalid, false],
      ["未知路徑、沒有 token", "/nope", "GET", undefined, false],
    ];
    for (const [label, path, method, token, api] of cases) {
      denied(`K13 ${label}`, await call(path, { env: tm.env(), method, token }), api);
    }

    // /app.js 在回退路徑上也必須被同一道關卡涵蓋
    const cNoToken = await call("/app.js", { env: tm.env() });
    denied("K13 /app.js、沒有 token", cNoToken);
    t("K13 /app.js、沒有 token 紀錄", cNoToken.reason, "missing");

    const cHead = await call("/app.js", { env: tm.env(), method: "HEAD" });
    denied("K13 HEAD /app.js、沒有 token", cHead);

    // 簽章有效、但 aud 是別支應用的 token：同一個 team domain 底下共用簽章金鑰，
    // 少了 aud 相等比對的話這條會變成 200。
    const cBadAud = await call("/app.js", { env: tm.env(), token: await mint(k1, KID1, tm.domain, { aud: ["aud-of-another-app"] }) });
    denied("K13 /app.js、有效簽章但 aud 不符", cBadAud);
    t("K13 /app.js、aud 不符 紀錄", cBadAud.reason, "bad_aud");

    const cOk = await call("/app.js", { env: tm.env(), token: await mint(k1, KID1, tm.domain) });
    t("K13 /app.js、有效 token → [不拋例外, 200]", [cOk.threw === null, cOk.status], [true, 200]);
    tt("K13 /app.js 本文與 APP_JS 完全相等", cOk.body === APP_JS);

    const cAudEmpty = await call("/app.js", { env: tm.env({ ACCESS_AUD: "" }), token: await mint(k1, KID1, tm.domain) });
    t("K13 /app.js、ACCESS_AUD 空 → 503", cAudEmpty.status, 503);
  }

  console.log("  K14：ACCESS_AUD 的 503 在回退之前");
  {
    const tm = team();
    const c = await call("/", { env: tm.env({ ACCESS_AUD: "" }), token: await mint(k1, KID1, tm.domain) });
    t("K14 ACCESS_AUD 空 + 回退設定齊全 + 有效 token → [503, certs 抓取次數, console 輸出行數]", [c.status, tm.count(), c.lines.length], [503, 0, 0]);
  }

  console.log("  K15：不外洩");
  {
    const out = allLines.map((l) => l.text).join("\n");
    const bodies = allBodies.join("\n");
    const leaks = (v) => out.includes(v) || bodies.includes(v);
    const canaries = { EMAIL, SUB, KID1, KID2, KIDATK, UNKNOWN_KID, "team domain（cloudflareaccess.com）": "cloudflareaccess.com", ATTACKER_CERTS };
    for (const [k, v] of Object.entries(canaries)) tt(`K15 回應本文與 console 輸出不含 ${k}`, !leaks(v));
    t("K15 不含任何 token（列出外洩數）", minted.filter(leaks).length, 0);
    const segs = [...new Set(minted.flatMap((tok) => tok.split(".")).filter((s) => s.length >= 16))];
    t("K15 不含任何 token 片段（長度 ≥ 16，列出外洩數）", segs.filter(leaks).length, 0);
    tt(`K15 檢查了足夠多的 token 與片段（${minted.length} 個 token、${segs.length} 個片段）`, minted.length >= 80 && segs.length >= 100);
    const LINE = new RegExp(`^\\{"accessJwt":"(${REASONS.join("|")})"\\}$`);
    t("K15 console 輸出行只能是 console.log 的 {\"accessJwt\":\"<列舉值>\"}（列出不符的行數）",
      allLines.filter((l) => !(l.m === "log" && LINE.test(l.text))).length, 0);
    tt(`K15 擷取到的輸出與本文不是空集合（${allLines.length} 行、${allBodies.length} 個本文）`, allLines.length >= 50 && allBodies.length >= 100);
  }

  console.log("  K16：原始碼");
  {
    const src = readFileSync(new URL("../src/index.js", import.meta.url), "utf8");
    for (const [label, re] of [
      ["accessDiag", /accessDiag/], ["logAccessDiag", /logAccessDiag/], ["jwtPayloadAudMatch", /jwtPayloadAudMatch/],
      ["AbortSignal.timeout", /AbortSignal\s*\.\s*timeout/],
      ['redirect: "error"', /redirect\s*:\s*["'`]error/], ['redirect: "follow"', /redirect\s*:\s*["'`]follow/],
    ]) tt(`K16 index.js 不含 ${label}`, !re.test(src));
    // 這個 regex 也會比對到註解裡的 "import" 字樣，所以 index.js 的註解刻意不使用那個字
    t("K16 index.js 的 import 只有既有的 ./page.js", src.match(/\bimport\b[^\r\n]*/g), ['import { PAGE, APP_JS } from "./page.js";']);
  }

  Date.now = realDateNow;
}

console.log("\n通過 " + pass + " 項，失敗 " + fail + " 項");
process.exit(fail ? 1 : 0);
