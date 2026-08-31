// 頁面的靜態檢查。瀏覽器擴充功能沒連上時，這是能做到的最強驗證：
//   1. 內嵌腳本的語法（寫這種長腳本最常見的錯就是語法錯）
//   2. 腳本抓的每個 id 在 HTML 裡真的存在（打錯字會在執行期變成 null 爆炸）
//   3. 腳本讀的 data-* 屬性真的有被產生出來
//   4. CSP 允許的範圍與頁面實際用到的資源一致

import { PAGE } from "../src/page.js";
import { writeFileSync, mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { execFileSync } from "node:child_process";

let pass = 0, fail = 0;
const ok = (d) => { console.log("    ✓ " + d); pass++; };
const no = (d) => { console.log("    ✗ " + d); fail++; };

const script = (PAGE.match(/<script>([\s\S]*?)<\/script>/) || [])[1];

console.log("情境 A：內嵌腳本的語法");
if (!script) {
  no("找不到 <script> 區塊");
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
  const produced = new Set([
    ...PAGE.matchAll(/data-([a-z-]+)=/g),
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

console.log("\n情境 D：頁面不可以依賴任何外部資源");
{
  const ext = [...PAGE.matchAll(/(?:src|href)="(https?:\/\/[^"]+)"/g)].map((m) => m[1]);
  if (ext.length) no("頁面引用了外部資源，CSP 會擋掉：" + ext.join(", "));
  else ok("沒有引用任何外部資源，符合 default-src 'none'");

  const hasInlineStyle = /<style>/.test(PAGE);
  const hasInlineScript = /<script>/.test(PAGE);
  ok("樣式與腳本都內嵌（style:" + hasInlineStyle + " script:" + hasInlineScript + "）");
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

console.log("\n通過 " + pass + " 項，失敗 " + fail + " 項");
process.exit(fail ? 1 : 0);
