// 頁面的靜態檢查。瀏覽器擴充功能沒連上時，這是能做到的最強驗證：
//   1. 頁面腳本（APP_JS）的語法（寫這種長腳本最常見的錯就是語法錯）
//   2. 腳本抓的每個 id 在 HTML 裡真的存在（打錯字會在執行期變成 null 爆炸）
//   3. 腳本讀的 data-* 屬性真的有被產生出來（產生端同時看 PAGE 與 APP_JS）
//   4. CSP 允許的範圍與頁面實際用到的資源一致，而且 PAGE 裡沒有任何行內腳本／行內事件屬性
//   5. fmt() 的輸出只可能來自數字（情境 F）

import { PAGE, APP_JS } from "../src/page.js";
import { writeFileSync, mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { execFileSync } from "node:child_process";

let pass = 0, fail = 0;
const ok = (d) => { console.log("    ✓ " + d); pass++; };
const no = (d) => { console.log("    ✗ " + d); fail++; };

// 腳本已經不在 PAGE 裡了：它是獨立的 APP_JS，由 Worker 的 /app.js 提供。
const script = APP_JS;

console.log("情境 A：頁面腳本（APP_JS）的語法");
if (!script) {
  no("APP_JS 是空的");
} else {
  const dir = mkdtempSync(join(tmpdir(), "pagecheck-"));
  const f = join(dir, "inline.cjs");
  writeFileSync(f, script, "utf8");
  try {
    execFileSync(process.execPath, ["--check", f], { stdio: "pipe" });
    ok("node --check 通過（" + script.split("\n").length + " 行）");
  } catch (e) {
    no("語法錯誤：" + String(e.stderr || e).split("\n").slice(0, 4).join(" "));
  }
}

console.log("\n情境 B：腳本抓的 id 必須真的存在於 HTML");
{
  const declared = new Set([...PAGE.matchAll(/\bid="([^"]+)"/g)].map((m) => m[1]));
  const used = new Set([...(script || "").matchAll(/\$\("([^"]+)"\)/g)].map((m) => m[1]));
  const missing = [...used].filter((x) => !declared.has(x));
  if (missing.length) no("腳本抓了不存在的 id：" + missing.join(", "));
  else ok("腳本用到的 " + used.size + " 個 id 全部存在");

  // 反向：宣告了卻沒用到的 id 不是錯，但值得知道
  const unused = [...declared].filter((x) => !used.has(x));
  console.log("      （宣告但未被 $() 取用：" + (unused.length ? unused.join(", ") : "無") + "）");
}

console.log("\n情境 C：data-* 屬性的產生端與讀取端要對得上");
{
  const readAttrs = new Set([
    ...(script || "").matchAll(/dataset\.(\w+)/g),
  ].map((m) => m[1]));
  const readSelectors = new Set([
    ...(script || "").matchAll(/\[data-([a-z-]+)\]/g),
  ].map((m) => m[1]));
  // 產生端一定要同時掃 PAGE 與 APP_JS：data-clear／data-dom 是腳本用 innerHTML 產生的，
  // 只掃 PAGE 的話這兩個讀取端就沒有任何產生端為它們背書，檢查形同虛設。
  const produced = new Set([
    ...PAGE.matchAll(/data-([a-z-]+)=/g),
    ...APP_JS.matchAll(/data-([a-z-]+)=/g),
  ].map((m) => m[1]));

  const camel = (s) => s.replace(/-([a-z])/g, (_, c) => c.toUpperCase());
  const producedCamel = new Set([...produced].map(camel));

  const missDataset = [...readAttrs].filter((x) => !producedCamel.has(x));
  const missSelector = [...readSelectors].filter((x) => !produced.has(x));

  if (missDataset.length) no("讀了沒有被產生的 dataset：" + missDataset.join(", "));
  else ok("dataset 讀取端全部有對應的產生端（" + [...readAttrs].join(", ") + "）");

  if (missSelector.length) no("選擇器找的 data-* 沒有產生端：" + missSelector.join(", "));
  else ok("[data-*] 選擇器全部有對應的產生端（" + [...readSelectors].join(", ") + "）");
}

console.log("\n情境 D：頁面不可以依賴跨源資源，也不可以有任何行內腳本或行內事件屬性");
{
  const ext = [...PAGE.matchAll(/(?:src|href)="(https?:\/\/[^"]+)"/g)].map((m) => m[1]);
  if (ext.length) no("頁面引用了跨源資源，CSP 會擋掉：" + ext.join(", "));
  else ok("沒有引用任何跨源資源，符合 default-src 'none'");

  const hasInlineStyle = /<style>/.test(PAGE);
  ok("樣式內嵌、腳本改由同源外部檔提供（style:" + hasInlineStyle + "）");

  // script-src 是 'self'，而自訂網域的邊緣還會再加 nonce：行內腳本沒有 nonce 就不會執行，
  // 頁面 JS 完全不動、API 一次都不會呼叫（2026-09-15 上線後實際發生）。所以 PAGE 裡
  // 只能有一個腳本標籤，而且必須是指向 /app.js 的空標籤。
  // data-cfasync="false" 保留（PR #27）：zone 開著 Rocket Loader 時它會改寫腳本的載入方式。
  // 大小寫不敏感（加 i）：HTML 的標籤名與屬性名本來就不分大小寫，只比對小寫會漏掉 <SCRIPT>。
  const EXPECTED_TAG = '<script data-cfasync="false" src="/app.js"><' + "/script>";
  const tags = [...PAGE.matchAll(/<script\b[^>]*>/gi)].map((m) => m[0]);
  if (tags.length === 1) ok("PAGE 恰好一個腳本開頭標籤");
  else no("PAGE 必須恰好一個腳本開頭標籤，實際 " + tags.length + " 個：" + tags.join(" "));

  const elements = [...PAGE.matchAll(/<script\b[\s\S]*?<\/script\s*>/gi)].map((m) => m[0]);
  if (elements.length === 1 && elements[0] === EXPECTED_TAG) {
    ok("腳本標籤逐字等於 " + EXPECTED_TAG + "（標籤之間沒有任何內容）");
  } else {
    no("腳本標籤不是預期的形式，PAGE 裡可能留了行內腳本：" + JSON.stringify(elements));
  }

  const bare = tags.filter((t) => !/\sdata-cfasync="false"/i.test(t));
  if (bare.length) no("有腳本標籤沒帶 data-cfasync=\"false\"，會被 Rocket Loader 改寫：" + bare.join(" "));
  else ok("全部 " + tags.length + " 個腳本標籤都帶 data-cfasync=\"false\"（Rocket Loader 不會改寫）");

  // 行內事件屬性（onclick=、onError= …）在 script-src 'self' 之下一律不會執行，
  // 而且就算執行也是我們不想要的寫法。PAGE 與 APP_JS 產生的片段都不可以有。
  for (const [name, src] of [["PAGE", PAGE], ["APP_JS", APP_JS]]) {
    const m = src.match(/\son[a-z]+\s*=/i);
    if (m) no(name + " 含行內事件屬性：" + m[0].trim());
    else ok(name + " 不含行內事件屬性（on*=）");

    const j = src.match(/javascript:/i);
    if (j) no(name + " 含 javascript: 網址");
    else ok(name + " 不含 javascript: 網址");
  }

  // APP_JS 是原樣送出的 JS 檔，不經過 HTML 解析，但它若含 </script 就代表有人
  // 又把它塞回頁面裡了 —— 那會在瀏覽器端提早結束標籤。
  if (/<\/script/i.test(APP_JS)) no("APP_JS 含 </script");
  else ok("APP_JS 不含 </script");
}

console.log("\n情境 E：需求對照 —— 這四項在頁面上都要找得到");
{
  const checks = [
    ["手動重新整理按鈕", /id="refresh"/.test(PAGE) && /\$\("refresh"\)\.addEventListener\("click"/.test(script)],
    ["柱狀圖可點選並帶出時間段", /bar-hit/.test(PAGE) && /state\.bucket = \(state\.bucket === b\.ts\)/.test(script)],
    ["允許/拒絕的篩選", /data-v="allowed"/.test(PAGE) && /data-v="blocked"/.test(PAGE)],
    ["網域搜尋", /id="q"/.test(PAGE) && /queryName/.test(PAGE) === false],
    ["即時顯示目前分析條件", /id="chips"/.test(PAGE) && /renderChips/.test(script)],
    ["輸入中即時反映（尚未套用的狀態）", /pending/.test(script)],
  ];
  for (const [d, c] of checks) c ? ok(d) : no(d);
}

console.log("\n情境 F：fmt() 只輸出由數字產生的字串（它的結果有幾處未經 esc() 就進 innerHTML）");
{
  // 從 APP_JS 擷取 fmt 的定義本身來測，而不是在這裡另寫一份 —— 改了頁面卻沒改測試時才抓得到。
  const m = APP_JS.match(/\bvar fmt = (function\s*\(n\)\s*\{[^\n]*\});/);
  if (!m) {
    no("在 APP_JS 找不到 fmt 的定義");
  } else {
    let fmt = null;
    try { fmt = new Function("return (" + m[1] + ");")(); }
    catch (e) { no("fmt 的定義無法取出：" + String(e && e.message)); }
    if (typeof fmt === "function") {
      // 取出的函式看不到 APP_JS 裡的其他區域變數（例如 esc）：呼叫時拋例外也要算成一項失敗，不讓整支檢查中斷
      const raw = fmt;
      fmt = (v) => { try { return raw(v); } catch (e) { return "（拋出例外：" + String(e && e.message) + "）"; } };
      const same = (d, got, want) => (got === want ? ok(d + "：" + JSON.stringify(got)) : no(d + "：得到 " + JSON.stringify(got) + " 預期 " + JSON.stringify(want)));
      same("fmt(1234)", fmt(1234), "1,234");
      for (const [label, v] of [["0", 0], ["null", null], ["undefined", undefined], ['""', ""], ["NaN", NaN], ["Infinity", Infinity], ["-0", -0]]) {
        same("fmt(" + label + ")", fmt(v), "0");
      }
      const xss = fmt("<img src=x onerror=alert(1)>");
      same("fmt(\"<img src=x onerror=alert(1)>\")", xss, "0");
      if (String(xss).includes("<")) no("fmt 的輸出含 <"); else ok("fmt 的輸出不含 <");
      same("fmt(\"123\")", fmt("123"), "123");
      same("fmt(1234.5) 與 Number(1234.5).toLocaleString(\"zh-Hant\") 相同", fmt(1234.5), Number(1234.5).toLocaleString("zh-Hant"));
    }
  }
}

console.log("\n通過 " + pass + " 項，失敗 " + fail + " 項");
process.exit(fail ? 1 : 0);
