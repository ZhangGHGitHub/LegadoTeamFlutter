"""验收用宿主 mock 服务（批 8~16 设备验收）。

功能：
- POST /upload        解析 multipart，记录请求头/字段/文件元信息/body 摘要，返回 {"url": ...}
- POST /upload-fail   固定返回 500，用于失败路径验收
- GET  /rss.xml       标准 RSS 2.0（2 个 item，description 含 <div class="content">正文</div>）
- GET  /rss_article_2.xml  第二篇文章页
- GET  /files/<name>  下载回显（upload 返回的 url 可访问）

用法：python mock_server.py [--port 18080] [--outdir .]
"""

import argparse
import hashlib
import json
import os
import sys
import threading
import uuid
from datetime import datetime
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

OUTDIR = os.path.dirname(os.path.abspath(__file__))
LOCK = threading.Lock()

RSS_XML = """<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0">
  <channel>
    <title>MockRSS</title>
    <link>http://127.0.0.1:18080/rss.xml</link>
    <description>验收用 mock RSS 源</description>
    <language>zh-cn</language>
    <item>
      <title>Mock 文章一：RSS 引擎解析验证</title>
      <link>http://127.0.0.1:18080/rss_article_1.html</link>
      <guid>http://127.0.0.1:18080/rss_article_1.html</guid>
      <pubDate>Mon, 26 Oct 2026 10:00:00 +0800</pubDate>
      <description><![CDATA[<div class="content">正文一</div>]]></description>
    </item>
    <item>
      <title>Mock 文章二：分页与正文规则验证</title>
      <link>http://127.0.0.1:18080/rss_article_2.html</link>
      <guid>http://127.0.0.1:18080/rss_article_2.html</guid>
      <pubDate>Tue, 27 Oct 2026 09:30:00 +0800</pubDate>
      <description><![CDATA[<div class="content">正文二</div>]]></description>
    </item>
  </channel>
</rss>
"""

ARTICLE_1 = """<!DOCTYPE html>
<html><head><meta charset="utf-8"><title>Mock 文章一</title></head>
<body><h1>Mock 文章一</h1>
<div class="content">正文一</div>
</body></html>
"""

ARTICLE_2 = """<!DOCTYPE html>
<html><head><meta charset="utf-8"><title>Mock 文章二</title></head>
<body><h1>Mock 文章二</h1>
<div class="content">正文二</div>
</body></html>
"""


def log_jsonl(record):
    line = json.dumps(record, ensure_ascii=False, default=str)
    with LOCK:
        with open(os.path.join(OUTDIR, "upload_log.jsonl"), "a", encoding="utf-8") as f:
            f.write(line + "\n")
        with open(os.path.join(OUTDIR, "server.log"), "a", encoding="utf-8") as f:
            f.write(line + "\n")


