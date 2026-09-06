# -*- coding: utf-8 -*-
"""换源变量链 E2E 夹具服务器（R1 追加修复验证，2026-09-06）。

两个书源（同分组 R1V、同名同作者书「R1换源验证书」）：
  R1VA  普通链：search → detail → toc → content 全程无变量依赖（旧源基线）
  R1VB  变量链（对齐修复面）：
    - 搜索期 @put 级联导出 svid=VID123（候选搜索期变量 → T5 透传/persist 落库）
    - bookUrl 为模板 /r1vb/detail?vid={{svid}}（换源详情请求须带候选变量展开）
    - 详情页 @put 导出 tok=TK777（book 级变量），tocUrl 模板 /r1vb/toc?tok={{tok}}
      （换源目录请求须带候选⊕详情导出合并变量展开）
    - content URL 直带 tok 参数（服务端再校验）

服务端强校验：detail 缺 vid=VID123、toc 缺 tok=TK777、content 缺 tok=TK777
一律 400——修复前（变量表恒空）请求会带字面 {{svid}}/{{tok}} 而失败。

端点：
  /r1v/sources.json                 → 2 个书源（分组 R1V）
  /r1va/search|detail|toc|content   → 普通链
  /r1vb/search|detail|toc|content   → 变量链（带校验）
  /marker/<name>                    → 驱动脚本同步标记

证据：JSONL 请求日志（含完整 path+query，可断言变量已展开）。
"""
from __future__ import annotations

import argparse
import json
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlparse, parse_qs

LOG_LOCK = threading.Lock()
LOG_FP = None
PORT = 8092
URL_HOST = "127.0.0.1"

BOOK_NAME = "R1换源验证书"
BOOK_AUTHOR = "R1作者"
VID = "VID123"
TOK = "TK777"

CHAPTERS = [("第一章 起源", "起"), ("第二章 风波", "风"), ("第三章 终局", "终")]


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
        f'<span class="kind">玄幻</span>'
        f'<span class="vid">{VID}</span></div></body></html>'
    ).encode("utf-8")

def build_sources(port: int) -> list[dict]:
    h = host(port)
    return [
        {
            "bookSourceUrl": f"{h}/r1v/home/a",
            "bookSourceName": "R1VA",
            "bookSourceGroup": "R1V",
            "bookSourceType": 0,
            "enabled": True,
            "searchUrl": f"{h}/r1va/search?kw={{{{key}}}}",
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
        },
        {
            "bookSourceUrl": f"{h}/r1v/home/b",
            "bookSourceName": "R1VB",
            "bookSourceGroup": "R1V",
            "bookSourceType": 0,
            "enabled": True,
            "searchUrl": f"{h}/r1vb/search?kw={{{{key}}}}",
            # 搜索期 @put（本解析器后缀语法）：级联变量 svid 随候选导出
            # （T5 透传/persist 落库）；bookUrl 取自 href（内嵌 {{svid}} 模板，
            # 对齐真实书源「URL 规则带变量占位」形态），须在换源详情请求时
            # 用候选变量展开
            "ruleSearch": {
                "bookList": "class.book-item",
                "name": "class.name@text",
                "author": "class.author@text",
                "kind": "class.kind@text@put:{svid:class.vid@text}",
                "bookUrl": "class.name@href",
            },
            # 详情期 @put：tok 进 book 级变量（T3 导出）；tocUrl 模板含 {{tok}}，
            # 须在换源目录请求时用候选⊕详情导出合并变量展开
            "ruleBookInfo": {
                "name": "class.title@text",
                "author": "class.author@text",
                "tocUrl": "class.toc@href@put:{tok:class.tok@text}",
            },
            "ruleToc": {
                "chapterList": "class.ch",
                "chapterName": "tag.a@text",
                "chapterUrl": "tag.a@href",
            },
            "ruleContent": {"content": "class.c@text"},
        },
    ]


