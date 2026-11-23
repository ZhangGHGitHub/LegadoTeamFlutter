#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""批21 RSS WebView 宿主桥设备验收 mock 服务。

监听 0.0.0.0:18082（设备经 LAN 192.168.100.52:18082 访问）。
- /rss_bridge.xml   验收用 RSS 2.0 feed（各场景文章 description 内联 HTML）
- /echo             返回 hello；记录完整请求头（含源 header / UA）
- /urlmode.html     singleUrl URL 模式页面
- /article/<n>.html 普通文章页（点击链接/回归用）
- /pixel.png        1x1 PNG（正常图片保留验证）
- /refresh_target.html  本机 meta refresh 目标（辅助定位是否发生跳转）
所有请求写入 mock/requests.jsonl。
"""
import json
import os
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
LOG_PATH = os.path.join(BASE_DIR, "requests.jsonl")
HOST = "0.0.0.0"
PORT = 18082
HOST_IP = "192.168.100.52"

_lock = threading.Lock()

PNG_1X1 = bytes.fromhex(
    "89504e470d0a1a0a0000000d49484452000000010000000108060000001f15c4"
    "890000000d49444154789c6360000000020001e221bc330000000049454e44ae"
    "426082"
)


def log_request(handler, body: bytes) -> None:
    entry = {
        "ts": time.strftime("%Y-%m-%d %H:%M:%S"),
        "method": handler.command,
        "path": handler.path,
        "headers": {k: v for k, v in handler.headers.items()},
        "body_len": len(body),
        "body_head": body[:512].decode("utf-8", "replace"),
    }
    with _lock:
        with open(LOG_PATH, "a", encoding="utf-8") as fh:
            fh.write(json.dumps(entry, ensure_ascii=False) + "\n")


def item(title: str, link: str, description: str, guid: str, pub_date: str) -> str:
    safe_desc = description.replace("]]>", "]]&gt;")
    return f"""
    <item>
      <title>{title}</title>
      <link>{link}</link>
      <guid isPermaLink="false">{guid}</guid>
      <pubDate>{pub_date}</pubDate>
      <description><![CDATA[{safe_desc}]]></description>
    </item>"""


BRIDGE_DESC = """
<div id="bridge-article">
  <h3 id="bridge-h">BRIDGE base body</h3>
  <p>正文可见 BRIDGE-BODY</p>
  <img id="bridge-img" src="http://192.168.100.52:18082/pixel.png">
</div>
"""

CLEAN_DESC = """
<h3 id="clean-h">CLEAN-BODY 正文可见</h3>
<script>document.title='HACKED'</script>
<svg><style>&lt;script&gt;document.title='MXSS'&lt;/script&gt;</style></svg>
<meta http-equiv=refresh content="0;url=https://example.com">
<img src=x onerror="document.title='ONERR'">
<img id="ok-img" src="http://192.168.100.52:18082/pixel.png">
<style>#clean-h{color:rgb(0,128,0)}</style>
"""

NORMAL_DESC = """
<h3 id="normal-h">NORMAL-BODY 普通文章</h3>
<p>回归正文</p>
<img id="normal-img" src="http://192.168.100.52:18082/pixel.png">
<p><a id="normal-link" href="http://192.168.100.52:18082/article/3.html">NORMAL-LINK</a></p>
<style>#normal-h{color:rgb(0,0,200)}</style>
"""

SEC_DESC = """
<h3 id="sec-h">SEC-BODY 安全探针</h3>
<p>安全探针正文</p>
"""

OVERRIDE_DESC = """
<h3 id="override-h">OVERRIDE-BODY</h3>
<p><a id="blockme" href="http://192.168.100.52:18082/article/blocked.html">BLOCK_ME_LINK</a></p>
<p><a id="oklink" href="http://192.168.100.52:18082/article/allowed.html">ALLOWED_LINK</a></p>
"""

LOG_DESC = """
<h3 id="log-h">LOG-BODY</h3>
<p>showWebLog 验证正文</p>
"""

AJAX_DESC = """
<div id="ajax-article">
  <h3 id="ajax-h">AJAX-BODY</h3>
  <p>ajaxAwait 验证正文</p>
