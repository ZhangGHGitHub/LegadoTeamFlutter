#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""批18a 设备验收用 Mock WebDAV 服务（仅本机回环，独立于被测应用）。

监听 127.0.0.1:18081，模拟 /dav/ 根目录：
  /dav/                     -> 目录（含 books/）
  /dav/books/               -> 目录（含 txt-sample.txt / txt-default.txt）
  /dav/books/txt-sample.txt -> 中文 TXT 正文
  /dav/books/txt-default.txt-> 中文 TXT 正文（供默认 WebDAV 导入用）

支持 PROPFIND(Depth 0/1) / GET / HEAD / PUT / DELETE / MKCOL，
Basic Auth 接受任意凭据（记录到日志便于核对）。请求日志逐行写
dav_requests.log，UTF-8 无 BOM。
"""

import base64
import hashlib
import os
import sys
import threading
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import unquote, urlsplit

HOST = "0.0.0.0"
PORT = 18081
BASE = "/dav"
LOG_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "dav_requests.log")
LOG_LOCK = threading.Lock()

SAMPLE_TXT = """第一章 山雨欲来

　　暮色压在青石镇上空，风从山脊上翻过来，带着潮湿的土腥气。
　　林砚把最后一页账本合上，指腹在封皮上停了停，听见门外有人敲门。

第二章 旧客

　　“林掌柜，别来无恙。”来人披着蓑衣，斗笠压得很低。
　　林砚看了他很久，才认出来人是三年前离开镇子的沈舟。

第三章 灯下

　　油灯的火苗跳了跳，把两个人的影子拉得很长。
　　沈舟从怀里取出一封信，信封上没有落款，只有一枚褪色的火漆印。

第四章 夜行

　　子时过后，雨势渐小。两人沿着河堤往镇外走，脚下的石板被雨水洗得发亮。
　　远处的山影里，隐约有一星灯火。

第五章 归途

　　天亮时，林砚站在镇口回望。山路尽头空无一人。
　　他收起伞，转身走进渐渐热闹起来的街市。
""".strip("\n")

DEFAULT_TXT = """默认账号测试书

　　这是通过默认 WebDAV（同步账号，id=-1）导入的验证文本。
　　它的 origin 应为 webDav::<完整 url>，不带 serverID 属性后缀。

　　第一段：山中方一日，世上已千年。
　　第二段：纸上得来终觉浅，绝知此事要躬行。
　　第三段：用于验证远程书库默认服务器导入链路。

