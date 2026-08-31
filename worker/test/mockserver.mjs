// 本機模擬伺服器：用假資料跑真正的 Worker，讓瀏覽器可以實際操作頁面。
// 目的是驗證頁面腳本真的能執行 —— 單元測試驗不到 DOM 與互動。
import { createServer } from "node:http";
import worker from "../src/index.js";

const TOKEN = "local-dev-token";

// 造 24 個小時桶，量體有起伏，最後一桶刻意塞一個未歸類的判定代碼，
// 用來確認「其他」的警告橫幅真的會出現。
const now = Date.now();
const hour = 3600_000;
const seriesRows = [];
for (let i = 23; i >= 0; i--) {
  const ts = new Date(Math.floor((now - i * hour) / hour) * hour).toISOString().replace(/\.\d+Z$/, "Z");
  const base = 400 + Math.round(600 * Math.abs(Math.sin(i / 3)));
  seriesRows.push({ count: base, dimensions: { datetimeHour: ts, resolverDecision: 5 } });
  seriesRows.push({ count: Math.round(base * 0.18), dimensions: { datetimeHour: ts, resolverDecision: 9 } });
  seriesRows.push({ count: Math.round(base * 0.06), dimensions: { datetimeHour: ts, resolverDecision: 10 } });
  if (i === 0) seriesRows.push({ count: 12, dimensions: { datetimeHour: ts, resolverDecision: 99 } });
}

const topRows = [
  { count: 2241, dimensions: { queryName: "www.cloudflare-gateway.com", resolverDecision: 10, policyName: "Global Policy - Allow DNS queries for cloudflare-gateway.com domain" } },
  { count: 1476, dimensions: { queryName: "googleads.g.doubleclick.net", resolverDecision: 9, policyName: "Block ads" } },
  { count: 743, dimensions: { queryName: "whois.apnic.net", resolverDecision: 5, policyName: null } },
  { count: 615, dimensions: { queryName: "whoami.akamai.net", resolverDecision: 5, policyName: null } },
  { count: 497, dimensions: { queryName: "qcc.qualcomm.com", resolverDecision: 9, policyName: "Block ads" } },
  { count: 395, dimensions: { queryName: "o64374.ingest.sentry.io", resolverDecision: 9, policyName: "Block ads" } },
  { count: 372, dimensions: { queryName: "firebase-settings.crashlytics.com", resolverDecision: 9, policyName: "Block ads" } },
  { count: 330, dimensions: { queryName: "discord.com", resolverDecision: 5, policyName: null } },
  { count: 118, dimensions: { queryName: "r5.sn-abc.googlevideo.com", resolverDecision: 10, policyName: "Allow YouTube/Google Video CDN (防止上游清單誤封)" } },
  { count: 12, dimensions: { queryName: "unknown-decision.example", resolverDecision: 99, policyName: null } },
];

globalThis.fetch = async (url, init) => {
  const body = JSON.parse(init.body);
  const isSeries = !body.query.includes("queryName");
  const f = body.variables.filter;

  let rows = isSeries ? seriesRows : topRows;

  // 讓模擬資料也會回應篩選條件，這樣互動才看得出效果
  if (f.resolverDecision_in) {
    rows = rows.filter(r => f.resolverDecision_in.includes(r.dimensions.resolverDecision));
  }
  if (f.queryName_like) {
    const pat = f.queryName_like.replace(/%/g, "").toLowerCase();
    rows = rows.filter(r => !r.dimensions.queryName || r.dimensions.queryName.toLowerCase().includes(pat));
  }
  if (!isSeries && f.datetime_geq && f.datetime_leq) {
    const span = Date.parse(f.datetime_leq) - Date.parse(f.datetime_geq);
    // 被點選的時間桶：只回前三筆，讓畫面上看得出「縮小了」
    if (span < 2 * hour) rows = rows.slice(0, 3);
  }

  return new Response(JSON.stringify({
    data: { viewer: { accounts: [{ gatewayResolverQueriesAdaptiveGroups: rows }] } },
  }), { status: 200, headers: { "Content-Type": "application/json" } });
};

const env = {
  DASH_TOKEN: TOKEN,
  CF_API_TOKEN: "mock",
  CF_ACCOUNT_ID: "mock-account",
  DB: {
    prepare: () => ({
      all: async () => ({
        results: [
          { run_at: Math.floor(now / 1000) - 600, status: "success", total_merged: 277894, total_uploaded: 223146, total_excluded_by_native_category: 54742, total_whitelisted: 6, notes: null },
          { run_at: Math.floor(now / 1000) - 4200, status: "success", total_merged: 277880, total_uploaded: 223135, total_excluded_by_native_category: 54739, total_whitelisted: 6, notes: null },
        ],
      }),
    }),
  },
  CACHE_KV: { get: async () => new ArrayBuffer(3714852) },
};

createServer(async (req, res) => {
  const url = "http://127.0.0.1:8787" + req.url;
  // 自動帶上憑證，省去每次手動登入
  const r = await worker.fetch(new Request(url, {
    method: req.method,
    headers: { ...req.headers, Authorization: "Bearer " + TOKEN },
  }), env);
  res.writeHead(r.status, Object.fromEntries(r.headers));
  res.end(Buffer.from(await r.arrayBuffer()));
}).listen(8787, "127.0.0.1", () => console.log("mock server on http://127.0.0.1:8787"));
