#!/usr/bin/env python3
"""批40 设备验收用 Mock WebDAV（独立进程，非应用内实现）。

监听 0.0.0.0:18082，支持：
- Basic Auth（任意账号密码均接受；缺失 Authorization 返回 401，用于认证路径取证）
- PUT：写入 mock/remote/<path>，记录日志
- PROPFIND（Depth 0/1）：返回 207 多状态 XML（d:href/displayname/getcontentlength/
  getlastmodified/getetag/resourcetype）
- DELETE：删除并记录
- GET：返回文件内容

请求日志：mock/requests.log（每行 JSON）；远端文件清单：mock/remote_manifest.txt。
"""
import base64
import json
import os
import sys
import threading
import time
import urllib.parse
from email.utils import formatdate
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

BASE = r"D:\OH-WorkSpace\LegadoTeam\legado\tmp_debug\device_acceptance_20261029_batch40\mock"
REMOTE = os.path.join(BASE, "remote")
REQUESTS_LOG = os.path.join(BASE, "requests.log")
MANIFEST = os.path.join(BASE, "remote_manifest.txt")
LOCK = threading.Lock()


def log_line(entry):
    with LOCK:
        with open(REQUESTS_LOG, "a", encoding="utf-8") as f:
            f.write(json.dumps(entry, ensure_ascii=False) + "\n")


def write_manifest():
    with LOCK:
        lines = []
        for root, _dirs, files in os.walk(REMOTE):
            for name in sorted(files):
                full = os.path.join(root, name)
                rel = os.path.relpath(full, REMOTE).replace("\\", "/")
                lines.append(f"{rel}\t{os.path.getsize(full)}\t{time.strftime('%Y-%m-%d %H:%M:%S', time.localtime(os.path.getmtime(full)))}")
        with open(MANIFEST, "w", encoding="utf-8") as f:
            f.write("\n".join(lines) + ("\n" if lines else ""))