　　全文结束。
""".strip("\n")


def now_http_date() -> str:
    return datetime.now(timezone.utc).strftime("%a, %d %b %Y %H:%M:%S GMT")


# 虚拟文件系统：路径 -> (bytes, mtime, is_dir)
def build_fs():
    sample = SAMPLE_TXT.encode("utf-8")
    default = DEFAULT_TXT.encode("utf-8")
    return {
        BASE + "/": (b"", now_http_date(), True),
        BASE + "/books/": (b"", now_http_date(), True),
        BASE + "/books/txt-sample.txt": (sample, now_http_date(), False),
        BASE + "/books/txt-default.txt": (default, now_http_date(), False),
    }


FS = build_fs()
FS_LOCK = threading.Lock()


def etag_of(data: bytes) -> str:
    return '"' + hashlib.md5(data).hexdigest() + '"'


def xml_escape(text: str) -> str:
    return (
        text.replace("&", "&amp;")
        .replace("<", "&lt;")
        .replace(">", "&gt;")
        .replace('"', "&quot;")
    )


def propfind_xml(path: str, depth: int) -> str:
    entries = []
    norm = path if path.endswith("/") else path + "/"
    if norm in FS:
        entries.append(norm)
    if depth != 0:
        for p in sorted(FS):
            if p != norm and p.startswith(norm):
                rest = p[len(norm):]
                if "/" not in rest.rstrip("/"):
                    entries.append(p)

    parts = ['<?xml version="1.0" encoding="utf-8"?>', '<D:multistatus xmlns:D="DAV:">']
    for p in entries:
        data, mtime, is_dir = FS[p]
        display = p.rstrip("/").rsplit("/", 1)[-1] if p != BASE + "/" else "dav"
        parts.append("  <D:response>")
        parts.append("    <D:href>%s</D:href>" % xml_escape(p))
        parts.append("    <D:propstat>")
        parts.append("      <D:prop>")
        parts.append("        <D:displayname>%s</D:displayname>" % xml_escape(display))
        parts.append("        <D:getlastmodified>%s</D:getlastmodified>" % mtime)
        if is_dir:
            parts.append("        <D:resourcetype><D:collection/></D:resourcetype>")
            parts.append("        <D:getcontentlength>0</D:getcontentlength>")
        else:
            parts.append("        <D:resourcetype/>")
            parts.append("        <D:getcontentlength>%d</D:getcontentlength>" % len(data))
            parts.append("        <D:getetag>%s</D:getetag>" % etag_of(data))
        parts.append("      </D:prop>")
        parts.append("      <D:status>HTTP/1.1 200 OK</D:status>")
        parts.append("    </D:propstat>")
        parts.append("  </D:response>")
    parts.append("</D:multistatus>")
    return "\n".join(parts)


def log_line(handler, extra=""):
    auth = handler.headers.get("Authorization", "")
    user = ""
    if auth.lower().startswith("basic "):
        try:
            raw = base64.b64decode(auth.split(" ", 1)[1]).decode("utf-8", "replace")
            user = raw.split(":", 1)[0]
        except Exception:
            user = "<decode-error>"
    line = "[%s] %s %s depth=%s user=%s %s" % (
        datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
        handler.command,
        handler.path,
        handler.headers.get("Depth", "-"),
        user or "<none>",
        extra,
    )
    with LOG_LOCK:
        with open(LOG_PATH, "a", encoding="utf-8", newline="\n") as f:
            f.write(line + "\n")
    print(line, flush=True)


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "MockWebDAV/1.0"

    def _path(self):
        # 归并连续斜杠：Rust 侧 full_url 为字符串直拼，url 与 remote_dir
        # 可能产生 `//`（如 url 尾斜杠 + remote_dir 前斜杠）。
        raw = unquote(urlsplit(self.path).path)
        while "//" in raw:
            raw = raw.replace("//", "/")
        return raw

    def _send_body(self, code, body: bytes, content_type="text/plain; charset=utf-8", head_only=False):
        self.send_response(code)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if not head_only:
            self.wfile.write(body)

    def do_OPTIONS(self):
        log_line(self)
        self.send_response(200)
        self.send_header("DAV", "1,2")
        self.send_header("Allow", "OPTIONS, GET, HEAD, PUT, DELETE, PROPFIND, MKCOL")
        self.send_header("Content-Length", "0")
        self.end_headers()

    def do_PROPFIND(self):
        path = self._path()
        try:
            depth = int(self.headers.get("Depth", "1") or "1")
        except ValueError:
            depth = 1
        # 读掉请求体，避免 keep-alive 连接残留
        try:
            length = int(self.headers.get("Content-Length", "0") or "0")
            if length:
                self.rfile.read(length)
        except Exception:
            pass
        if path not in FS:
            log_line(self, "404")
            self._send_body(404, b"not found")
            return
        xml = propfind_xml(path, depth)
        body = xml.encode("utf-8")
        log_line(self, "207 entries=%d" % xml.count("<D:response>"))
        self.send_response(207)
        self.send_header("Content-Type", 'application/xml; charset="utf-8"')
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        self._get_or_head(head_only=False)

    def do_HEAD(self):
        self._get_or_head(head_only=True)

    def _get_or_head(self, head_only: bool):
        path = self._path()
        entry = FS.get(path)
        if entry is None or entry[2]:
            log_line(self, "404")
            self._send_body(404, b"not found", head_only=head_only)
            return
        data, mtime, _ = entry
        log_line(self, "200 bytes=%d" % len(data))
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("ETag", etag_of(data))
        self.send_header("Last-Modified", mtime)
        self.end_headers()
        if not head_only:
            self.wfile.write(data)

    def do_PUT(self):
        path = self._path()
        try:
            length = int(self.headers.get("Content-Length", "0") or "0")
            data = self.rfile.read(length) if length else b""
        except Exception:
            data = b""
        with FS_LOCK:
            FS[path] = (data, now_http_date(), False)
        log_line(self, "201 bytes=%d" % len(data))
        self._send_body(201, b"")

    def do_DELETE(self):
        path = self._path()
        with FS_LOCK:
            existed = FS.pop(path, None) is not None
        log_line(self, "204" if existed else "404")
        self.send_response(204 if existed else 404)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def do_MKCOL(self):
        path = self._path()
        with FS_LOCK:
            FS.setdefault(path.rstrip("/") + "/", (b"", now_http_date(), True))
        log_line(self, "201")
        self._send_body(201, b"")

    def log_message(self, fmt, *args):
        # 抑制默认 stderr 访问日志（统一写 dav_requests.log）
        pass


def main():
    open(LOG_PATH, "w", encoding="utf-8").close()
    server = ThreadingHTTPServer((HOST, PORT), Handler)
    print("Mock WebDAV listening on http://%s:%d%s/" % (HOST, PORT, BASE), flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
