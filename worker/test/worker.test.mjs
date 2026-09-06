// Worker 的邏輯測試。把 global fetch 換成樁，不需要真的 Cloudflare 憑證。
// 重點在兩件事：認證不能有破口，以及判定分類不能把「允許」算成「拒絕」。

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

console.log("\n通過 " + pass + " 項，失敗 " + fail + " 項");
process.exit(fail ? 1 : 0);