def parse_multipart(body, boundary):
    """极简 multipart 解析，返回 (fields, files)。"""
    fields, files = [], []
    if not boundary:
        return fields, files
    delim = b"--" + boundary
    parts = body.split(delim)
    for part in parts:
        part = part.strip(b"\r\n")
        if not part or part == b"--":
            continue
        if b"\r\n\r\n" not in part:
            continue
        raw_headers, content = part.split(b"\r\n\r\n", 1)
        if content.endswith(b"\r\n"):
            content = content[:-2]
        headers = {}
        for line in raw_headers.decode("utf-8", "replace").split("\r\n"):
            if ":" in line:
                k, v = line.split(":", 1)
                headers[k.strip().lower()] = v.strip()
        disp = headers.get("content-disposition", "")
        name = None
        filename = None
        for piece in disp.split(";"):
            piece = piece.strip()
            if piece.startswith("name="):
                name = piece[5:].strip('"')
            elif piece.startswith("filename="):
                filename = piece[9:].strip('"')
        entry = {
            "name": name,
            "filename": filename,
            "content_type": headers.get("content-type"),
            "size": len(content),
            "sha1": hashlib.sha1(content).hexdigest(),
            "head256": content[:256].decode("utf-8", "replace"),
        }
        if filename is not None:
            # 保存完整上传内容，供离线核对导出 JSON 字段
            os.makedirs(os.path.join(OUTDIR, "files"), exist_ok=True)
            with open(os.path.join(OUTDIR, "files", entry["sha1"] + ".bin"), "wb") as f:
                f.write(content)
            files.append(entry)
        else:
            entry["value"] = content.decode("utf-8", "replace")[:512]
            fields.append(entry)
    return fields, files


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        sys.stderr.write("[%s] %s - %s\n" % (
            datetime.now().isoformat(timespec="seconds"), self.address_string(), fmt % args))

    def _send(self, code, payload, ctype="application/json; charset=utf-8"):
        data = payload if isinstance(payload, bytes) else payload.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        path = self.path.split("?")[0]
        if path == "/rss.xml":
            self._send(200, RSS_XML, "application/rss+xml; charset=utf-8")
            return
        if path == "/rss_article_2.xml":
            self._send(200, ARTICLE_2, "text/html; charset=utf-8")
            return
        if path == "/rss_article_1.html":
            self._send(200, ARTICLE_1, "text/html; charset=utf-8")
            return
        if path == "/rss_article_2.html":
            self._send(200, ARTICLE_2, "text/html; charset=utf-8")
            return
        if path.startswith("/files/"):
            name = path[len("/files/"):]
            fpath = os.path.join(OUTDIR, "files", os.path.basename(name))
            if os.path.exists(fpath):
                with open(fpath, "rb") as f:
                    self._send(200, f.read(), "application/octet-stream")
            else:
                self._send(404, json.dumps({"error": "not found"}))
            return
        self._send(404, json.dumps({"error": "unknown path", "path": path}))

    def do_POST(self):
        path = self.path.split("?")[0]
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length) if length else b""
        ctype = self.headers.get("Content-Type", "")
        boundary = None
        if "boundary=" in ctype:
            boundary = ctype.split("boundary=")[1].split(";")[0].strip().strip('"').encode()

        fields, files = parse_multipart(body, boundary)
        record = {
            "ts": datetime.now().isoformat(timespec="milliseconds"),
            "method": "POST",
            "path": path,
            "headers": dict(self.headers.items()),
            "content_type": ctype,
            "body_size": len(body),
            "fields": fields,
            "files": files,
        }

        if path == "/upload-fail":
            record["result"] = "500 injected failure"
            log_jsonl(record)
            self._send(500, json.dumps(
                {"error": "mock upload failure", "detail": "验收注入的 500"}, ensure_ascii=False))
            return

        if path in ("/upload", "/"):
            key = uuid.uuid4().hex[:12]
            if files:
                record["content_sha1"] = files[0]["sha1"]
                key = files[0]["sha1"][:12]
                fname = files[0]["filename"] or "payload.bin"
                os.makedirs(os.path.join(OUTDIR, "files"), exist_ok=True)
                # 只存摘要，避免大文件占空间
                with open(os.path.join(OUTDIR, "files", key + ".json"), "w", encoding="utf-8") as f:
                    json.dump({"from": fname, "meta": files[0]}, f, ensure_ascii=False, indent=2)
            url = "http://127.0.0.1:18080/files/%s" % key
            record["result"] = url
            log_jsonl(record)
            self._send(200, json.dumps(
                {"url": url, "code": 200, "msg": "ok"}, ensure_ascii=False))
            return

        record["result"] = "404"
        log_jsonl(record)
        self._send(404, json.dumps({"error": "unknown post path", "path": path}))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=18080)
    ap.add_argument("--host", default="127.0.0.1")
    a = ap.parse_args()
    srv = ThreadingHTTPServer((a.host, a.port), Handler)
    with open(os.path.join(OUTDIR, "server.log"), "a", encoding="utf-8") as f:
        f.write("=== mock server start %s on %s:%d ===\n" % (
            datetime.now().isoformat(timespec="seconds"), a.host, a.port))
    print("listening on %s:%d (outdir=%s)" % (a.host, a.port, OUTDIR), flush=True)
    srv.serve_forever()


if __name__ == "__main__":
    main()
