# -*- coding: utf-8 -*-
"""批39b 核心验证 A 用 mock 源站：规则正确/规则错/无 searchUrl 三种场景。"""
import json, sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 18090

BOOKS = [
    {"name": "测试书一", "author": "作者甲", "bookUrl": "/book/1", "coverUrl": "", "intro": "简介一"},
    {"name": "测试书二", "author": "作者乙", "bookUrl": "/book/2", "coverUrl": "", "intro": "简介二"},
]

class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def log_message(self, fmt, *args):
        sys.stderr.write("[mock] %s\n" % (fmt % args))
        sys.stderr.flush()

    def _send(self, body, ctype="text/html; charset=utf-8", code=200):
        raw = body.encode("utf-8") if isinstance(body, str) else body
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def do_GET(self):
        u = urlparse(self.path)
        q = parse_qs(u.query)
        if u.path == "/search":
            kw = (q.get("kw") or q.get("key") or [""])[0]
            # 页面里有 <a> 链接（规则正确时能解析出结果）
            items = "".join(
                '<li><a href="%s">%s</a><span>%s</span></li>' % (b["bookUrl"], b["name"], b["author"])
                for b in BOOKS
            )
            html = "<html><body><ul class='result'>%s</ul></body></html>" % items
            self._send(html)
            return
        if u.path == "/empty-search":
            # 有 <a> 但结构不匹配任何「书源规则」可解析形态（用于假阳回归）
            self._send("<html><body><div>暂无结果</div><a href='/x'>无关链接</a></body></html>")
            return
        if u.path == "/book/1":
            # 详情页本身带目录（ruleBookInfo.tocUrl 为空时按 bookUrl 取目录）
            links = "".join(
                '<li><a href="/content/1/%d">第%d章</a></li>' % (i, i) for i in range(1, 4)
            )
            self._send(
                "<html><body><h1>测试书一</h1><ul class='toc'>%s</ul></body></html>" % links
            )
            return
        if u.path == "/toc/1":
            links = "".join(
                '<li><a href="/content/1/%d">第%d章</a></li>' % (i, i) for i in range(1, 4)
            )
            self._send("<html><body><ul class='toc'>%s</ul></body></html>" % links)
            return
        if u.path.startswith("/content/1/"):
            self._send("<html><body><div id='content'>这是正文内容，用于校验正文步骤。</div></body></html>")
            return
        self._send("<html><body>ok</body></html>")

if __name__ == "__main__":
    srv = ThreadingHTTPServer(("0.0.0.0", PORT), H)
    print("mock listening on 0.0.0.0:%d" % PORT, flush=True)
    srv.serve_forever()
