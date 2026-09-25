# -*- coding: utf-8 -*-
"""swd 轮 W2 夹具服务器（目录派生字段同步验证，2026-09-25，端口 8093）。

两个书源（同分组 R1W、同名同作者书「R1换源验证书2」）：
  SWA  3 章目录（第一章 一 / 第二章 二 / 第三章 三）
  SWB  5 章目录（第一章 甲 / 第二章 乙 / 第三章 丙 / 第四章 丁 / 第五章 戊）

两源目录条数不同（3 vs 5）：换源 SWA→SWB 后，books.totalChapterNum 必须
从 3 同步为 5、latestChapterTitle 必须从「第三章 三」同步为「第五章 戊」
（与目录页显示对照）——若派生字段不同步，值将停留在旧源，断言可区分。

端点：
  /r1w/sources.json  → 2 个书源（导入用，格式对齐 r1v_switch_server.py）
  /wa|wb/search|detail|toc|content

MuMu NAT：guest 127.0.0.1 → host localhost（与 8092 同路），无需 adb reverse。
"""
from __future__ import annotations

import argparse
import json
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

LOG_LOCK = threading.Lock()
LOG_FP = None
PORT = 8093
URL_HOST = "127.0.0.1"
# 换源取消路径验证：--delay 令 /wb/detail 与 /wb/toc（现场抓取链）响应前
# 睡眠 N 秒，拉长 applying 窗口便于观测/取消；默认 0 不影响 ② 快速换源。
DELAY = 0.0

BOOK_NAME = "R1换源验证书2"
BOOK_AUTHOR = "R1作者2"

CHAPTERS_A = ["第一章 一", "第二章 二", "第三章 三"]
CHAPTERS_B = ["第一章 甲", "第二章 乙", "第三章 丙", "第四章 丁", "第五章 戊"]


def log_event(kind: str, **fields) -> None:
    rec = {"ts": round(time.time(), 3), "kind": kind, **fields}
    line = json.dumps(rec, ensure_ascii=False)
    with LOG_LOCK:
        print(line, flush=True)
        if LOG_FP is not None:
            LOG_FP.write(line + "\n")
            LOG_FP.flush()


def host(port: int) -> str:
    return f"http://{URL_HOST}:{port}"


def html_list(href: str) -> bytes:
    return (
        f'<html><body><div class="book-item">'
        f'<a class="name" href="{href}">{BOOK_NAME}</a>'
        f'<span class="author">{BOOK_AUTHOR}</span>'
        f'<span class="kind">玄幻</span></div></body></html>'
    ).encode("utf-8")


def build_sources(port: int) -> list[dict]:
    h = host(port)
    out = []
    for tag, prefix, chapters in (
        ("SWA", "wa", CHAPTERS_A),
        ("SWB", "wb", CHAPTERS_B),
    ):
        out.append({
            "bookSourceUrl": f"{h}/r1w/home/{'a' if tag == 'SWA' else 'b'}",
            "bookSourceName": tag,
            "bookSourceGroup": "R1W",
            "bookSourceType": 0,
            "enabled": True,
            "searchUrl": f"{h}/{prefix}/search?kw={{{{key}}}}",
            "ruleSearch": {
                "bookList": "class.book-item",
                "name": "class.name@text",
                "author": "class.author@text",
                "bookUrl": "class.name@href",
            },
            "ruleBookInfo": {
                "name": "class.title@text",
                "author": "class.author@text",
                "tocUrl": "class.toc@href",
            },
            "ruleToc": {
                "chapterList": "class.ch",
                "chapterName": "tag.a@text",
                "chapterUrl": "tag.a@href",
            },
            "ruleContent": {"content": "class.c@text"},
        })
    return out


def toc_html(prefix: str, chapters: list[str]) -> bytes:
    rows = "".join(
        f'<div class="ch"><a href="/{prefix}/content?i={i}">{t}</a></div>'
        for i, t in enumerate(chapters)
    )
    return f"<html><body>{rows}</body></html>".encode("utf-8")


