#!/usr/bin/env python3
"""
雲端擋廣告架構 - 核心同步腳本

流程：
1. 抓取 sources.yaml 裡定義的所有來源（OISD Big + AdGuard 6 組訂閱 + 自訂來源）
2. 解析各種格式（domains / adblock / hosts），合併去重
3. 從 D1 讀取白名單，扣除
4. 從 D1 讀取分類快取，未快取或過期的網域批次查詢 Cloudflare Intel API
5. 扣除「已被 Cloudflare 原生 Ads 分類涵蓋」的網域
6. 加上 D1 自訂封鎖清單（強制納入，即使原生分類已涵蓋）
7. 切成 1000 筆一組，上傳到 Cloudflare Gateway 當 Lists
8. 更新 Policy 引用所有清單
9. 寫入 sync_history 紀錄本次結果

設計原則：單一來源抓取/解析失敗不會讓整個流程中斷（best effort）。
"""

import os
import re
import sys
import time
import json
import logging
import requests
import yaml
from datetime import datetime, timezone

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
)
log = logging.getLogger("sync")

# ── 環境變數 ──────────────────────────────────────────────
CF_ACCOUNT_ID = os.environ["CF_ACCOUNT_ID"]
CF_ZONE_ID = os.environ.get("CF_ZONE_ID")  # 目前這版本上傳清單走 account 層級 API，暫不需要
CF_API_TOKEN = os.environ["CF_API_TOKEN"]  # 新申請的 Token，需要 Intel(讀取) + D1(編輯) + Zero Trust(編輯) 權限
D1_DATABASE_ID = os.environ["D1_DATABASE_ID"]

CF_API_BASE = "https://api.cloudflare.com/client/v4"
HEADERS = {"Authorization": f"Bearer {CF_API_TOKEN}", "Content-Type": "application/json"}

DOMAIN_RE = re.compile(r"^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)+$")


def is_valid_domain(d: str) -> bool:
    """基本網域格式驗證，避免髒資料混進清單造成上傳失敗"""
    if not d or len(d) > 253:
        return False
    return bool(DOMAIN_RE.match(d))


# ── 來源抓取與解析 ────────────────────────────────────────

def fetch_source(name: str, url: str, timeout: int = 30) -> str | None:
    try:
        resp = requests.get(url, timeout=timeout, headers={"User-Agent": "cloudflare-gateway-block-ads-sync/1.0"})
        resp.raise_for_status()
        return resp.text
    except Exception as e:
        log.warning(f"[{name}] 抓取失敗，略過此來源: {e}")
        return None


def parse_domains(text: str) -> set[str]:
    """純網域清單，支援 *.domain.com 萬用字元前綴（直接取後面的網域本體）"""
    out = set()
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith(("#", "!")):
            continue
        line = line.removeprefix("*.")
        if is_valid_domain(line):
            out.add(line.lower())
    return out


def parse_adblock(text: str) -> set[str]:
    """
    AdBlock Plus 語法，只抽取單純的網域封鎖規則（||domain^ 或 ||domain^$modifier）。
    略過：註解（!）、CSS/元素隱藏規則（## #@# #?#）、例外規則（@@，交給我們自己的白名單機制處理，
    不採用第三方清單自帶的例外，避免不受控的破口）、帶 domain= 條件式作用域的規則（語意是「只在特定網站上生效」，
    不等於「一律封鎖此網域」，直接採用會過度封鎖）。
    """
    out = set()
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith(("!", "#")):
            continue
        if line.startswith("@@"):
            continue  # 例外規則交給我們自己的白名單機制
        if "##" in line or "#@#" in line or "#?#" in line:
            continue  # CSS/元素隱藏規則，DNS 層級用不到
        if not line.startswith("||"):
            continue

        body = line[2:]
        # 切掉結尾的 ^ 跟後面所有 $modifier
        m = re.match(r"^([a-zA-Z0-9.\-_*]+)\^", body)
        if not m:
            continue
        domain = m.group(1).lstrip("*.").lower()

        # 有 $domain= 這種條件式作用域的規則不當作全域封鎖，略過
        if "$domain=" in line:
            continue

        if is_valid_domain(domain):
            out.add(domain)
    return out


def parse_hosts(text: str) -> set[str]:
    """hosts 檔格式：0.0.0.0 domain.com 或 127.0.0.1 domain.com"""
    out = set()
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        parts = line.split()
        if len(parts) >= 2 and parts[0] in ("0.0.0.0", "127.0.0.1", "::1", "::"):
            domain = parts[1].lower()
            if is_valid_domain(domain):
                out.add(domain)
    return out


