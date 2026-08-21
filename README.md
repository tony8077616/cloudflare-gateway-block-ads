# cloudflare-gateway-block-ads（feature/three-source-merge）

用 Cloudflare Zero Trust Gateway 做全網域擋廣告/追蹤器，不需要額外硬體、不需要在家裡多跑一台 Pi-hole。

這個分支是在原本 `main`（OISD Small → Gateway Lists）的基礎上，重新設計成三來源整合的版本：

```
OISD Big  ─┐
            ├─ 合併去重 → 跟 Cloudflare 原生 Ads 分類比對 → 只上傳原生分類沒涵蓋到的部分 → Cloudflare Gateway
AdGuard 6 組訂閱 ─┘
```

---

## 這個分支跟 main 的差異

| | main | feature/three-source-merge |
|---|---|---|
| 來源 | OISD Small | **OISD Big** + AdGuard 6 組訂閱（filter_21、filter_24、EasyList、uBlock filters/badware/privacy）|
| 去重機制 | 無 | 先比對 Cloudflare 原生「Ads」分類（Advertisements + Trackers/Analytics），已涵蓋的網域不重複上傳 |
| 白名單/自訂封鎖清單 | 無 | 有，存放在 D1，用 `manage.sh` 操作 |
| 分類查詢快取 | 無 | 有，存放在 D1，30 天內不重查 |
| 儲存 | 無 | Cloudflare D1（`dns-blocklist-apac`，APAC 地區）|

## 為什麼這樣設計

- **不用 Regex**：實測過（見下方參考），同等規模的網域清單用 Regex 表示會因為 Cloudflare 6,500 字元/policy 的限制，需要遠超過清單方式所需的 policy 數量，規模化之後完全不划算
- **原生分類先擋一層**：Cloudflare 自己的「Ads」分類（Advertisements + Trackers/Analytics）零維護成本、自動更新，先讓它擋掉涵蓋範圍內的網域，可以把實際需要上傳的清單筆數壓低，爭取更多空間在 300 個 List 的免費額度上限之內
- **D1 只做背景批次處理，不做即時查詢**：DNS 查詢當下的封鎖判斷完全交給 Cloudflare Gateway 自己的清單機制，D1 只在 GitHub Actions 排程同步時被讀寫，避開了「即時查詢外部資料庫延遲不穩定」的問題
- **CNAME 分類維持 Cloudflare 預設**（不開啟「忽略 CNAME 域名類別」），保留偵測「用第一方網域偽裝的廣告/追蹤器」的能力，個案誤判交給白名單處理，不犧牲整體防護力

## 已知的技術限制

- **只能做網域層級封鎖，做不到路徑或 App 層級**：DNS 查詢只看得到主機名稱，看不到 URL 路徑或是哪個 App 發出的請求。如果來源清單裡有 `||domain.com/specific/path` 或 `$app=` 這類規則，這些條件會被忽略，只會取網域本體整個封鎖
- **不採用第三方清單自帶的 `@@` 例外規則**：交給我們自己的白名單機制統一管理，避免不受控的破口

---

## 部署前置作業

1. Fork 這個分支到你自己的 repo（或建立 `feature/three-source-merge` 分支）
2. 到 repo → Settings → Secrets and variables → Actions，新增：

   | Secret 名稱 | 值 |
   |---|---|
   | `CF_ACCOUNT_ID` | 你的 Cloudflare Account ID |
   | `CF_API_TOKEN_ADBLOCK` | 新申請的 Token，需要 **Intel（讀取）+ D1（編輯）+ Zero Trust（編輯）** 權限，跟 main 分支用的 Token 分開，不要共用 |
   | `CF_D1_DATABASE_ID` | `0918dd23-b75e-4ab5-a82f-bdaa44650fea`（APAC 地區，4 個資料表已就緒）|

3. **刪掉舊的 `block_ads_update.yml`、`block_ads.sh`、`block_ads_delete.sh`、`oisd_small_domainswild2.txt`**，避免新舊兩套機制同時跑、互搶 Cloudflare 端資源
4. 建議先手動觸發一次 workflow（`workflow_dispatch`），看執行紀錄確認沒問題，再放心讓它照排程自動跑（預設每天台灣時間凌晨 2:00）

## 檔案結構