def content_html(prefix: str, i: int) -> bytes:
    chapters = CHAPTERS_A if prefix == "wa" else CHAPTERS_B
    tag = "SWA" if prefix == "wa" else "SWB"
    t = chapters[i]
    return (
        f'<html><body><div class="c">{tag}正文『{t}』标准段落内容'
        f"{BOOK_NAME}</div></body></html>"
    ).encode("utf-8")


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        pass

    def do_GET(self):  # noqa: N802
        parsed = urlparse(self.path)
        path = parsed.path
        q = parse_qs(parsed.query)
        h = host(PORT)
        log_event("req", path=self.path)

        if path == "/r1w/sources.json":
            body = json.dumps(build_sources(PORT), ensure_ascii=False).encode("utf-8")
            self._send(200, body, "application/json; charset=utf-8")
            log_event("sources_json")
            return

        if path.startswith("/marker/"):
            log_event("marker", name=path[len("/marker/"):])
            self._send(200, b"ok", "text/plain")
            return

        if path == "/wa/search":
            self._send(200, html_list("/wa/detail"), "text/html; charset=utf-8")
            return
        if path == "/wa/detail":
            body = (
                f'<html><body><div class="title">{BOOK_NAME}</div>'
                f'<div class="author">{BOOK_AUTHOR}</div>'
                f'<a class="toc" href="/wa/toc"/></body></html>'
            ).encode("utf-8")
            self._send(200, body, "text/html; charset=utf-8")
            return
        if path == "/wa/toc":
            self._send(200, toc_html("wa", CHAPTERS_A), "text/html; charset=utf-8")
            return
        if path == "/wa/content":
            self._send(200, content_html("wa", int((q.get("i") or ["0"])[0])),
                       "text/html; charset=utf-8")
            return

        if path == "/wb/search":
            self._send(200, html_list("/wb/detail"), "text/html; charset=utf-8")
            return
        if path == "/wb/detail":
            if DELAY:
                time.sleep(DELAY)
            body = (
                f'<html><body><div class="title">{BOOK_NAME}</div>'
                f'<div class="author">{BOOK_AUTHOR}</div>'
                f'<a class="toc" href="/wb/toc"/></body></html>'
            ).encode("utf-8")
            self._send(200, body, "text/html; charset=utf-8")
            return
        if path == "/wb/toc":
            if DELAY:
                time.sleep(DELAY)
            self._send(200, toc_html("wb", CHAPTERS_B), "text/html; charset=utf-8")
            return
        if path == "/wb/content":
            self._send(200, content_html("wb", int((q.get("i") or ["0"])[0])),
                       "text/html; charset=utf-8")
            return

        self._send(200, b"ok", "text/plain")
        log_event("misc", path=path)

    def _send(self, code: int, body: bytes, ctype: str) -> bool:
        try:
            self.send_response(code)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return True
        except (BrokenPipeError, ConnectionResetError, OSError):
            return False


class Server(ThreadingHTTPServer):
    daemon_threads = True
    request_queue_size = 128
    allow_reuse_address = True


def main():
    global LOG_FP, PORT
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=8093)
    ap.add_argument("--log", required=True)
    ap.add_argument("--url-host", default="127.0.0.1")
    ap.add_argument("--delay", type=float, default=0.0,
                    help="/wb/detail|toc 响应前睡眠秒数（拉长换源 applying 窗口）")
    args = ap.parse_args()
    PORT = args.port
    globals()["URL_HOST"] = args.url_host
    globals()["DELAY"] = args.delay
    LOG_FP = Path(args.log).open("w", encoding="utf-8")
    srv = Server(("0.0.0.0", PORT), Handler)
    log_event("server_start", port=PORT, mode="w2")
    try:
        srv.serve_forever(poll_interval=0.2)
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    import sys
    sys.exit(main())