PARSERS = {"domains": parse_domains, "adblock": parse_adblock, "hosts": parse_hosts}


def merge_all_sources(config: dict) -> set[str]:
    merged: set[str] = set()
    for src in config["sources"]:
        if not src.get("enabled", True):
            continue
        name, url, fmt = src["name"], src["url"], src["format"]
        log.info(f"抓取來源：{name} ({fmt}) ← {url}")
        text = fetch_source(name, url)
        if text is None:
            continue
        parser = PARSERS.get(fmt)
        if parser is None:
            log.warning(f"[{name}] 未知格式 '{fmt}'，略過")
            continue
        try:
            domains = parser(text)
            log.info(f"[{name}] 解析出 {len(domains)} 筆網域")
            merged |= domains
        except Exception as e:
            log.warning(f"[{name}] 解析失敗，略過此來源: {e}")
    return merged


# ── D1 存取 ──────────────────────────────────────────────

def d1_query(sql: str, params: list | None = None) -> list:
    body = {"sql": sql}
    if params:
        body["params"] = params
    resp = requests.post(
        f"{CF_API_BASE}/accounts/{CF_ACCOUNT_ID}/d1/database/{D1_DATABASE_ID}/query",
        headers=HEADERS, json=body, timeout=30,
    )
    resp.raise_for_status()
    data = resp.json()
    if not data["success"]:
        raise RuntimeError(f"D1 查詢失敗: {data['errors']}")
    return data["result"][0]["results"]


def d1_batch(statements: list[tuple[str, list]]):
    """批次執行多個 SQL（用於大量寫入，減少 API 呼叫次數）"""
    if not statements:
        return
    body = {"batch": [{"sql": sql, "params": params} for sql, params in statements]}
    resp = requests.post(
        f"{CF_API_BASE}/accounts/{CF_ACCOUNT_ID}/d1/database/{D1_DATABASE_ID}/query",
        headers=HEADERS, json=body, timeout=60,
    )
    resp.raise_for_status()
    data = resp.json()
    if not data["success"]:
        raise RuntimeError(f"D1 批次寫入失敗: {data['errors']}")


def load_whitelist() -> set[str]:
    try:
        rows = d1_query("SELECT domain FROM custom_whitelist")
        return {r["domain"].lower() for r in rows}
    except Exception as e:
        log.warning(f"讀取白名單失敗，本次視為空白名單（best effort，不中斷流程）: {e}")
        return set()


def load_custom_blocklist() -> set[str]:
    try:
        rows = d1_query("SELECT domain FROM custom_blocklist")
        return {r["domain"].lower() for r in rows}
    except Exception as e:
        log.warning(f"讀取自訂封鎖清單失敗，本次視為空清單（best effort，不中斷流程）: {e}")
        return set()


def load_category_cache(ttl_days: int) -> dict[str, bool]:
    """回傳 {domain: is_ads_category}，只取未過期的快取"""
    cutoff = int(time.time()) - ttl_days * 86400
    try:
        rows = d1_query(
            "SELECT domain, is_ads_category FROM domain_category_cache WHERE checked_at >= ?",
            [str(cutoff)],
        )
        return {r["domain"]: bool(r["is_ads_category"]) for r in rows}
    except Exception as e:
        log.warning(f"讀取分類快取失敗，本次視為無快取，將重新查詢全部網域: {e}")
        return {}


def save_category_cache(results: dict[str, tuple[bool, list[str]]]):
    """results: {domain: (is_ads, categories_list)}"""
    now = int(time.time())
    statements = []
    for domain, (is_ads, cats) in results.items():
        statements.append((
            "INSERT INTO domain_category_cache (domain, is_ads_category, categories, checked_at) "
            "VALUES (?, ?, ?, ?) "
            "ON CONFLICT(domain) DO UPDATE SET is_ads_category=excluded.is_ads_category, "
            "categories=excluded.categories, checked_at=excluded.checked_at",
            [domain, "1" if is_ads else "0", json.dumps(cats, ensure_ascii=False), str(now)],
        ))
    # D1 batch 一次不要塞太多，分批送
    CHUNK = 200
    for i in range(0, len(statements), CHUNK):
        try:
            d1_batch(statements[i:i + CHUNK])
        except Exception as e:
            log.warning(f"寫入分類快取第 {i}~{i+CHUNK} 批失敗，略過（不影響本次結果，只影響下次快取命中率）: {e}")


