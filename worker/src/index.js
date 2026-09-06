/**
 * 即時觀測儀表板 —— Cloudflare Worker
 *
 * 資料來源是 Cloudflare GraphQL Analytics 的 gatewayResolverQueriesAdaptiveGroups，
 * 也就是 Gateway 實際處理過的 DNS 查詢記錄。這跟 sync.sh 產出的「清單裡有什麼」
 * 是兩回事：清單是意圖，這裡是結果。
 *
 * 安全性：這個頁面會攤開你的完整 DNS 查詢記錄 —— 你去過哪些網站、用哪些 App、
 * 什麼時間用。這是高度敏感的資料。進入權限一律由 Worker-level Cloudflare Access
 * 把關；這支 Worker 只負責確認 Access 真的驗過這個請求，而且驗的是這支應用（比對
 * aud）。ACCESS_AUD 沒設定時，這個 Worker 會拒絕提供任何內容（fail closed），
 * 而不是預設公開。詳見 README。
 */

import { PAGE } from "./page.js";

// ── resolverDecision 對照 ────────────────────────────────
//
// Cloudflare 在 GraphQL 裡把 resolverDecision 宣告成數字，沒有具名列舉，
// 官方文件也只列出字串形式，沒有給數值對照。所以這張表是實證推導出來的
// （2026-08-30，24 小時樣本，用 resolverDecision × policyName 交叉比對）：
//
//   5  → 63,292 筆，policyName 一律為空              = 沒有任何政策命中而放行
//   9  →  9,114 筆，policyName 一律是 "Block ads"    = 被封鎖政策擋下
//   10 →  3,097 筆，policyName 一律是 Allow 類政策    = 被放行政策明確放行
//
// **沒有列在這裡的數字碼一律歸到「其他」，並在畫面上原樣顯示那個碼。**
// 猜錯的代價是把「允許」畫成「拒絕」，那比誠實顯示「未知」糟糕得多。
// 之後如果看到「其他」有量，看它伴隨的 policyName 就能判斷該歸哪邊，再補進這張表。
const DECISION = {
  5: { group: "allowed", label: "允許（無政策命中）" },
  9: { group: "blocked", label: "拒絕（封鎖政策）" },
  10: { group: "allowed", label: "允許（放行政策）" },
};

const ALLOWED_CODES = Object.keys(DECISION).filter((k) => DECISION[k].group === "allowed").map(Number);
const BLOCKED_CODES = Object.keys(DECISION).filter((k) => DECISION[k].group === "blocked").map(Number);

function decisionOf(code) {
  return DECISION[code] || { group: "other", label: `其他（代碼 ${code}）` };
}

// ── 時間範圍與分組粒度 ────────────────────────────────────
// 桶數刻意控制在 24–72 之間：太少看不出趨勢，太多在手機上會擠成一團。
const RANGES = {
  "1h": { hours: 1, bucket: "datetimeFiveMinutes", label: "近 1 小時", step: 5 * 60_000 },
  "6h": { hours: 6, bucket: "datetimeFifteenMinutes", label: "近 6 小時", step: 15 * 60_000 },
  "24h": { hours: 24, bucket: "datetimeHour", label: "近 24 小時", step: 60 * 60_000 },
  "7d": { hours: 24 * 7, bucket: "date", label: "近 7 天", step: 24 * 60 * 60_000 },
};

// ── 認證 ─────────────────────────────────────────────────
//
// 改用 Worker-level Cloudflare Access 之後，JWT 由執行環境在請求進到 Worker 之前就
// 驗完了，ctx.access 拿到的是已經驗過的結果 —— 官方文件明載不需要自行驗證 JWT。
// Access 沒有驗證這個請求時，ctx.access 會是 undefined。

/**
 * 比對 Access 應用的 aud。
 *
 * 原始 JWT 裡的 aud 是陣列，而 ctx.access.aud 的型別官方文件沒有明確保證，
 * 所以字串與陣列兩種形式都要能處理。
 *
 * **一定要相等比對，不可以用 String(aud).includes(expected) 之類的子字串比對。**
 * 同一個 team domain 底下所有 Access 應用共用簽章金鑰，aud 相等是區隔本應用與
 * 其他應用的唯一依據；寬鬆比對等於把別支應用的通行證也一併放了進來。
 */
function audMatches(aud, expected) {
  if (!expected) return false;
  if (Array.isArray(aud)) return aud.includes(expected);
  return aud === expected;
}

// ── Cloudflare GraphQL Analytics ─────────────────────────

