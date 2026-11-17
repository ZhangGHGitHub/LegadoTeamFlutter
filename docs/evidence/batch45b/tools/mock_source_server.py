# -*- coding: utf-8 -*-
"""批45b D 项验收夹具：最小 mock 书源服务（不改动产品代码）。

提供：
  GET /search?key=<kw>  → JSON 搜索结果（1 本书）
  GET /book/<id>        → 书籍详情
  GET /toc/<id>         → 目录（1 章）
  GET /content/<id>/1   → 正文
  GET /marker/<name>    → 记录阶段标记（用于证明 JS 确实被求值）

用法：python -I mock_source_server.py --port 18120
"""
from __future__ import annotations

import argparse
import json
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

HITS: list[str] = []


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):  # 静音默认访问日志
        pass

    def _send(self, obj, code=200):
        body = json.dumps(obj, ensure_ascii=False).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        u = urlparse(self.path)
        q = parse_qs(u.query)
        HITS.append(self.path)
        print(f"[hit] {self.path}", flush=True)

        if u.path == "/search":
            kw = (q.get("key") or [""])[0]
            return self._send({
                "data": [{
                    "name": f"QA45B变量书-{kw}",
                    "author": "QA45B",
                    "intro": "批45b D 项变量持久化验证用书",
                    "bookUrl": "http://192.168.100.52:18120/book/1",
                    "coverUrl": "",
                    "kind": "测试",
                    "tocUrl": "http://192.168.100.52:18120/toc/1",
                }]
            })
        if u.path.startswith("/book/"):
            return self._send({
                "name": "QA45B变量书",
                "author": "QA45B",
                "intro": "批45b D 项变量持久化验证用书",
                "kind": "测试",
                "coverUrl": "",
                "tocUrl": "http://192.168.100.52:18120/toc/1",
            })
        if u.path.startswith("/toc/"):
            return self._send({"data": [
                {"name": "第1章 变量章", "url": "http://192.168.100.52:18120/content/1/1"},
            ]})
        if u.path.startswith("/content/"):
            return self._send({"url": "变量持久化正文：source.put 写入的 qa45b_var 应能读回。"})
        if u.path.startswith("/marker/"):
            return self._send({"ok": True, "path": self.path, "ts": time.time()})
        if u.path == "/rss/login":
            # 最小登录页（E 项：RSS 登录 WebView 执行链验证）
            html = (
                "<!doctype html><html><head><meta charset='utf-8'>"
                "<title>QA45B 登录</title></head><body>"
                "<h2>QA45B 订阅源登录</h2>"
                "<form method='get' action='/rss/login'>"
                "<input name='u' placeholder='账号'>"
                "<input name='p' type='password' placeholder='密码'>"
                "<button type='submit'>登录</button></form>"
                "<p id='ok'>登录页已加载（mock）</p></body></html>"
            ).encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(html)))
            self.end_headers()
            self.wfile.write(html)
            return
        if u.path == "/rss/list":
            return self._send({"data": [{
                "title": "QA45B 测试文章",
                "link": "http://192.168.100.52:18120/rss/article/1",
                "content": "批45b E 项 RSS 登录验证文章",
            }]})
        return self._send({"error": "not found", "path": self.path}, 404)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=18120)
    args = ap.parse_args()
    srv = ThreadingHTTPServer(("0.0.0.0", args.port), Handler)
    print(f"[mock] listening on 0.0.0.0:{args.port}", flush=True)
    srv.serve_forever()


if __name__ == "__main__":
    main()
