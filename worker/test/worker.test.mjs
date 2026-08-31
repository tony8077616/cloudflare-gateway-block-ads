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

const TOKEN = "s3cr3t-token";
const baseEnv = { DASH_TOKEN: TOKEN, CF_API_TOKEN: "cf-token", CF_ACCOUNT_ID: "acct123" };

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
const authed = (path) => req(path, { headers: { Authorization: "Bearer " + TOKEN } });

console.log("情境 A：沒有設定 DASH_TOKEN 時必須 fail closed");
{
  const r = await worker.fetch(req("/"), { CF_API_TOKEN: "x", CF_ACCOUNT_ID: "y" });
  t("回傳 503", r.status, 503);
  const body = await r.text();
  tt("說明要怎麼設定", body.includes("wrangler secret put DASH_TOKEN"));
  const r2 = await worker.fetch(req("/api/data"), { CF_API_TOKEN: "x" });
  t("API 也一樣擋住", r2.status, 503);
}

console.log("\n情境 B：認證");
{
  const r = await worker.fetch(req("/"), baseEnv);
  t("沒帶憑證 → 401 並顯示登入頁", r.status, 401);
  tt("是 HTML 登入頁", (await r.text()).includes("通行碼"));

  const r2 = await worker.fetch(req("/api/data"), baseEnv);
  t("API 沒帶憑證 → 401 JSON", r2.status, 401);

  const r3 = await worker.fetch(req("/", { headers: { Authorization: "Bearer wrong-token" } }), baseEnv);
  t("錯的 token → 401", r3.status, 401);

  const r4 = await worker.fetch(req("/", { headers: { Authorization: "Bearer " + TOKEN.slice(0, 5) } }), baseEnv);
  t("token 前綴正確但長度不同 → 401", r4.status, 401);

  const r5 = await worker.fetch(req("/", { headers: { Cookie: "dash_token=" + encodeURIComponent(TOKEN) } }), baseEnv);
  t("正確的 cookie → 200", r5.status, 200);

  stubGraphQL([], []);
  const r6 = await worker.fetch(authed("/"), baseEnv);
  t("正確的 Bearer → 200", r6.status, 200);
  tt("回的是儀表板頁面", (await r6.text()).includes("擋廣告觀測儀表板"));
}

console.log("\n情境 C：登入表單");
{
  const form = new FormData(); form.set("token", TOKEN);
  const r = await worker.fetch(req("/login", { method: "POST", body: form }), baseEnv);
  t("正確通行碼 → 302", r.status, 302);
  const c = r.headers.get("Set-Cookie") || "";
  tt("cookie 有 HttpOnly", c.includes("HttpOnly"));
  tt("cookie 有 Secure", c.includes("Secure"));
  tt("cookie 有 SameSite=Strict", c.includes("SameSite=Strict"));

  const bad = new FormData(); bad.set("token", "nope");
  const r2 = await worker.fetch(req("/login", { method: "POST", body: bad }), baseEnv);
  t("錯誤通行碼 → 401", r2.status, 401);
  tt("沒有發出 cookie", !(r2.headers.get("Set-Cookie") || "").includes("dash_token"));
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
  const r = await worker.fetch(authed("/api/data?range=24h"), baseEnv);
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
  await worker.fetch(authed("/api/data?range=24h&decision=blocked"), baseEnv);
  const f = captured[0].variables.filter;
  t("僅拒絕 → resolverDecision_in=[9]", f.resolverDecision_in, [9]);

  stubGraphQL([], []);
  await worker.fetch(authed("/api/data?range=24h&decision=allowed"), baseEnv);
  t("僅允許 → resolverDecision_in=[5,10]", captured[0].variables.filter.resolverDecision_in, [5, 10]);

  stubGraphQL([], []);
  await worker.fetch(authed("/api/data?range=24h&decision=all"), baseEnv);
  tt("全部 → 不帶 resolverDecision_in", captured[0].variables.filter.resolverDecision_in === undefined);

  // 這一項是實測踩過的坑：queryName_like 不帶 % 的話永遠回 0 筆
  stubGraphQL([], []);
  await worker.fetch(authed("/api/data?range=24h&q=doubleclick"), baseEnv);
  t("搜尋要包成 %pattern%", captured[0].variables.filter.queryName_like, "%doubleclick%");

  stubGraphQL([], []);
  await worker.fetch(authed("/api/data?range=1h"), baseEnv);
  tt("1 小時用 5 分鐘分桶", captured[0].query.includes("datetimeFiveMinutes"));
  stubGraphQL([], []);
  await worker.fetch(authed("/api/data?range=7d"), baseEnv);
  tt("7 天用日期分桶", /dimensions \{ date resolverDecision \}/.test(captured[0].query));

  stubGraphQL([], []);
  await worker.fetch(authed("/api/data?range=24h&range=bogus"), baseEnv);
  tt("無效的 range 退回 24h", captured[0].query.includes("datetimeHour"));
}

console.log("\n情境 F：點選柱狀圖只縮小明細的時間範圍，趨勢圖仍是完整範圍");
{
  stubGraphQL([], []);
  await worker.fetch(authed("/api/data?range=24h&bucket=2026-08-30T10:00:00Z"), baseEnv);
  const seriesFilter = captured[0].variables.filter;
  const topFilter = captured[1].variables.filter;
  t("明細起點 = 被點的時間桶", topFilter.datetime_geq, "2026-08-30T10:00:00Z");
  tt("明細終點在該桶之內（未滿一小時）", topFilter.datetime_leq.startsWith("2026-08-30T10:59:59"));
  tt("趨勢圖不受時間桶影響", seriesFilter.datetime_geq !== topFilter.datetime_geq);

  stubGraphQL([], []);
  await worker.fetch(authed("/api/data?range=24h&bucket=not-a-time"), baseEnv);
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
  const d = await (await worker.fetch(authed("/api/data?range=24h"), baseEnv)).json();
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
  const r = await worker.fetch(authed("/api/data?range=24h"), baseEnv);
  t("回 500", r.status, 500);
  const j = await r.json();
  tt("帶出原始錯誤訊息", j.error.includes("Authentication error"));
}

console.log("\n情境 I：安全標頭與未知路徑");
{
  stubGraphQL([], []);
  const r = await worker.fetch(authed("/"), baseEnv);
  tt("有 X-Content-Type-Options", r.headers.get("X-Content-Type-Options") === "nosniff");
  tt("有 X-Frame-Options: DENY", r.headers.get("X-Frame-Options") === "DENY");
  tt("CSP 預設封死", (r.headers.get("Content-Security-Policy") || "").includes("default-src 'none'"));
  tt("不快取", (r.headers.get("Cache-Control") || "").includes("no-store"));
  const r2 = await worker.fetch(authed("/nope"), baseEnv);
  t("未知路徑 → 404", r2.status, 404);
}

console.log("\n通過 " + pass + " 項，失敗 " + fail + " 項");
process.exit(fail ? 1 : 0);
