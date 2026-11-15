# -*- coding: utf-8 -*-
"""批37 字体缓存只读/清缓存补齐验收 —— 本地 mock 源站。

在批36b mock 基础上新增字体资源：
  /font/valid.ttf   仓库内 app/src/main/assets/font/number.ttf 副本（合法 TTF）
  /font/big.ttf     33MiB（34603008 字节）伪字体，用于 32MB 上限验证
  /font/poison.zip  zip 字节，经 queryTTF(url) 落入共享字体缓存后测试
                    unzipFile 默认输出（同目录）是否被写策略拒绝
  /arch/book.zip    与 /book.zip 相同的压缩包（un7zFile 显式输出用例输入）
其余路由沿用批36：/a/cover.jpg /b/cover.jpg /a.jpg /book.zip /book2.zip
/search /book/1.html /toc/1.html /chapter/1.html /source.json

所有请求追加写入 mock_access.log；书源 JS 经 POST /report 回传验收串，
写入 mock_report.log（绕开 UI 截断）。
运行：python qa37_mock_server.py [--port 8926]
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
FONT_PATH = os.path.join(HERE, "qa37_valid.ttf")
PORT = 8926
if "--port" in sys.argv:
    PORT = int(sys.argv[sys.argv.index("--port") + 1])

JPEG_A = b"\xff\xd8\xff\xe0" + (b"A" * 1996)
JPEG_B = b"\xff\xd8\xff\xe0" + (b"B" * 1996)
JPEG_PLAIN = b"\xff\xd8\xff\xe0" + (b"J" * 1496)

# 32MiB 上限之上 1MiB（Content-Length 快速拒绝路径）
BIG_FONT = b"\x00" * (33 * 1024 * 1024)

with open(FONT_PATH, "rb") as _f:
    VALID_FONT = _f.read()


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
        elif base == "/arch/book.zip":
            self._send(ZIP_BYTES, "application/zip")
        elif base == "/font/valid.ttf":
            self._send(VALID_FONT, "font/ttf")
        elif base == "/font/big.ttf":
            self._send(BIG_FONT, "font/ttf")
        elif base == "/font/poison.zip":
            self._send(ZIP_BYTES, "application/zip")
        elif base == "/search":
            self._send(SEARCH_HTML.encode("utf-8"), "text/html; charset=utf-8")
        elif base == "/book/1.html":
            self._send(BOOK_HTML.encode("utf-8"), "text/html; charset=utf-8")
        elif base == "/toc/1.html":
            self._send(TOC_HTML.encode("utf-8"), "text/html; charset=utf-8")
        elif base == "/chapter/1.html":
            self._send(CONTENT_HTML.encode("utf-8"), "text/html; charset=utf-8")
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
    for p in (LOG_PATH, REPORT_PATH):
        if os.path.exists(p):
            os.remove(p)
    srv = ThreadingHTTPServer(("0.0.0.0", PORT), Handler)
    print("QA37 mock server on 0.0.0.0:%d, log=%s" % (PORT, LOG_PATH), flush=True)
    srv.serve_forever()


if __name__ == "__main__":
    threading.current_thread().name = "qa37-mock"
    main()
