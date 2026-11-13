# -*- coding: utf-8 -*-
"""批29 QA mock 源站。

用途（书源脚本不再全局阻塞 / jsLib 失败可见）：
- /fast/search         立即返回快源搜索结果（1 本书）
- /slow/jsblock        睡 8s 返回（供慢源 jsLib 顶层 java.ajax 阻塞）
- /slow/search         睡 8s 返回慢源搜索结果
- /fast/book.html      详情页
- /fast/toc.html       目录（2 章）
- /fast/ch1.html       第一章正文
- /fast/ch2.html       第二章正文
- /review/summary      段评摘要（复用批26 格式）
- /review/detail       段评详情
- /ping                健康探测

访问日志带毫秒时间戳，用于证明「快源请求/结果不被慢源 jsLib 阻塞」。
用法：python qa29_mock_server.py 8931 qa29_mock_access.log
"""
import http.server
import socketserver
import sys
import time
from datetime import datetime

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8931
LOG_PATH = sys.argv[2] if len(sys.argv) > 2 else "qa29_mock_access.log"
SLOW_SECONDS = 8.0
HOST = "192.168.100.52"


def log(msg: str) -> None:
    line = "%s %s" % (datetime.now().strftime("%H:%M:%S.%f")[:-3], msg)
    with open(LOG_PATH, "a", encoding="utf-8") as f:
        f.write(line + "\n")
    print(line, flush=True)


SEARCH_FAST = """<html><head><meta charset="utf-8"></head><body>
<div class="book"><a class="title" href="http://%s:%d/fast/book.html">QA29 快源书</a>
<span class="author">快源作者</span></div>
</body></html>""" % (HOST, PORT)

SEARCH_SLOW = """<html><head><meta charset="utf-8"></head><body>
<div class="book"><a class="title" href="http://%s:%d/slow/book.html">QA29 慢源书</a>
<span class="author">慢源作者</span></div>
</body></html>""" % (HOST, PORT)

DETAIL_FAST = """<html><head><meta charset="utf-8"></head><body>
<div class="name">QA29 快源书</div><div class="author">快源作者</div>
<div class="intro">批29 QA 快源，用于并发搜索与阅读回归。</div>
<a class="toc" href="http://%s:%d/fast/toc.html">目录</a>
</body></html>""" % (HOST, PORT)

DETAIL_SLOW = """<html><head><meta charset="utf-8"></head><body>
<div class="name">QA29 慢源书</div><div class="author">慢源作者</div>
<div class="intro">批29 QA 慢源，jsLib 顶层 java.ajax 阻塞 8s。</div>
<a class="toc" href="http://%s:%d/slow/toc.html">目录</a>
</body></html>""" % (HOST, PORT)

TOC_FAST = """<html><head><meta charset="utf-8"></head><body>
<ul id="list">
<li><a href="http://%s:%d/fast/ch1.html">第一章 起点</a></li>
<li><a href="http://%s:%d/fast/ch2.html">第二章 继续</a></li>
</ul></body></html>""" % (HOST, PORT, HOST, PORT)

TOC_SLOW = """<html><head><meta charset="utf-8"></head><body>
<ul id="list">
<li><a href="http://%s:%d/slow/ch1.html">第一章 慢起</a></li>
<li><a href="http://%s:%d/slow/ch2.html">第二章 慢续</a></li>
</ul></body></html>""" % (HOST, PORT, HOST, PORT)

CH1 = """<html><head><meta charset="utf-8"></head><body>
<div class="content"><p>批29 第一章第一段：慢与快互不阻塞的验证正文。</p>
<p>批29 第一章第二段：用于段评与划线回归的文本。</p>
<p>批29 第一章第三段：全文完。</p></div></body></html>"""

CH2 = """<html><head><meta charset="utf-8"></head><body>
<div class="content"><p>批29 第二章第一段：翻章后的正文。</p>
<p>批29 第二章第二段：翻章成功标志。</p></div></body></html>"""

REVIEW_SUMMARY = '{"data":[{"idx":1,"cnt":7,"token":"p1"},{"idx":2,"cnt":3,"token":"p2"}]}'
REVIEW_DETAIL = ('{"comments":[{"id":"c1","user":"QA29读者甲","tag":"楼主",'
                 '"text":"批29 段评正文：这一段讨论很热闹。"},'
                 '{"id":"c2","user":"QA29读者乙","tag":"","text":"批29 段评正文：同意楼上。"}]}')


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def _send(self, body: str, code: int = 200, ctype: str = "text/html; charset=utf-8"):
        data = body.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        path = self.path.split("?")[0]
        log("GET %s" % self.path)
        if path == "/ping":
            self._send("ok", ctype="text/plain; charset=utf-8")
            return
        if path == "/fast/search":
            self._send(SEARCH_FAST)
            return
        if path == "/slow/jsblock":
            time.sleep(SLOW_SECONDS)
            log("SLOW-JSBLOCK released after %.1fs" % SLOW_SECONDS)
            self._send("ok", ctype="text/plain; charset=utf-8")
            return
        if path == "/slow/search":
            # 立即返回：把全部 8s 延迟集中在 jsLib 顶层 java.ajax，
            # 便于区分「HTTP 慢」与「jsLib 阻塞」两种成因
            self._send(SEARCH_SLOW)
            return
        if path == "/slow/book.html":
            self._send(DETAIL_SLOW)
            return
        if path == "/slow/toc.html":
            self._send(TOC_SLOW)
            return
        if path == "/badlogin/search":
            self._send(SEARCH_FAST)
            return
        if path == "/fast/book.html":
            self._send(DETAIL_FAST)
            return
        if path == "/fast/toc.html":
            self._send(TOC_FAST)
            return
        if path == "/fast/ch1.html":
            self._send(CH1)
            return
        if path == "/fast/ch2.html":
            self._send(CH2)
            return
        if path == "/slow/ch1.html" or path == "/slow/ch2.html":
            self._send(CH2)
            return
        if path == "/review/summary":
            self._send(REVIEW_SUMMARY, ctype="application/json; charset=utf-8")
            return
        if path == "/review/detail":
            self._send(REVIEW_DETAIL, ctype="application/json; charset=utf-8")
            return
        self._send("not found", code=404, ctype="text/plain; charset=utf-8")

    def log_message(self, fmt, *args):  # 关闭 stderr 默认日志，统一走文件
        return


class Server(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True


if __name__ == "__main__":
    with Server(("0.0.0.0", PORT), Handler) as httpd:
        log("LISTEN %s:%d slow=%.1fs" % (HOST, PORT, SLOW_SECONDS))
        httpd.serve_forever()
