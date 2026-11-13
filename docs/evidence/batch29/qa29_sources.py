# -*- coding: utf-8 -*-
"""批29 书源播种/开关控制（走 Web API，令牌 testtoken123）。

用法：
  python qa29_sources.py list
  python qa29_sources.py save <file.json> [...]
  python qa29_sources.py setenabled <url> 0|1
  python qa29_sources.py scenario A|B|C
  python qa29_sources.py delete <url>
"""
import json
import os
import sys
import urllib.request

BASE = "http://192.168.100.63:1122"
TOKEN = "testtoken123"
HERE = os.path.dirname(os.path.abspath(__file__))

URLS = {
    "fast": "http://192.168.100.52:8931/fast",
    "slow": "http://192.168.100.52:8931/slow",
    "badjs": "http://192.168.100.52:8931/badjs",
    "badlogin": "http://192.168.100.52:8931/badlogin",
    "b25": "http://192.168.100.52:8925",
}


def call(path, payload=None, raw=None):
    data = None
    headers = {"x-legado-token": TOKEN}
    if payload is not None:
        data = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        headers["Content-Type"] = "application/json"
    if raw is not None:
        data = raw
    req = urllib.request.Request(BASE + path, data=data, headers=headers, method="POST" if data else "GET")
    with urllib.request.urlopen(req, timeout=20) as resp:
        body = resp.read().decode("utf-8", "replace")
    try:
        return json.loads(body)
    except json.JSONDecodeError:
        return body


def get_sources():
    r = call("/getBookSources")
    data = r.get("data") if isinstance(r, dict) else None
    return data or []


def save_file(name):
    path = name if os.path.isabs(name) else os.path.join(HERE, name)
    with open(path, encoding="utf-8") as f:
        obj = json.load(f)
    r = call("/saveBookSource", payload=obj)
    print("save", obj["bookSourceName"], "->", json.dumps(r, ensure_ascii=False)[:200])
    return r


def set_enabled(url, enabled):
    src = next((s for s in get_sources() if s.get("bookSourceUrl") == url), None)
    if not src:
        print("NOT FOUND", url)
        return
    src["enabled"] = bool(enabled)
    r = call("/saveBookSource", payload=src)
    print("setenabled", url, enabled, "->", json.dumps(r, ensure_ascii=False)[:200])


def delete(url):
    r = call("/deleteBookSources", payload=[url])
    print("delete", url, "->", json.dumps(r, ensure_ascii=False)[:200])


def scenario(name):
    # 先全部关掉，再按场景打开
    for key, url in URLS.items():
        set_enabled(url, 0)
    if name == "A":
        set_enabled(URLS["fast"], 1)
        set_enabled(URLS["slow"], 1)
    elif name == "B":
        set_enabled(URLS["badjs"], 1)
        set_enabled(URLS["badlogin"], 1)
    elif name == "C":
        set_enabled(URLS["fast"], 1)
    elif name == "B1":
        set_enabled(URLS["badjs"], 1)
    elif name == "B2":
        set_enabled(URLS["badlogin"], 1)


def main():
    cmd = sys.argv[1]
    if cmd == "list":
        for s in get_sources():
            print("-", s.get("bookSourceName"), "|", s.get("bookSourceUrl"), "| enabled=", s.get("enabled"))
    elif cmd == "save":
        for name in sys.argv[2:]:
            save_file(name)
    elif cmd == "setenabled":
        set_enabled(sys.argv[2], int(sys.argv[3]))
    elif cmd == "delete":
        delete(sys.argv[2])
    elif cmd == "scenario":
        scenario(sys.argv[2])
    else:
        raise SystemExit(__doc__)


if __name__ == "__main__":
    main()