def toc_html(prefix: str) -> bytes:
    rows = "".join(
        f'<div class="ch"><a href="/{prefix}/content?i={i}&tok={TOK}">{t}</a></div>'
        for i, (t, _) in enumerate(CHAPTERS)
    )
    return f"<html><body>{rows}</body></html>".encode("utf-8")


def content_html(i: int, tag: str) -> bytes:
    t = CHAPTERS[i][0]
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

        if path == "/r1v/sources.json":
            body = json.dumps(build_sources(PORT), ensure_ascii=False).encode("utf-8")
            self._send(200, body, "application/json; charset=utf-8")
            log_event("sources_json")
            return

        if path.startswith("/marker/"):
            log_event("marker", name=path[len("/marker/"):])
            self._send(200, b"ok", "text/plain")
            return

        if path == "/r1va/search":
            self._send(200, html_list("/r1va/detail"), "text/html; charset=utf-8")
            return
        if path == "/r1va/detail":
            body = (
                f'<html><body><div class="title">{BOOK_NAME}</div>'
                f'<div class="author">{BOOK_AUTHOR}</div>'
                f'<a class="toc" href="/r1va/toc"/></body></html>'
            ).encode("utf-8")
            self._send(200, body, "text/html; charset=utf-8")
            return
        if path == "/r1va/toc":
            self._send(200, toc_html("r1va"), "text/html; charset=utf-8")
            return
        if path == "/r1va/content":
            self._send(200, content_html(int((q.get("i") or ["0"])[0]), "R1VA"),
                       "text/html; charset=utf-8")
            return

        # ── R1VB 变量链（服务端强校验：缺正确变量即 400）──
        if path == "/r1vb/search":
            self._send(200, html_list(f"{h}/r1vb/detail?vid={{{{svid}}}}"),
                       "text/html; charset=utf-8")
            return
        if path == "/r1vb/detail":
            if (q.get("vid") or [""])[0] != VID:
                log_event("reject", kind="detail", got=(q.get("vid") or [""])[0])
                self._send(400, b"vid mismatch", "text/plain")
                return
            body = (
                f'<html><body><div class="title">{BOOK_NAME}</div>'
                f'<div class="author">{BOOK_AUTHOR}</div>'
                f'<span class="tok">{TOK}</span>'
                f'<a class="toc" href="/r1vb/toc?tok={{{{tok}}}}"/></body></html>'
            ).encode("utf-8")
            self._send(200, body, "text/html; charset=utf-8")
            return
        if path == "/r1vb/toc":
            if (q.get("tok") or [""])[0] != TOK:
                log_event("reject", kind="toc", got=(q.get("tok") or [""])[0])
                self._send(400, b"tok mismatch", "text/plain")
                return
            self._send(200, toc_html("r1vb"), "text/html; charset=utf-8")
            return
        if path == "/r1vb/content":
            if (q.get("tok") or [""])[0] != TOK:
                log_event("reject", kind="content", got=(q.get("tok") or [""])[0])
                self._send(400, b"tok mismatch", "text/plain")
                return
            self._send(200, content_html(int((q.get("i") or ["0"])[0]), "R1VB"),
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
        except (BrokenPipeError, ConnectionResetError, ConnectionAbortedError, OSError):
            return False


class Server(ThreadingHTTPServer):
    daemon_threads = True
    request_queue_size = 128
    allow_reuse_address = True


def main():
    global LOG_FP, PORT
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=8092)
    ap.add_argument("--log", required=True)
    ap.add_argument("--url-host", default="127.0.0.1")
    args = ap.parse_args()
    PORT = args.port
    globals()["URL_HOST"] = args.url_host
    LOG_FP = Path(args.log).open("w", encoding="utf-8")
    srv = Server(("0.0.0.0", PORT), Handler)
    log_event("server_start", port=PORT, mode="r1v")
    try:
        srv.serve_forever(poll_interval=0.2)
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    sys.exit(main())