def record_sync_history(stats: dict, status: str, notes: str = ""):
    try:
        d1_query(
            "INSERT INTO sync_history "
            "(run_at, total_merged, total_uploaded, total_excluded_by_native_category, total_whitelisted, status, notes) "
            "VALUES (?, ?, ?, ?, ?, ?, ?)",
            [
                str(int(time.time())),
                str(stats.get("total_merged", 0)),
                str(stats.get("total_uploaded", 0)),
                str(stats.get("excluded_by_native", 0)),
                str(stats.get("whitelisted", 0)),
                status,
                notes,
            ],
        )
    except Exception as e:
        log.warning(f"寫入同步歷史紀錄失敗（不影響本次同步結果本身）: {e}")


# ── Cloudflare 原生分類比對 ──────────────────────────────

ADS_CATEGORY_NAMES = {"Advertisements", "Trackers/Analytics"}


def check_native_categories(domains: list[str], batch_size: int) -> dict[str, tuple[bool, list[str]]]:
    """回傳 {domain: (is_ads_category, categories)}"""
    results: dict[str, tuple[bool, list[str]]] = {}
    total = len(domains)
    for i in range(0, total, batch_size):
        batch = domains[i:i + batch_size]
        query = "&".join(f"domain={requests.utils.quote(d)}" for d in batch)
        url = f"{CF_API_BASE}/accounts/{CF_ACCOUNT_ID}/intel/domain/bulk?{query}"
        try:
            resp = requests.get(url, headers=HEADERS, timeout=30)
            resp.raise_for_status()
            data = resp.json()
            if not data["success"]:
                raise RuntimeError(str(data["errors"]))
            for item in data["result"]:
                domain = item.get("domain", "").lower()
                cats = [c.get("name", "") for c in (item.get("content_categories") or [])]
                is_ads = any(c in ADS_CATEGORY_NAMES for c in cats)
                results[domain] = (is_ads, cats)
            log.info(f"分類查詢進度：{min(i + batch_size, total)}/{total}")
        except Exception as e:
            log.warning(f"第 {i}~{i+batch_size} 批分類查詢失敗，這批網域本次視為『未被原生分類涵蓋』"
                        f"（保守處理，寧可多上傳也不要漏擋）: {e}")
            for d in batch:
                results[d] = (False, [])
        time.sleep(0.2)  # 避免打太快撞到速率限制
    return results


# ── Cloudflare Gateway 清單上傳 ───────────────────────────

def get_existing_lists(prefix: str) -> list[dict]:
    resp = requests.get(f"{CF_API_BASE}/accounts/{CF_ACCOUNT_ID}/gateway/lists", headers=HEADERS, timeout=30)
    resp.raise_for_status()
    data = resp.json()
    return [l for l in data["result"] if l["name"].startswith(prefix)]


def upload_lists(final_domains: set[str], config: dict):
    prefix = config["gateway"]["list_name_prefix"]
    chunk_size = config["gateway"]["list_chunk_size"]
    domains_sorted = sorted(final_domains)
    chunks = [domains_sorted[i:i + chunk_size] for i in range(0, len(domains_sorted), chunk_size)]

    existing = get_existing_lists(prefix)
    existing_by_index = {}
    for l in existing:
        m = re.search(r"(\d+)$", l["name"])
        if m:
            existing_by_index[int(m.group(1))] = l

    list_ids = []
    for idx, chunk in enumerate(chunks, start=1):
        name = f"{prefix} - {idx:03d}"
        body = {"name": name, "type": "DOMAIN", "items": [{"value": d} for d in chunk]}
        if idx in existing_by_index:
            list_id = existing_by_index[idx]["id"]
            resp = requests.put(f"{CF_API_BASE}/accounts/{CF_ACCOUNT_ID}/gateway/lists/{list_id}",
                                 headers=HEADERS, json=body, timeout=60)
        else:
            resp = requests.post(f"{CF_API_BASE}/accounts/{CF_ACCOUNT_ID}/gateway/lists",
                                  headers=HEADERS, json=body, timeout=60)
        resp.raise_for_status()
        data = resp.json()
        if not data["success"]:
            raise RuntimeError(f"清單 {name} 上傳失敗: {data['errors']}")
        list_ids.append(data["result"]["id"])
        log.info(f"清單 {name} 已上傳（{len(chunk)} 筆）")

    # 刪除多餘的舊清單（例如網域數變少，之前有 060 這次只需要 055）
    for idx, l in existing_by_index.items():
        if idx > len(chunks):
            try:
                requests.delete(f"{CF_API_BASE}/accounts/{CF_ACCOUNT_ID}/gateway/lists/{l['id']}",
                                 headers=HEADERS, timeout=30)
                log.info(f"刪除多餘舊清單：{l['name']}")
            except Exception as e:
                log.warning(f"刪除舊清單 {l['name']} 失敗（不影響本次上傳結果，之後手動清理即可）: {e}")

    return list_ids