def xml_escape(text):
    return (text.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
            .replace('"', "&quot;"))


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "MockWebDAV/1.0"

    def log_message(self, fmt, *args):
        pass  # 自定义日志

    def _auth_ok(self):
        auth = self.headers.get("Authorization")
        return bool(auth and auth.startswith("Basic "))

    def _record(self, method, status, size=0):
        auth = self.headers.get("Authorization") or ""
        user = ""
        if auth.startswith("Basic "):
            try:
                user = base64.b64decode(auth[6:]).decode("utf-8", "replace")
            except Exception:
                user = "<decode-error>"
        entry = {
            "ts": time.strftime("%Y-%m-%d %H:%M:%S"),
            "method": method,
            "raw_path": self.path,
            "path": urllib.parse.unquote(urllib.parse.urlsplit(self.path).path),
            "depth": self.headers.get("Depth", ""),
            "auth": user,
            "body_size": size,
            "status": status,
        }
        log_line(entry)

    def _send(self, status, body=b"", ctype="application/xml; charset=utf-8", extra=None):
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        if extra:
            for k, v in extra.items():
                self.send_header(k, v)
        self.end_headers()
        if body and self.command != "HEAD":
            self.wfile.write(body)

    def _fs_path(self):
        path = urllib.parse.unquote(urllib.parse.urlsplit(self.path).path)
        rel = path.lstrip("/")
        # 防目录穿越
        parts = [p for p in rel.split("/") if p not in ("", ".")]
        if any(p == ".." for p in parts):
            return None, None
        return os.path.join(REMOTE, *parts), parts

    def do_PUT(self):
        if not self._auth_ok():
            self._record("PUT", 401)
            self._send(401, b"unauthorized", extra={"WWW-Authenticate": 'Basic realm="mock"'})
            return
        length = int(self.headers.get("Content-Length") or 0)
        data = self.rfile.read(length) if length else b""
        full, parts = self._fs_path()
        if full is None:
            self._record("PUT", 400, len(data))
            self._send(400, b"bad path")
            return
        os.makedirs(os.path.dirname(full) or REMOTE, exist_ok=True)
        existed = os.path.exists(full)
        with open(full, "wb") as f:
            f.write(data)
        # 额外留档：上传文件名/大小/时间戳
        with LOCK:
            with open(os.path.join(BASE, "put_manifest.log"), "a", encoding="utf-8") as f:
                f.write(f"{time.strftime('%Y-%m-%d %H:%M:%S')}\t{urllib.parse.unquote(self.path)}\t{len(data)}\n")
        write_manifest()
        self._record("PUT", 201 if not existed else 204, len(data))
        self._send(201 if not existed else 204, b"")

    def do_GET(self):
        if not self._auth_ok():
            self._record("GET", 401)
            self._send(401, b"unauthorized")
            return
        full, _parts = self._fs_path()
        if full is None or not os.path.isfile(full):
            self._record("GET", 404)
            self._send(404, b"not found")
            return
        with open(full, "rb") as f:
            data = f.read()
        self._record("GET", 200, len(data))
        self._send(200, data, ctype="application/octet-stream")

    def do_DELETE(self):
        if not self._auth_ok():
            self._record("DELETE", 401)
            self._send(401, b"unauthorized")
            return
        full, _parts = self._fs_path()
        if full is None or not os.path.exists(full):
            self._record("DELETE", 404)
            self._send(404, b"not found")
            return
        os.remove(full)
        write_manifest()
        self._record("DELETE", 204)
        self._send(204, b"")

    def do_PROPFIND(self):
        if not self._auth_ok():
            self._record("PROPFIND", 401)
            self._send(401, b"unauthorized", extra={"WWW-Authenticate": 'Basic realm="mock"'})
            return
        depth = (self.headers.get("Depth") or "1").strip()
        full, parts = self._fs_path()
        if full is None:
            self._record("PROPFIND", 400)
            self._send(400, b"bad path")
            return
        url_path = "/" + "/".join(parts)
        if not url_path.endswith("/"):
            url_path += "/"
        target_exists = os.path.isdir(full) if full else False

        def entry(href, name, is_dir, size=0, mtime=None):
            mtime = mtime or time.time()
            rtype = "<d:collection/>" if is_dir else ""
            return (
                "<d:response>"
                f"<d:href>{xml_escape(href)}</d:href>"
                "<d:propstat><d:prop>"
                f"<d:displayname>{xml_escape(name)}</d:displayname>"
                f"<d:getcontentlength>{0 if is_dir else size}</d:getcontentlength>"
                f"<d:getlastmodified>{formatdate(mtime, usegmt=True)}</d:getlastmodified>"
                f"<d:getetag>\"{size}-{int(mtime)}\"</d:getetag>"
                f"<d:resourcetype>{rtype}</d:resourcetype>"
                "</d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat>"
                "</d:response>"
            )

        entries = []
        if target_exists:
            if depth != "0":
                for name in sorted(os.listdir(full)):
                    child = os.path.join(full, name)
                    is_dir = os.path.isdir(child)
                    entries.append(entry(url_path + name + ("/" if is_dir else ""), name,
                                         is_dir, 0 if is_dir else os.path.getsize(child),
                                         os.path.getmtime(child)))
            # Depth 0 或 1 都返回自身集合项
            entries.insert(0, entry(url_path, os.path.basename(full.rstrip("\\/")) or "root", True,
                                   0, os.path.getmtime(full)))
            body = ('<?xml version="1.0" encoding="utf-8"?>'
                    '<d:multistatus xmlns:d="DAV:">' + "".join(entries) + "</d:multistatus>")
            self._record("PROPFIND", 207)
            self._send(207, body.encode("utf-8"))
        else:
            # 目录不存在：目录型 PUT 上游会自动建目录；根目录 /legado/ 首次 PUT 前
            # 需存在。这里对不存在的目录返回 404（让应用测试配置明确失败）。
            self._record("PROPFIND", 404)
            self._send(404, b"not found")

    def do_MKCOL(self):
        if not self._auth_ok():
            self._record("MKCOL", 401)
            self._send(401, b"unauthorized")
            return
        full, _parts = self._fs_path()
        if full is None:
            self._record("MKCOL", 400)
            self._send(400, b"bad path")
            return
        if os.path.exists(full):
            self._record("MKCOL", 405)
            self._send(405, b"exists")
            return
        os.makedirs(full, exist_ok=True)
        write_manifest()
        self._record("MKCOL", 201)
        self._send(201, b"")


def main():
    os.makedirs(REMOTE, exist_ok=True)
    port = 18082
    if len(sys.argv) > 1:
        port = int(sys.argv[1])
    server = ThreadingHTTPServer(("0.0.0.0", port), Handler)
    print(f"Mock WebDAV listening on 0.0.0.0:{port}, root={REMOTE}", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
