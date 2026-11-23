# -*- coding: utf-8 -*-
"""批36 设备验收用本地模拟书源服务器。

用法: python mock_server.py [port] [fail_file]
  port      监听端口（默认 18080，设备侧经 `adb reverse tcp:18080 tcp:18080` 访问）
  fail_file 若该文件存在且内容包含页码数字，则该页请求返回 HTTP 500（故障注入）

端点：
  /explore?kind=xh|ds&page=N   发现分类页（标题含页码）
  /search?q=KEY&page=N         搜索页
  /book/<id>                   详情页（含目录）
  /chapter/<id>/<n>            正文页
  /health                      健康检查
"""
import sys
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 18080
FAIL_FILE = sys.argv[2] if len(sys.argv) > 2 else ''

KIND_NAMES = {'xh': '玄幻', 'ds': '都市'}


def fail_pages():
    if not FAIL_FILE:
        return set()
    try:
        with open(FAIL_FILE, encoding='utf-8') as f:
            return {int(x) for x in f.read().replace(',', ' ').split()}
    except Exception:
        return set()


def explore_html(kind, page):
    kind_name = KIND_NAMES.get(kind, kind)
    items = []
    for i in range(1, 4):
        bid = f'{kind}-{page}-{i}'
        items.append(
            f'<div class="book-item">'
            f'<a href="/book/{bid}"><img class="cover" src="/cover/{i}.png"/>'
            f'<span class="name">{kind_name}第{page}页-书{i}</span></a>'
            f'<span class="author">作者{kind_name}{i}</span>'
            f'<span class="kind">{kind_name}</span>'
            f'</div>'
        )
    return (
        '<html><head><meta charset="utf-8"></head><body>'
        f'<div class="page-marker">PAGE={page} KIND={kind_name}</div>'
        + ''.join(items)
        + '</body></html>'
    )


def search_html(q, page):
    items = []
    for i in range(1, 3):
        bid = f'search-{page}-{i}'
        items.append(
            f'<div class="search-item">'
            f'<a href="/book/{bid}">'
            f'<span class="name">搜索-{q}-第{page}页-书{i}</span></a>'
            f'<span class="author">搜索作者{i}</span>'
            f'</div>'
        )
    return (
        '<html><head><meta charset="utf-8"></head><body>'
        f'<div class="page-marker">SEARCH={q} PAGE={page}</div>'
        + ''.join(items)
        + '</body></html>'
    )


def book_html(bid):
    chapters = ''.join(
        f'<div class="chapter"><a href="/chapter/{bid}/{i}">第{i}章 验收章节{i}</a></div>'
        for i in range(1, 4)
    )
    return (
        '<html><head><meta charset="utf-8"></head><body>'
        f'<h1>{bid}</h1>'
        '<div class="author">QA36作者</div>'
        '<div class="intro">这是批36设备验收测试书。</div>'
        '<img class="cover" src="/cover/1.png"/>'
        f'{chapters}'
        '</body></html>'
    )


def chapter_html(bid, n):
    paras = ''.join(
        f'<p>QA36正文-{bid}-第{n}章-段落{i}：这是用于验收的测试正文。</p>'
        for i in range(1, 6)
    )
    return (
        '<html><head><meta charset="utf-8"></head><body>'
        f'<div class="content"><h1>第{n}章 验收章节{n}</h1>{paras}</div>'
        '</body></html>'
    )


PNG = bytes.fromhex(
    '89504e470d0a1a0a0000000d49484452000000010000000108060000001f15c4'
    '890000000a49444154789c6360000002000154a24f5d0000000049454e44ae42'
    '6082'
)


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        sys.stderr.write('%s - %s\n' % (self.address_string(), fmt % args))

    def _send(self, code, body, ctype='text/html; charset=utf-8'):
        data = body.encode('utf-8') if isinstance(body, str) else body
        self.send_response(code)
        self.send_header('Content-Type', ctype)
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        path = parsed.path
        query = urllib.parse.parse_qs(parsed.query)
        page = int(query.get('page', ['1'])[0] or '1')

        if path == '/health':
            self._send(200, 'ok', 'text/plain; charset=utf-8')
            return
        if path == '/cover/1.png':
            self._send(200, PNG, 'image/png')
            return
        if path == '/explore':
            if page in fail_pages():
                self._send(500, 'injected failure for page %d' % page)
                return
            kind = query.get('kind', ['xh'])[0]
            self._send(200, explore_html(kind, page))
            return
        if path == '/search':
            if page in fail_pages():
                self._send(500, 'injected failure for page %d' % page)
                return
            q = query.get('q', [''])[0]
            self._send(200, search_html(q, page))
            return
        if path.startswith('/book/'):
            self._send(200, book_html(path[len('/book/'):]))
            return
        if path.startswith('/chapter/'):
            parts = path[len('/chapter/'):].split('/')
            bid, n = parts[0], (parts[1] if len(parts) > 1 else '1')
            self._send(200, chapter_html(bid, n))
            return
        self._send(404, 'not found')


if __name__ == '__main__':
    srv = ThreadingHTTPServer(('127.0.0.1', PORT), Handler)
    sys.stderr.write('mock server listening on 127.0.0.1:%d fail_file=%r\n' % (PORT, FAIL_FILE))
    srv.serve_forever()