def ensure_policy(list_ids: list[str], config: dict):
    """確保 Gateway Policy 引用目前所有的清單 ID"""
    policy_name = config["gateway"]["policy_name"]
    resp = requests.get(f"{CF_API_BASE}/accounts/{CF_ACCOUNT_ID}/gateway/rules", headers=HEADERS, timeout=30)
    resp.raise_for_status()
    rules = resp.json()["result"]
    existing = next((r for r in rules if r["name"] == policy_name), None)

    # 語法已透過查詢帳戶現有的 Block ads policy 實際內容核對確認：
    # any(dns.domains[*] in $<list-uuid>)，多個清單用 or 串接
    traffic = " or ".join(f"any(dns.domains[*] in ${lid})" for lid in list_ids)

    body = {
        "name": policy_name,
        "action": "block",
        "enabled": True,
        "filters": ["dns"],
        "traffic": traffic,
    }

    if existing:
        resp = requests.put(f"{CF_API_BASE}/accounts/{CF_ACCOUNT_ID}/gateway/rules/{existing['id']}",
                             headers=HEADERS, json=body, timeout=30)
    else:
        resp = requests.post(f"{CF_API_BASE}/accounts/{CF_ACCOUNT_ID}/gateway/rules",
                              headers=HEADERS, json=body, timeout=30)
    resp.raise_for_status()
    data = resp.json()
    if not data["success"]:
        raise RuntimeError(f"Policy 更新失敗: {data['errors']}")
    log.info(f"Policy 「{policy_name}」已更新，引用 {len(list_ids)} 個清單")


# ── 主流程 ───────────────────────────────────────────────

def main():
    with open(os.path.join(os.path.dirname(__file__), "sources.yaml"), encoding="utf-8") as f:
        config = yaml.safe_load(f)

    stats = {}

    # 1. 抓取 + 合併 + 去重
    merged = merge_all_sources(config)
    stats["total_merged"] = len(merged)
    log.info(f"合併去重後總計：{len(merged)} 筆網域")

    # 2. 扣除白名單
    whitelist = load_whitelist()
    before = len(merged)
    merged -= whitelist
    stats["whitelisted"] = before - len(merged)
    log.info(f"扣除白名單 {stats['whitelisted']} 筆，剩餘 {len(merged)} 筆")

    # 3. 原生分類比對
    excluded_by_native = 0
    if config["native_category_check"]["enabled"]:
        ttl = config["native_category_check"]["cache_ttl_days"]
        batch_size = config["native_category_check"]["bulk_batch_size"]

        cached = load_category_cache(ttl)
        log.info(f"分類快取命中 {len(cached)} 筆")

        to_check = [d for d in merged if d not in cached]
        log.info(f"需要重新查詢分類的網域：{len(to_check)} 筆")

        if to_check:
            fresh_results = check_native_categories(to_check, batch_size)
            save_category_cache(fresh_results)
            for d, (is_ads, _cats) in fresh_results.items():
                cached[d] = is_ads

        final_after_native = {d for d in merged if not cached.get(d, False)}
        excluded_by_native = len(merged) - len(final_after_native)
        merged = final_after_native
        log.info(f"扣除已被 Cloudflare 原生 Ads 分類涵蓋的 {excluded_by_native} 筆，剩餘 {len(merged)} 筆")
    stats["excluded_by_native"] = excluded_by_native

    # 4. 加上自訂封鎖清單（強制納入）
    custom_block = load_custom_blocklist()
    merged |= custom_block
    log.info(f"加入自訂封鎖清單 {len(custom_block)} 筆，最終總計：{len(merged)} 筆")

    stats["total_uploaded"] = len(merged)

    if not merged:
        log.error("最終清單是空的，可能所有來源都抓取失敗，中止本次上傳避免清空 Gateway 清單")
        record_sync_history(stats, "failed", "final list empty, aborted")
        sys.exit(1)

    # 5. 上傳到 Cloudflare Gateway
    try:
        list_ids = upload_lists(merged, config)
        ensure_policy(list_ids, config)
    except Exception as e:
        log.error(f"上傳到 Cloudflare Gateway 失敗: {e}")
        record_sync_history(stats, "failed", str(e))
        sys.exit(1)

    record_sync_history(stats, "success")
    log.info("同步完成")
    log.info(json.dumps(stats, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
