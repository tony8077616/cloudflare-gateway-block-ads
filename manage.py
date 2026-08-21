#!/usr/bin/env python3
"""
白名單 / 自訂封鎖清單管理小工具

用法：
  python manage.py whitelist add example.com "誤擋了常用服務"
  python manage.py whitelist remove example.com
  python manage.py whitelist list

  python manage.py block add ads.example-manga-app.com "手動追加的廣告網域"
  python manage.py block remove ads.example-manga-app.com
  python manage.py block list

設計原則：單一筆操作失敗只印出錯誤訊息，不會讓程式整個崩潰（best effort）。
"""

import os
import re
import sys
import time
import requests

CF_ACCOUNT_ID = os.environ.get("CF_ACCOUNT_ID")
CF_API_TOKEN = os.environ.get("CF_API_TOKEN")
D1_DATABASE_ID = os.environ.get("D1_DATABASE_ID")
CF_API_BASE = "https://api.cloudflare.com/client/v4"

DOMAIN_RE = re.compile(r"^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)+$")

TABLE_MAP = {"whitelist": "custom_whitelist", "block": "custom_blocklist"}


def check_env():
    missing = [k for k in ("CF_ACCOUNT_ID", "CF_API_TOKEN", "D1_DATABASE_ID") if not os.environ.get(k)]
    if missing:
        print(f"❌ 缺少環境變數：{', '.join(missing)}")
        print("   請先 export CF_ACCOUNT_ID / CF_API_TOKEN / D1_DATABASE_ID 再執行")
        sys.exit(1)


def d1_query(sql: str, params: list | None = None):
    body = {"sql": sql}
    if params:
        body["params"] = params
    resp = requests.post(
        f"{CF_API_BASE}/accounts/{CF_ACCOUNT_ID}/d1/database/{D1_DATABASE_ID}/query",
        headers={"Authorization": f"Bearer {CF_API_TOKEN}", "Content-Type": "application/json"},
        json=body, timeout=30,
    )
    data = resp.json()
    if not data.get("success"):
        raise RuntimeError(str(data.get("errors")))
    return data["result"][0]["results"]


def cmd_add(table_key: str, domain: str, reason: str):
    domain = domain.strip().lower()
    if not DOMAIN_RE.match(domain):
        print(f"❌ '{domain}' 看起來不是合法的網域格式，沒有寫入。請確認拼字（例如是否誤帶了 http:// 或路徑）")
        return
    table = TABLE_MAP[table_key]
    try:
        d1_query(
            f"INSERT INTO {table} (domain, reason, added_at) VALUES (?, ?, ?) "
            f"ON CONFLICT(domain) DO UPDATE SET reason=excluded.reason",
            [domain, reason, str(int(time.time()))],
        )
        print(f"✅ 已加入 {table_key}：{domain}")
        print("   提醒：下次排程同步（或手動觸發 workflow）後才會實際生效")
    except Exception as e:
        print(f"❌ 寫入失敗：{e}")


def cmd_remove(table_key: str, domain: str):
    domain = domain.strip().lower()
    table = TABLE_MAP[table_key]
    try:
        d1_query(f"DELETE FROM {table} WHERE domain = ?", [domain])
        print(f"✅ 已從 {table_key} 移除：{domain}")
    except Exception as e:
        print(f"❌ 移除失敗：{e}")


def cmd_list(table_key: str):
    table = TABLE_MAP[table_key]
    try:
        rows = d1_query(f"SELECT domain, reason, added_at FROM {table} ORDER BY added_at DESC")
        if not rows:
            print(f"（{table_key} 目前是空的）")
            return
        for r in rows:
            print(f"  {r['domain']:<40} {r.get('reason', '')}")
        print(f"共 {len(rows)} 筆")
    except Exception as e:
        print(f"❌ 查詢失敗：{e}")


def main():
    check_env()
    if len(sys.argv) < 3:
        print(__doc__)
        sys.exit(1)

    table_key, action = sys.argv[1], sys.argv[2]
    if table_key not in TABLE_MAP:
        print(f"❌ 未知類型 '{table_key}'，只能是 whitelist 或 block")
        sys.exit(1)

    if action == "add":
        if len(sys.argv) < 4:
            print("❌ 用法：manage.py <whitelist|block> add <domain> [reason]")
            sys.exit(1)
        domain = sys.argv[3]
        reason = sys.argv[4] if len(sys.argv) > 4 else ""
        cmd_add(table_key, domain, reason)
    elif action == "remove":
        if len(sys.argv) < 4:
            print("❌ 用法：manage.py <whitelist|block> remove <domain>")
            sys.exit(1)
        cmd_remove(table_key, sys.argv[3])
    elif action == "list":
        cmd_list(table_key)
    else:
        print(f"❌ 未知操作 '{action}'，只能是 add / remove / list")
        sys.exit(1)


if __name__ == "__main__":
    main()
