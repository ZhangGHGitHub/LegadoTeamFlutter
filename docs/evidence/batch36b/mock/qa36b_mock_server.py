# -*- coding: utf-8 -*-
"""批36 文件 API 上游对齐验收 —— 本地 mock 源站。

用途：为设备上的书源提供可判定内容与可审计访问日志。
路由：
  /a/cover.jpg   内容以 A 填充（2000B，前缀 JPEG SOI）
  /b/cover.jpg   内容以 B 填充（2000B，前缀 JPEG SOI）
  /a.jpg         普通 jpg（带 ,{"type":"jpg"} 选项剥离测试用）
  /book.zip      含 qa36/1.txt、qa36/2.txt 的压缩包（解压/删目录测试用）
  /search?q=...  搜索页 HTML
  /book/1.html   书籍信息页
  /toc/1.html    目录页
  /chapter/1.html 正文页
  /source.json   书源 JSON（供 UI 导入备用）
所有请求追加写入 mock_access.log（同一目录）。
运行：python qa36_mock_server.py [--port 8926]
"""

import io
import os
import sys
import threading
import zipfile
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))
LOG_PATH = os.path.join(HERE, "mock_access.log")
REPORT_PATH = os.path.join(HERE, "mock_report.log")
PORT = 8926
if "--port" in sys.argv:
    PORT = int(sys.argv[sys.argv.index("--port") + 1])

JPEG_A = b"\xff\xd8\xff\xe0" + (b"A" * 1996)
JPEG_B = b"\xff\xd8\xff\xe0" + (b"B" * 1996)
JPEG_PLAIN = b"\xff\xd8\xff\xe0" + (b"J" * 1496)


def build_zip() -> bytes:
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED) as zf:
        zf.writestr("qa36/1.txt", "QA36 line one\n")
        zf.writestr("qa36/2.txt", "QA36 line two\n")
    return buf.getvalue()


ZIP_BYTES = build_zip()


def build_zip_root() -> bytes:
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED) as zf:
        zf.writestr("1.txt", "QA36 line one\n")
        zf.writestr("2.txt", "QA36 line two\n")
    return buf.getvalue()


ZIP2_BYTES = build_zip_root()

SEARCH_HTML = """<html><body>
<div class="item">
  <a class="link" href="/book/1.html">book</a>
  <span class="skip">skip</span>
</div>
</body></html>"""

BOOK_HTML = """<html><body>
<div class="name">QA36 Mock Book</div>
<div class="author">QA36 Mock Author</div>
<div class="intro">QA36 mock book for file api acceptance.</div>
<a class="toc" href="/toc/1.html">toc</a>
</body></html>"""

TOC_HTML = """<html><body>
<div class="ch"><a href="/chapter/1.html">Chapter 1</a></div>
</body></html>"""

CONTENT_HTML = """<html><body>
<div id="content">QA36 mock chapter content line 1.<br>line 2.</div>
</body></html>"""

SOURCE_JSON = """{
  "bookSourceUrl": "http://192.168.100.52:8926",
  "bookSourceName": "QA36 文件API源",
  "bookSourceType": 0,
  "enabled": true,
  "enabledExplore": false,
  "searchUrl": "http://192.168.100.52:8926/search?q={{key}}",
  "ruleSearch": {
    "bookList": "class.item",
    "name": "@js:参见 QA36 脚本",
    "author": "@js:参见 QA36 脚本",
    "bookUrl": "class.link@href"
  },
  "ruleBookInfo": {
    "name": "class.name@text",
    "author": "class.author@text",
    "intro": "class.intro@text",
    "tocUrl": "class.toc@href"
  },
  "ruleToc": {
    "chapterList": "class.ch",
    "chapterName": "tag.a@text",
    "chapterUrl": "tag.a@href"
  },
  "ruleContent": {
    "content": "id.content@html"
  }
}"""


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def _log(self, line: str) -> None:
        with open(LOG_PATH, "a", encoding="utf-8") as f:
            f.write(line + "\n")

    def _send(self, body: bytes, ctype: str = "application/octet-stream") -> None:
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):  # noqa: N802
        path = self.path
        self._log("GET %s" % path)
        base = path.split("?", 1)[0]
        if base == "/a/cover.jpg":
            self._send(JPEG_A, "image/jpeg")
        elif base == "/b/cover.jpg":
            self._send(JPEG_B, "image/jpeg")
        elif base == "/a.jpg":
            self._send(JPEG_PLAIN, "image/jpeg")
        elif base == "/book.zip":
            self._send(ZIP_BYTES, "application/zip")
        elif base == "/book2.zip":
            self._send(ZIP2_BYTES, "application/zip")
        elif base == "/search":
            self._send(SEARCH_HTML.encode("utf-8"), "text/html; charset=utf-8")
        elif base == "/book/1.html":
            self._send(BOOK_HTML.encode("utf-8"), "text/html; charset=utf-8")
        elif base == "/toc/1.html":
            self._send(TOC_HTML.encode("utf-8"), "text/html; charset=utf-8")
        elif base == "/chapter/1.html":
            self._send(CONTENT_HTML.encode("utf-8"), "text/html; charset=utf-8")
        elif base == "/source.json":
            self._send(SOURCE_JSON.encode("utf-8"), "application/json; charset=utf-8")
        else:
            self.send_response(404)
            self.send_header("Content-Length", "0")
            self.end_headers()

    def do_POST(self):  # noqa: N802
        """书源 JS 通过 java.post 回传验收字符串，绕开 UI 截断。"""
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length).decode("utf-8", "replace")
        self._log("POST %s" % self.path)
        if self.path.split("?", 1)[0] == "/report":
            with open(REPORT_PATH, "a", encoding="utf-8") as f:
                f.write(body + "\n")
        resp = b"ok"
        self.send_response(200)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(resp)))
        self.end_headers()
        self.wfile.write(resp)

    def log_message(self, fmt, *args):  # 静音 stderr，改走自有日志
        pass


def main() -> None:
    if os.path.exists(LOG_PATH):
        os.remove(LOG_PATH)
    srv = ThreadingHTTPServer(("0.0.0.0", PORT), Handler)
    print("QA36 mock server on 0.0.0.0:%d, log=%s" % (PORT, LOG_PATH), flush=True)
    srv.serve_forever()


if __name__ == "__main__":
    threading.current_thread().name = "qa36-mock"
    main()