async function graphql(env, query, variables) {
  const resp = await fetch("https://api.cloudflare.com/client/v4/graphql", {
    method: "POST",
    headers: {
      Authorization: `Bearer ${env.CF_API_TOKEN}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({ query, variables }),
  });
  const body = await resp.json().catch(() => null);
  if (!resp.ok || !body) {
    throw new Error(`GraphQL HTTP ${resp.status}`);
  }
  if (body.errors && body.errors.length) {
    // 最常見的原因是 API Token 缺少 Account Analytics: Read，直接講清楚
    throw new Error(body.errors.map((e) => e.message).join("; "));
  }
  return body.data;
}

/**
 * 把使用者的篩選條件翻成 GraphQL filter。
 *
 * 注意 queryName_like 一定要帶 % 萬用字元 —— 實測不帶的話永遠回 0 筆，
 * 會做出一個「搜尋永遠沒結果」的功能。
 */
function buildFilter({ since, until, decision, search, bucketStart, bucketEnd }) {
  const f = { datetime_geq: since, datetime_leq: until };
  if (bucketStart && bucketEnd) {
    f.datetime_geq = bucketStart;
    f.datetime_leq = bucketEnd;
  }
  if (decision === "allowed") f.resolverDecision_in = ALLOWED_CODES;
  else if (decision === "blocked") f.resolverDecision_in = BLOCKED_CODES;
  if (search) f.queryName_like = `%${search}%`;
  return f;
}

const SERIES_QUERY = (bucketField) => `
  query($acct:String!, $filter:AccountGatewayResolverQueriesAdaptiveGroupsFilter_InputObject!) {
    viewer { accounts(filter:{accountTag:$acct}) {
      gatewayResolverQueriesAdaptiveGroups(limit:2000, filter:$filter, orderBy:[${bucketField}_ASC]) {
        count
        dimensions { ${bucketField} resolverDecision }
      }
    } }
  }`;

const TOP_QUERY = `
  query($acct:String!, $filter:AccountGatewayResolverQueriesAdaptiveGroupsFilter_InputObject!) {
    viewer { accounts(filter:{accountTag:$acct}) {
      gatewayResolverQueriesAdaptiveGroups(limit:100, filter:$filter, orderBy:[count_DESC]) {
        count
        dimensions { queryName resolverDecision policyName }
      }
    } }
  }`;

function rows(data, key = "gatewayResolverQueriesAdaptiveGroups") {
  return data?.viewer?.accounts?.[0]?.[key] || [];
}

// ── API ──────────────────────────────────────────────────

async function apiData(request, env) {
  const url = new URL(request.url);
  const rangeKey = RANGES[url.searchParams.get("range")] ? url.searchParams.get("range") : "24h";
  const range = RANGES[rangeKey];
  const decision = ["all", "allowed", "blocked"].includes(url.searchParams.get("decision"))
    ? url.searchParams.get("decision")
    : "all";
  const search = (url.searchParams.get("q") || "").trim().slice(0, 120);
  const bucket = url.searchParams.get("bucket") || "";

  const now = Date.now();
  const since = new Date(now - range.hours * 3600_000).toISOString().replace(/\.\d+Z$/, "Z");
  const until = new Date(now).toISOString().replace(/\.\d+Z$/, "Z");

  // 點了某根柱子的話，明細只看那一段時間；柱狀圖本身仍然顯示完整範圍，
  // 這樣才看得出被選中的那段在整體裡的位置。
  let bucketStart = null;
  let bucketEnd = null;
  if (bucket) {
    const t = Date.parse(bucket);
    if (!Number.isNaN(t)) {
      bucketStart = new Date(t).toISOString().replace(/\.\d+Z$/, "Z");
      bucketEnd = new Date(t + range.step - 1).toISOString().replace(/\.\d+Z$/, "Z");
    }
  }

  const seriesFilter = buildFilter({ since, until, decision, search });
  const topFilter = buildFilter({ since, until, decision, search, bucketStart, bucketEnd });

  const [seriesData, topData] = await Promise.all([
    graphql(env, SERIES_QUERY(range.bucket), { acct: env.CF_ACCOUNT_ID, filter: seriesFilter }),
    graphql(env, TOP_QUERY, { acct: env.CF_ACCOUNT_ID, filter: topFilter }),
  ]);

  // 時間序列：同一個時間桶把各判定加總成 允許 / 拒絕 / 其他
  const buckets = new Map();
  for (const r of rows(seriesData)) {
    const ts = r.dimensions[range.bucket];
    if (!buckets.has(ts)) buckets.set(ts, { ts, allowed: 0, blocked: 0, other: 0 });
    buckets.get(ts)[decisionOf(r.dimensions.resolverDecision).group] += r.count;
  }
  const series = [...buckets.values()].sort((a, b) => a.ts.localeCompare(b.ts));

  // 明細：同一個網域可能有多種判定，合併成一列並記下各判定的細分
  const domains = new Map();
  for (const r of rows(topData)) {
    const name = r.dimensions.queryName;
    const d = decisionOf(r.dimensions.resolverDecision);
    if (!domains.has(name)) {
      domains.set(name, { domain: name, total: 0, allowed: 0, blocked: 0, other: 0, policies: [], codes: [] });
    }
    const row = domains.get(name);
    row.total += r.count;
    row[d.group] += r.count;
    if (r.dimensions.policyName && !row.policies.includes(r.dimensions.policyName)) {
      row.policies.push(r.dimensions.policyName);
    }
    if (!row.codes.includes(r.dimensions.resolverDecision)) row.codes.push(r.dimensions.resolverDecision);
  }
  const topDomains = [...domains.values()].sort((a, b) => b.total - a.total).slice(0, 50);

  const totals = series.reduce(
    (a, b) => ({ allowed: a.allowed + b.allowed, blocked: a.blocked + b.blocked, other: a.other + b.other }),
    { allowed: 0, blocked: 0, other: 0 },
  );

  return {
    generatedAt: new Date().toISOString(),
    filters: { range: rangeKey, rangeLabel: range.label, decision, search, bucket },
    window: { since, until, bucketField: range.bucket, stepMs: range.step },
    totals,
    series,
    topDomains,
    // 讓畫面能標出「這些代碼我們還沒歸類」，而不是把它們默默算成允許或拒絕
    knownDecisions: DECISION,
  };
}

async function apiStatus(env) {
  const out = { sync: null, kv: null, errors: [] };

  if (env.DB) {
    try {
      // 只讀最新幾筆，走主鍵倒序 —— 讀取列數固定，符合這個專案對 D1 用量的紀律
      const r = await env.DB.prepare(
        `SELECT run_at, status, total_merged, total_uploaded,
                total_excluded_by_native_category, total_whitelisted, notes
         FROM sync_history ORDER BY id DESC LIMIT 5`,
      ).all();
      out.sync = r.results || [];
    } catch (e) {
      out.errors.push(`D1: ${e.message}`);
    }
  } else {
    out.errors.push("D1: 沒有繫結 DB，略過同步狀態");
  }

  if (env.CACHE_KV) {
    try {
      const v = await env.CACHE_KV.get("category-cache-v1", "arrayBuffer");
      out.kv = v ? { present: true, bytes: v.byteLength } : { present: false };
    } catch (e) {
      out.errors.push(`KV: ${e.message}`);
    }
  }
  return out;
}

// ── 路由 ─────────────────────────────────────────────────

const SECURITY_HEADERS = {
  "X-Content-Type-Options": "nosniff",
  "X-Frame-Options": "DENY",
  "Referrer-Policy": "no-referrer",
  // 頁面完全自帶樣式與腳本，不載入任何外部資源
  "Content-Security-Policy":
    "default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; connect-src 'self'; img-src data:; form-action 'self'; base-uri 'none'",
};

function json(obj, status = 200) {
  return new Response(JSON.stringify(obj), {
    status,
    headers: { "Content-Type": "application/json; charset=utf-8", "Cache-Control": "no-store", ...SECURITY_HEADERS },
  });
}

function html(body, status = 200) {
  return new Response(body, {
    status,
    headers: { "Content-Type": "text/html; charset=utf-8", "Cache-Control": "no-store", ...SECURITY_HEADERS },
  });
}

export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);

    // 沒有設定 ACCESS_AUD 就什麼都不給。維持原本的 fail-closed 哲學：
    // 這個頁面攤開完整 DNS 查詢記錄，設定漏掉的預設結果不可以是「公開」。
    if (!env.ACCESS_AUD) {
      return html(
        `<h1>尚未設定 ACCESS_AUD</h1><p>這個儀表板會顯示完整的 DNS 查詢記錄，在指定它所屬的 Cloudflare Access 應用之前不會提供任何內容。</p>
         <p>請把 Access 應用的 Application Audience (AUD) Tag 填進 <code>wrangler.toml</code> 的 <code>[vars] ACCESS_AUD</code>，重新部署之後再試。</p>`,
        503,
      );
    }

    // Cloudflare Access 沒有驗證這個請求，或驗證的是別的應用 → 拒絕。
    // 這道關卡刻意放在所有路由之前、也刻意放在 try 之外：它涵蓋每一個路徑與方法
    //（含 /api/*、404 分支、OPTIONS、HEAD），而且不留任何能繞過它的例外分支。
    if (!ctx.access || !audMatches(ctx.access.aud, env.ACCESS_AUD)) {
      if (url.pathname.startsWith("/api/")) return json({ error: "未通過驗證" }, 403);
      return html(
        `<h1>需要透過 Cloudflare Access 進入</h1><p>這個請求沒有經過 Cloudflare Access 驗證，或者驗證的是另一支 Access 應用。</p>
         <p>請從 Access 應用涵蓋的網址進入，並用政策允許的帳號登入。</p>`,
        403,
      );
    }

    try {
      if (url.pathname === "/api/data") return json(await apiData(request, env));
      if (url.pathname === "/api/status") return json(await apiStatus(env));
      if (url.pathname === "/") return html(PAGE);
      return json({ error: "找不到這個路徑" }, 404);
    } catch (e) {
      return json({ error: String(e.message || e) }, 500);
    }
  },
};