</div>
"""

RSS_XML = f"""<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0">
  <channel>
    <title>QA RSS bridge feed</title>
    <link>http://192.168.100.52:18082/</link>
    <description>batch21 acceptance</description>
    <language>zh-cn</language>
    {item("QA-BRIDGE-基础", "http://192.168.100.52:18082/article/1.html", BRIDGE_DESC, "qa-bridge-1", "Mon, 26 Oct 2026 10:00:00 +0800")}
    {item("QA-CLEAN-清洗", "http://192.168.100.52:18082/article/2.html", CLEAN_DESC, "qa-clean-2", "Mon, 26 Oct 2026 10:01:00 +0800")}
    {item("QA-NORMAL-普通", "http://192.168.100.52:18082/article/3.html", NORMAL_DESC, "qa-normal-3", "Mon, 26 Oct 2026 10:02:00 +0800")}
    {item("QA-SEC-安全探针", "http://192.168.100.52:18082/article/4.html", SEC_DESC, "qa-sec-4", "Mon, 26 Oct 2026 10:03:00 +0800")}
    {item("QA-OVERRIDE-拦截", "http://192.168.100.52:18082/article/5.html", OVERRIDE_DESC, "qa-override-5", "Mon, 26 Oct 2026 10:04:00 +0800")}
    {item("QA-LOG-日志", "http://192.168.100.52:18082/article/6.html", LOG_DESC, "qa-log-6", "Mon, 26 Oct 2026 10:05:00 +0800")}
    {item("QA-AJAX-回环", "http://192.168.100.52:18082/article/7.html", AJAX_DESC, "qa-ajax-7", "Mon, 26 Oct 2026 10:06:00 +0800")}
  </channel>
</rss>
"""

URLMODE_HTML = """<!DOCTYPE html>
<html><head><meta charset="utf-8"><title>URLMODE-PAGE</title></head>
<body>
<h3 id="urlmode">URL MODE BODY</h3>
<p id="urlmode-wait">waiting</p>
</body></html>
"""

REFRESH_TARGET_HTML = """<!DOCTYPE html>
<html><head><meta charset="utf-8"><title>REFRESH-TARGET</title></head>
<body><h3 id="refresh-target">REFRESH TARGET REACHED</h3></body></html>
"""

ARTICLE_HTML = """<!DOCTYPE html>
<html><head><meta charset="utf-8"><title>ARTICLE {n}</title></head>
<body><h3 id="article-{n}">ARTICLE {n} BODY</h3></body></html>
"""


class Handler(BaseHTTPRequestHandler):
    server_version = "QAMock/1.0"

    def _read_body(self) -> bytes:
        length = int(self.headers.get("Content-Length") or 0)
        return self.rfile.read(length) if length > 0 else b""

    def _send(self, code: int, body: bytes, content_type: str) -> None:
        self.send_response(code)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        body = self._read_body()
        log_request(self, body)
        parsed = urlparse(self.path)
        path = parsed.path
        if path == "/echo":
            self._send(200, b"hello", "text/plain; charset=utf-8")
        elif path == "/rss_bridge.xml":
            self._send(200, RSS_XML.encode("utf-8"), "application/rss+xml; charset=utf-8")
        elif path == "/urlmode.html":
            self._send(200, URLMODE_HTML.encode("utf-8"), "text/html; charset=utf-8")
        elif path == "/refresh_target.html":
            self._send(200, REFRESH_TARGET_HTML.encode("utf-8"), "text/html; charset=utf-8")
        elif path == "/pixel.png":
            self._send(200, PNG_1X1, "image/png")
        elif path.startswith("/article/") and path.endswith(".html"):
            n = path[len("/article/"):-len(".html")] or "0"
            self._send(200, ARTICLE_HTML.format(n=n).encode("utf-8"), "text/html; charset=utf-8")
        else:
            self._send(404, b"not found", "text/plain; charset=utf-8")

    def do_POST(self):
        body = self._read_body()
        log_request(self, body)
        self._send(200, b"hello-post", "text/plain; charset=utf-8")

    def log_message(self, fmt, *args):
        # 默认 stderr 日志已由 requests.jsonl 覆盖；保留一行简洁输出便于实时观察
        print("[mock] " + (fmt % args), flush=True)


def main() -> None:
    os.makedirs(os.path.dirname(LOG_PATH), exist_ok=True)
    server = ThreadingHTTPServer((HOST, PORT), Handler)
    print(f"[mock] listening on {HOST}:{PORT}, log={LOG_PATH}", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
