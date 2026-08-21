# 使用說明

這是 `tony8077616/cloudflare-gateway-block-ads` 的擴充分支，把來源從單純 OISD Small 換成
**OISD Big + 你原本訂閱的 AdGuard 6 組清單**，並加上跟 Cloudflare 原生分類比對去重的機制。

## 部署前置作業（你需要自己在 GitHub 上做的事）

1. Fork 這個分支到你自己的 repo（或新增一個 `feature/three-source-merge` 分支）
2. 到你的 repo → Settings → Secrets and variables → Actions，新增以下三個 Secrets：

   | Secret 名稱 | 值 |
   |---|---|
   | `CF_ACCOUNT_ID` | 你的 Cloudflare Account ID |
   | `CF_API_TOKEN_ADBLOCK` | 你新申請的 Token（需要 Intel 讀取 + D1 編輯 + Zero Trust 編輯權限）|
   | `CF_D1_DATABASE_ID` | `0918dd23-b75e-4ab5-a82f-bdaa44650fea`（已建立好的 D1 資料庫，地區為 APAC，4 個資料表已就緒）|

   **注意**：這組 Token 跟 `main` 分支原本用的 Token 是分開的兩組，不要共用，避免權限範圍互相影響。

3. 確認 workflow 排程時間（預設每天台灣時間凌晨 2:00，可以自己改 `.github/workflows/sync.yml` 裡的 cron）

## 白名單 / 自訂封鎖清單

用 `manage.py` 這支小工具操作（本機執行，需要先設定好跟 workflow 一樣的三個環境變數）：

```bash
export CF_ACCOUNT_ID=你的帳戶ID
export CF_API_TOKEN=你的Token
export D1_DATABASE_ID=0918dd23-b75e-4ab5-a82f-bdaa44650fea

# 加白名單（誤擋時救援用）
python manage.py whitelist add example.com "這是我常用的服務，誤擋了"

# 查看目前白名單
python manage.py whitelist list

# 移除白名單
python manage.py whitelist remove example.com

# 自訂封鎖清單（Cloudflare 原生分類沒涵蓋到、但你想額外擋的網域）
python manage.py block add ads.某廣告網域.com "手動追加"
python manage.py block list
python manage.py block remove ads.某廣告網域.com
```

**加完之後不會馬上生效**，要等下一次排程同步（或到 GitHub Actions 頁面手動觸發 `workflow_dispatch`）才會真的套用到 Cloudflare Gateway。

**設計原則是「盡力而為，不要跳錯」**：如果你不小心打錯網域格式、或 D1 一時連不上，`manage.py` 只會印出錯誤訊息，不會讓整個工具當掉；就算白名單或自訂清單讀取失敗，`sync.py` 主流程也會自動退回成「空清單」繼續跑完整個同步，不會因為這兩個小功能出問題就讓整個廣告清單同步失敗。

## 自訂訂閱來源

直接編輯 `sources.yaml`，在 `sources:` 底下比照現有格式新增一筆即可，`format` 支援：

- `domains`：純網域清單，每行一個
- `adblock`：AdBlock Plus 語法（`||domain^` 格式）
- `hosts`：hosts 檔格式（`0.0.0.0 domain.com`）

新增的來源如果抓取失敗或格式解析不出東西，**只會在執行紀錄裡留下警告，不會讓整次同步失敗**——其他來源照樣正常合併上傳。

## 目前的設計決策（跟你確認過的部分）

- **CNAME 分類**：維持 Cloudflare 預設（不開啟「忽略 CNAME 域名類別」），保留偵測 CNAME 偽裝廣告/追蹤器的能力。這個是 Cloudflare 後台的 Policy 設定，這次分支的程式碼不會去動它
- **來源**：OISD Big（不是 Small）+ 你原本已訂閱的 AdGuard 6 組清單
- **原生分類去重**：合併去重後的網域，會先查一次 Cloudflare 的 `/intel/domain/bulk`，已經被原生 Ads/Trackers 分類涵蓋的不會重複上傳，只上傳「原生分類漏掉的」部分，降低逼近 300 個 List 上限的風險
- **分類查詢結果會快取在 D1**（30 天內不重查），平常同步不會每次都重新查詢全部網域，只有快取過期或新網域才會查

## 執行流程摘要

```
抓取 7 個來源 → 合併去重
     ↓
扣掉白名單（D1 custom_whitelist）
     ↓
查 D1 分類快取，沒快取的批次查 Cloudflare Intel API（每批 500 筆）
     ↓
扣掉「已被 Cloudflare 原生 Ads 分類涵蓋」的網域
     ↓
加上自訂封鎖清單（D1 custom_blocklist，強制納入）
     ↓
切成 1000 筆一組，上傳/更新 Cloudflare Gateway Lists
     ↓
更新 Policy 引用所有清單，寫入本次同步紀錄到 D1 sync_history
```