```
sources.conf               來源清單設定（7 個內建來源 + 可自行新增自訂來源，格式 name|url|format）
sync.sh                    核心同步腳本（bash + curl + jq）
manage.sh                  白名單 / 自訂封鎖清單管理小工具
.github/workflows/sync.yml   排程 workflow
```

## 白名單 / 自訂封鎖清單

```bash
export CF_ACCOUNT_ID=你的帳戶ID
export CF_API_TOKEN=你的Token
export D1_DATABASE_ID=0918dd23-b75e-4ab5-a82f-bdaa44650fea

# 白名單（誤擋時救援用）
./manage.sh whitelist add example.com "這是我常用的服務，誤擋了"
./manage.sh whitelist list
./manage.sh whitelist remove example.com

# 自訂封鎖清單（原生分類沒涵蓋到、但你想額外擋的網域）
./manage.sh block add ads.某廣告網域.com "手動追加"
./manage.sh block list
./manage.sh block remove ads.某廣告網域.com
```

加完之後**不會馬上生效**，要等下一次排程同步（或手動觸發 workflow）才會實際套用到 Cloudflare Gateway。

**設計原則：盡力而為，不要跳錯**。`manage.sh` 打錯網域格式、或 D1 一時連不上，只會印出錯誤訊息，不會讓工具當掉（`set -uo pipefail` 但刻意不用 `-e`，就是為了讓這種錯誤可以印警告後繼續，而不是整個腳本中斷）；`sync.sh` 主流程如果讀不到白名單/自訂清單，會自動退回成空清單繼續往下跑，不會因為這兩個小功能出狀況就讓整個廣告清單同步失敗。

## 自訂訂閱來源

編輯 `sources.conf`，每行一筆，格式 `name|url|format`，`format` 支援 `domains`（純網域清單）、`adblock`（AdBlock Plus 語法）、`hosts`（hosts 檔格式）。新來源抓取或解析失敗只會留下警告紀錄，不會讓整次同步失敗，其他來源照樣正常合併上傳。

## 執行環境需求

`sync.sh` / `manage.sh` 只依賴 `bash`、`curl`、`jq`、`coreutils`（`sort`/`comm`/`awk`/`sed` 等），跟原本 `main` 分支的 `block_ads.sh` 用的工具組一致，不需要額外裝 Python。

## 同步流程

```
抓取 7 個來源（暫存到 GitHub Actions runner 本機檔案）→ 合併去重
     ↓
扣掉白名單（D1 custom_whitelist）
     ↓
查 D1 分類快取，沒快取或過期的批次查 Cloudflare Intel API（每批 500 筆，實測驗證上限約 700）
     ↓
扣掉「已被 Cloudflare 原生 Ads 分類涵蓋」的網域
     ↓
加上自訂封鎖清單（D1 custom_blocklist，強制納入）
     ↓
切成 1000 筆一組，上傳/更新 Cloudflare Gateway Lists
     ↓
更新 Policy（traffic 表達式：any(dns.domains[*] in $list-uuid)，語法已對照帳戶內現有正常運作的 Policy 核對過）
     ↓
寫入本次同步紀錄到 D1 sync_history
```

## 已測試過的部分

以下邏輯已經在沙箱環境用範例資料獨立測試過，確認行為符合預期：
- 三種格式（domains / adblock / hosts）的解析函式，含邊界案例（`$domain=` 條件式規則、CSS 隱藏規則、例外規則、大小寫混合、`*.` 萬用字元前綴）
- 白名單/分類扣除用的 `comm` 集合運算，含「清單為空」邊界情況
- D1 批次寫入、Gateway 清單上傳、Policy `traffic` 表達式的 JSON 組裝邏輯

**沒有測試過的部分**：整支 `sync.sh` 串起來、真的打 Cloudflare API 的完整流程（沒有測試環境可以跑）。第一次手動觸發 workflow 後，建議仔細看一次執行紀錄裡的統計數字（合併總數、扣除白名單/原生分類後的數量、最終上傳數量）合不合理。

## 參考

這個分支的設計參考了同類型專案的公開實作經驗，包括：
- Regex 規模化不可行的實測數據（CJ Scrofani，144K 網域用 Regex 需要 499 條 policy，用清單只需要 145 個）
- 白名單優先於封鎖清單的機制設計（luxysiv/Cloudflare-Gateway-DNS-Filter）
- 300 List 免費額度上限的處理方式（多個同類專案的共通做法）
