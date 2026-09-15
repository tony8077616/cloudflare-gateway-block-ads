// Worker 的邏輯測試。把 global fetch 換成樁，不需要真的 Cloudflare 憑證。
// 重點在兩件事：認證不能有破口，以及判定分類不能把「允許」算成「拒絕」。

import { inspect } from "node:util";
import worker from "../src/index.js";

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

// ── GraphQL 樁 ───────────────────────────────────────────
let captured = [];
function stubGraphQL(seriesRows, topRows) {
  captured = [];
  globalThis.fetch = async (url, init) => {
    const body = JSON.parse(init.body);
    captured.push(body);
    const isSeries = /datetimeHour|datetimeFiveMinutes|datetimeFifteenMinutes|date_ASC|\bdate\b/.test(body.query)
      && !body.query.includes("queryName");
    const rows = isSeries ? seriesRows : topRows;
    return new Response(JSON.stringify({
      data: { viewer: { accounts: [{ gatewayResolverQueriesAdaptiveGroups: rows }] } },
      errors: null,
    }), { status: 200, headers: { "Content-Type": "application/json" } });
  };
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

console.log("\n情境 I：安全標頭與未知路徑");
{
  stubGraphQL([], []);
  const r = await ok("/");
  tt("有 X-Content-Type-Options", r.headers.get("X-Content-Type-Options") === "nosniff");
  tt("有 X-Frame-Options: DENY", r.headers.get("X-Frame-Options") === "DENY");
  tt("CSP 預設封死", (r.headers.get("Content-Security-Policy") || "").includes("default-src 'none'"));
  tt("不快取", (r.headers.get("Cache-Control") || "").includes("no-store"));
  const r2 = await ok("/nope");
  t("未知路徑 → 404", r2.status, 404);
}

console.log("\n情境 J：暫時性診斷紀錄 —— 只記白名單是非值，且不參與授權");
{
  // 只在 worker.fetch 執行期間接管所有 console 方法，呼叫結束立即還原，
  // 這樣擷取到的只有 Worker 自己的輸出，不會和 t/tt 的結果混在一起。
  const METHODS = ["log", "info", "debug", "warn", "error", "trace"];
  const show = (a) => (typeof a === "string" ? a : inspect(a, { depth: 10 }));
  async function capture(request, env, ctx) {
    const saved = {}, lines = [];
    for (const m of METHODS) { saved[m] = console[m]; console[m] = (...a) => lines.push({ m, text: a.map(show).join(" ") }); }
    let resp = null, threw = null;
    try { resp = await worker.fetch(request, env, ctx); }
    catch (e) { threw = e; }
    finally { for (const m of METHODS) console[m] = saved[m]; }
    return { resp, threw, lines };
  }
  const diagOf = (c) => { try { return JSON.parse(c.lines[0].text).accessDiag; } catch { return null; } };
  const runs = [];           // J9 要逐一檢查的請求（不含 J8）
  const keep = (name, c) => { runs.push({ name, c }); return c; };

  // 金絲雀：每個都獨一無二，只要出現在任何 console 輸出裡就是洩漏
  const EMAIL = "canary-email-7f3a@example.org", SUB = "canary-sub-9c1e";
  const COOKIE_VAL = "canary-cookie-3a9d", SIG = "canary-sig-6b0c";
  const env = { ACCESS_AUD: AUD, CF_API_TOKEN: "canary-token-5d2b", CF_ACCOUNT_ID: "canary-acct-8e4f" };

  const b64u = (s) => Buffer.from(s, "utf8").toString("base64").replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
  const HDR = b64u(JSON.stringify({ alg: "RS256", typ: "JWT" }));
  const jwtOf = (payloadJson) => HDR + "." + b64u(payloadJson) + "." + SIG;
  // J4／J5 的 payload：pad 字串是為了讓編碼後同時含 - 與 _，且原始 base64 需要補位
  const P_OWN = JSON.stringify({ aud: [AUD], email: EMAIL, sub: SUB, pad: "~~~???~~~???~~" });
  const P_OTHER = [
    JSON.stringify({ aud: "aud-of-another-app", pad: "~~~???~~~???~" }),
    JSON.stringify({ aud: AUD + "x", pad: "~~~???~~~???~~" }),
    JSON.stringify({ aud: ["x", AUD + "y"], pad: "~~~???~~~???~~" }),
  ];
  for (const [i, p] of [P_OWN, ...P_OTHER].entries()) {
    const raw = Buffer.from(p, "utf8").toString("base64");
    tt(`測試 payload #${i} 編碼後含 - 與 _、且需要補位（不成立請調整 pad 字串）`,
      b64u(p).includes("-") && b64u(p).includes("_") && raw.endsWith("="));
  }
  const JWT = jwtOf(P_OWN);
  const authHeaders = {
    "Cf-Access-Jwt-Assertion": JWT,
    "Cf-Access-Authenticated-User-Email": EMAIL,
    Cookie: `other=1; CF_Authorization=${COOKIE_VAL}`,
  };

  // J1
  stubGraphQL([], []);
  const c1 = keep("J1", await capture(req("/"), env, ctxNone()));
  t("J1 無 ctx.access、無標頭 → 403", c1.resp?.status, 403);
  const d1 = diagOf(c1) || {};
  t("J1 診斷欄位", [d1.passed, d1.hasCtxAccess, d1.ctxAudType, d1.hasGetIdentity, d1.hasJwtHeader, d1.jwtAudMatch,
    d1.hasAuthEmailHeader, d1.hasAuthCookie, d1.route, d1.method],
    [false, false, "none", false, false, "absent", false, false, "root", "GET"]);

  // J2
  let identityCalled = false;
  const ctx2 = { access: { aud: AUD, email: EMAIL, getIdentity: () => { identityCalled = true; return Promise.resolve({ email: EMAIL, sub: SUB }); } } };
  const c2 = keep("J2", await capture(req("/api/status?q=canary-query", { headers: authHeaders }), env, ctx2));
  t("J2 本應用 ctx.access → /api/status 200", c2.resp?.status, 200);
  const d2 = diagOf(c2) || {};
  t("J2 診斷欄位", [d2.passed, d2.ctxAudType, d2.ctxAudMatch, d2.hasGetIdentity, d2.route], [true, "string", true, true, "api"]);
  tt("J2 getIdentity 沒有被呼叫", !identityCalled);

  // J3
  const c3a = keep("J3 陣列", await capture(req("/"), env, ctxAud([AUD])));
  t("J3 aud 陣列 → ctxAudType/passed", [c3a.resp?.status, diagOf(c3a)?.ctxAudType, diagOf(c3a)?.passed], [200, "array", true]);
  const c3b = keep("J3 缺 aud", await capture(req("/"), env, { access: {} }));
  t("J3 ctx.access 沒有 aud → 403、missing", [c3b.resp?.status, diagOf(c3b)?.ctxAudType], [403, "missing"]);

  // J4／J4b：本應用的未驗簽 JWT 無論有沒有（別的應用的）ctx.access 都不能放行
  for (const [label, mkCtx] of [["J4", ctxNone], ["J4b", () => ctxAud("aud-of-another-app")]]) {
    for (const path of ["/?q=canary-query", "/api/data?range=24h&q=canary-query"]) {
      stubLeakCanary();
      const c = keep(`${label} ${path}`, await capture(req(path, { headers: authHeaders }), env, mkCtx()));
      t(`${label} ${path} 帶本應用 JWT 仍然 403`, c.resp?.status, 403);
      const d = diagOf(c) || {};
      t(`${label} ${path} 診斷欄位`, [d.hasJwtHeader, d.jwtAudMatch, d.hasAuthCookie, d.hasAuthEmailHeader, d.passed],
        [true, true, true, true, false]);
      tt(`${label} ${path} GraphQL 樁沒有被呼叫`, captured.length === 0);
      tt(`${label} ${path} 本文不含 DNS 資料`, !(c.resp ? await c.resp.text() : "leaked-canary.example").includes("leaked-canary.example"));
    }
  }

  // J5：別的應用的 JWT，或只是字串上「包含」本應用 aud 的，一律 false
  for (const [i, p] of P_OTHER.entries()) {
    const c = keep(`J5 #${i}`, await capture(req("/", { headers: { "Cf-Access-Jwt-Assertion": jwtOf(p) } }), env, ctxNone()));
    t(`J5 #${i} 403、jwtAudMatch=false`, [c.resp?.status, diagOf(c)?.jwtAudMatch], [403, false]);
  }

  // J6：解不開的標頭
  // 長度 20000 的案例本身是可解、aud 相符的 JWT（第一段前面墊字），所以只有長度上限能讓它變 unparsable
  const J6 = [
    ["not-a-jwt", "not-a-jwt"], ["a.%%%.c", "a.%%%.c"], ["長度 20000", "x".repeat(20000 - JWT.length) + JWT],
    ["payload null", jwtOf("null")], ["payload []", jwtOf("[]")],
  ];
  tt("J6 長度 20000 的案例內容正確", J6[2][1].length === 20000 && J6[2][1].split(".").length === 3);
  for (const [name, h] of J6) {
    const c = keep(`J6 ${name}`, await capture(req("/", { headers: { "Cf-Access-Jwt-Assertion": h } }), env, ctxNone()));
    t(`J6 ${name} → 403、unparsable、不拋例外`, [c.threw === null, c.resp?.status, diagOf(c)?.jwtAudMatch], [true, 403, "unparsable"]);
  }
  const cProto = keep("J6 __proto__", await capture(
    req("/", { headers: { "Cf-Access-Jwt-Assertion": jwtOf(`{"__proto__":{"aud":["${AUD}"]}}`) } }), env, ctxNone()));
  tt("J6 __proto__ 夾帶的 aud 不算數", cProto.threw === null && cProto.resp?.status === 403 && diagOf(cProto)?.jwtAudMatch !== true);

  // J10：cookie 名稱必須完全相等
  for (const [cookie, want] of [["xCF_Authorization=1", false], ["CF_Authorization_old=1", false], ["a=1; CF_Authorization=2", true]]) {
    const c = keep(`J10 ${cookie}`, await capture(req("/", { headers: { Cookie: cookie } }), env, ctxNone()));
    t(`J10 Cookie「${cookie}」→ hasAuthCookie`, diagOf(c)?.hasAuthCookie, want);
  }

  // J8：讀標頭會拋錯的請求 —— 不能讓 Worker 炸掉，也不能輸出殘缺或填了替代值的 log
  const badReq = { url: "https://dash.example.com/", method: "GET",
    headers: { get() { throw new Error("boom"); }, has() { throw new Error("boom"); } } };
  for (const [name, ctx, want] of [["ctxNone", ctxNone(), 403], ["ctxAud", ctxAud(AUD), 200]]) {
    const c = await capture(badReq, env, ctx);
    t(`J8 ${name} 標頭讀取拋錯 → 不拋出、狀態碼`, [c.threw === null, c.resp?.status], [true, want]);
    t(`J8 ${name} 所有 console 方法合計輸出行數`, c.lines.length, 0);
    runs.push({ name: `J8 ${name}`, c, noJ9: true });
  }

  // J7：所有擷取到的輸出都不含任何金絲雀
  const allOut = runs.flatMap((r) => r.c.lines.map((l) => l.text)).join("\n");
  const secrets = { AUD, EMAIL, SUB, JWT, COOKIE_VAL, query: "canary-query", token: env.CF_API_TOKEN, acct: env.CF_ACCOUNT_ID };
  JWT.split(".").forEach((seg, i) => { secrets["JWT 第 " + i + " 段"] = seg; });
  for (const [k, v] of Object.entries(secrets)) tt(`J7 輸出不含 ${k}`, !allOut.includes(v));

  // J9：每個請求恰好一行 console.log、鍵集合與值都在白名單內
  const KEYS = ["ctxAudMatch", "ctxAudType", "hasAuthCookie", "hasAuthEmailHeader", "hasCtxAccess", "hasGetIdentity",
    "hasJwtHeader", "host", "jwtAudMatch", "method", "passed", "route"];
  const BOOL = ["passed", "hasCtxAccess", "ctxAudMatch", "hasGetIdentity", "hasJwtHeader", "hasAuthEmailHeader", "hasAuthCookie"];
  const bad = [];
  for (const { name, c, noJ9 } of runs) {
    if (noJ9) continue;
    let o = null;
    try { o = JSON.parse(c.lines[0].text); } catch {}
    const d = o?.accessDiag;
    const okShape = c.lines.length === 1 && c.lines[0].m === "log" && o && Object.keys(o).join() === "accessDiag" && d
      && JSON.stringify(Object.keys(d).sort()) === JSON.stringify(KEYS)
      && BOOL.every((k) => typeof d[k] === "boolean")
      && ["api", "root", "other"].includes(d.route)
      && ["GET", "HEAD", "POST", "OPTIONS", "other"].includes(d.method)
      && ["none", "missing", "string", "array", "other"].includes(d.ctxAudType)
      && [true, false, "absent", "unparsable"].includes(d.jwtAudMatch)
      && d.host === "dash.example.com";
    if (!okShape) bad.push(name);
  }
  t("J9 每個請求恰一行白名單 log（列出不符的請求）", bad, []);
  tt("J9 至少檢查了 20 個請求", runs.filter((r) => !r.noJ9).length >= 20);
}

console.log("\n通過 " + pass + " 項，失敗 " + fail + " 項");
process.exit(fail ? 1 : 0);
