# -*- coding: utf-8 -*-
"""批27~29 设备验收 mock 书源/RSS/跨域图片服务。

- 18080：书源站点（正文/目录/详情）
- 18081：另一端口 + 跨域域名（nip.io 解析到同一宿主 IP）图片服务
逐请求记录方法、路径与关键请求头到 mock_requests.log。
"""
import base64
import datetime
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

LOG_PATH = r"D:\OH-WorkSpace\LegadoTeam\legado\tmp_debug\device_acceptance_20261028_batch2729\mock\mock_requests.log"
HOST_IP = "192.168.100.52"
CROSS_HOST = "192-168-100-52.nip.io"
_lock = threading.Lock()

PNG = base64.b64decode(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
)

CONTENT_HTML = """<!doctype html><html><head><meta charset="utf-8"><title>第一章</title></head>
<body><div id="content"><p>这是正文第一段，用于验证登录头同站门控。</p>
<p><img src="http://{host}:18080/img/same-site.png" /></p>
<p><img src="http://{host}:18081/img/other-port.png" /></p>
<p><img src="http://{cross}:18081/img/cross-domain.png" /></p>
<p>正文结束。</p></div></body></html>"""

BOOK_HTML = """<!doctype html><html><head><meta charset="utf-8"><title>QA登录头书</title></head>
<body><div id="info"><h1>QA登录头书</h1><div class="author">QA作者</div>
<div class="intro">用于批27~29 设备验收的本地 mock 书。</div></div></body></html>"""

TOC_HTML = """<!doctype html><html><head><meta charset="utf-8"><title>目录</title></head>
<body><div id="list"><a href="http://{host}:18080/chapter/1">第一章 登录头</a>
<a href="http://{host}:18080/chapter/2">第二章 跨域</a></div></body></html>"""

RSS_HTML = """<!doctype html><html><head><meta charset="utf-8"><title>QA RSS</title></head>
<body><div class="item"><a class="title" href="http://{host}:18080/article/1">RSS文章一</a></div>
<div class="item"><a class="title" href="http://{host}:18080/article/2">RSS文章二</a></div></body></html>"""


def log(line: str) -> None:
    with _lock:
        with open(LOG_PATH, "a", encoding="utf-8") as f:
            f.write(line + "\n")
            f.flush()


class Handler(BaseHTTPRequestHandler):
    server_port = 18080

    def log_message(self, fmt, *args):  # 关闭默认 stderr 噪声
        pass

    def _send(self, body: bytes, ctype="text/html; charset=utf-8", code=200):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        try:
            self.wfile.write(body)
        except Exception:
            pass

    def do_HEAD(self):
        self._handle(head_only=True)

    def do_GET(self):
        self._handle(head_only=False)

    def _handle(self, head_only: bool):
        path = self.path.split("?")[0]
        hdrs = {k.lower(): v for k, v in self.headers.items()}
        record = {
            "ts": datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S.%f")[:-3],
            "port": self.server.server_port,
            "method": self.command,
            "path": self.path,
            "host_header": hdrs.get("host", ""),
            "x_login_token": hdrs.get("x-login-token", "<absent>"),
            "user_agent": hdrs.get("user-agent", ""),
            "referer": hdrs.get("referer", ""),
            "cookie": hdrs.get("cookie", ""),
        }
        log(
            "{ts} port={port} {method} {path} host={host_header} "
            "X-Login-Token={x_login_token} referer={referer}".format(**record)
        )

        if path.startswith("/img") or path.startswith("/cross"):
            if not head_only:
                self._send(PNG, "image/png")
            else:
                self._send(b"", "image/png")
            return

        host = HOST_IP
        body = "<html><body>QA mock</body></html>"
        if path == "/book/1":
            body = BOOK_HTML
        elif path == "/toc/1":
            body = TOC_HTML.format(host=host)
        elif path.startswith("/chapter/"):
            body = CONTENT_HTML.format(host=host, cross=CROSS_HOST)
        elif path == "/rss/a" or path == "/rss/b":
            body = RSS_HTML.format(host=host)
        elif path.startswith("/article/"):
            body = "<html><body><div id='content'><p>RSS 文章正文</p></div></body></html>"
        raw = body.encode("utf-8")
        if not head_only:
            self._send(raw)
        else:
            self._send(b"", "text/html; charset=utf-8")


def serve(port: int):
    srv = ThreadingHTTPServer(("0.0.0.0", port), Handler)
    srv.daemon_threads = True
    print(f"listening on 0.0.0.0:{port}", flush=True)
    srv.serve_forever()


if __name__ == "__main__":
    log(f"=== mock server started {datetime.datetime.now()} ===")
    t2 = threading.Thread(target=serve, args=(18081,), daemon=True)
    t2.start()
    serve(18080)
