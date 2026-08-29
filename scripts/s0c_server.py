# -*- coding: utf-8 -*-
"""S0-C 双包对比夹具服务器:7 个确定性场景书源(HTML 规则,原版 Kotlin 与
Rust 解析器双兼容),逐源递增延迟使到达顺序确定,从而两包聚合稳定序可比。

端点:
  /s0c/sources.json                    → 7 个书源(分组 S0C)
  /s0c/s0/search  (delay 2s)  列表 → 书甲
  /s0c/s1/start   (delay 4s)  302 → /s0c/s1/final → 书乙
  /s0c/s2/detail  (delay 6s)  详情(pattern 命中) → 书丙
  /s0c/s3/list    (delay 8s)  列表(pattern 不命中) → 书丁
  /s0c/s4/search  (delay 10s) 列表空 → 详情回退 → 书戊
  /s0c/s5/search  (delay 12s) loginCheckJs=false → 该源失败(无结果)
  /s0c/s6/search  (delay 14s) 列表空且无法解析 → 空结果

证据:JSONL 请求日志(search_start/search_end,含 aborted 探测)。
"""
from __future__ import annotations

import argparse
import json
import select
import socket
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlparse, parse_qs

LOG_LOCK = threading.Lock()
LOG_FP = None
PORT = 8090


def log_event(kind: str, **fields) -> None:
    rec = {"ts": round(time.time(), 3), "kind": kind, **fields}
    line = json.dumps(rec, ensure_ascii=False)
    with LOG_LOCK:
        print(line, flush=True)
        if LOG_FP is not None:
            LOG_FP.write(line + "\n")
            LOG_FP.flush()


def html_list(name: str, author: str, book_id: int) -> bytes:
    return (f'<html><body><div class="book-item">'
            f'<a class="name" href="/book/{book_id}">{name}</a>'
            f'<span class="author">{author}</span></div></body></html>'
            ).encode('utf-8')


def html_detail(name: str, author: str) -> bytes:
    return (f'<html><body><div class="title">{name}</div>'
            f'<div class="author">{author}</div></body></html>').encode('utf-8')


HTML_EMPTY = b'<html><body><p>not found</p></body></html>'

# 场景表:路径前缀 / 延迟 / 响应构造
DELAY = {i: 1.0 * (2 * i + 2) for i in range(7)}  # 2,4,6,8,10,12,14


def build_sources(port: int) -> list[dict]:
    """7 个书源;127.0.0.1 形式配合 adb reverse,双包同构。"""
    def s(i, path, **extra):
        base = {
            'bookSourceUrl': f'http://127.0.0.1:{port}/s0c/home/{i}',
            'bookSourceName': f'S0C-S{i}',
            'bookSourceGroup': 'S0C',
            'bookSourceType': 0,
            'enabled': True,
            'searchUrl': f'http://127.0.0.1:{port}/s0c/s{i}/{path}?kw={{{{key}}}}',
            'ruleSearch': {
                'bookList': '.book-item',
                'name': '.name',
                'author': '.author',
                'bookUrl': '.name@href',
            },
        }
        base.update(extra)
        return base

    return [
        s(0, 'search', loginCheckJs='result.code() == 200'),
        s(1, 'start'),
        s(2, 'detail',
          bookUrlPattern=r'^http://127\.0\.0\.1:\d+/s0c/s2/detail\?kw=.+$',
          ruleBookInfo={'name': '.title', 'author': '.author'}),
        s(3, 'list',
          bookUrlPattern=r'^https://never\.match/\d+$'),
        s(4, 'search',
          ruleSearch={'bookList': '.none', 'name': '.name', 'author': '.author', 'bookUrl': '.name@href'},
          ruleBookInfo={'name': '.title', 'author': '.author'}),
        s(5, 'search', loginCheckJs='false'),
        s(6, 'search',
          ruleSearch={'bookList': '.none', 'name': '.name', 'author': '.author', 'bookUrl': '.name@href'},
          ruleBookInfo={'name': '.title', 'author': '.author'}),
    ]


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        pass

    def do_GET(self):  # noqa: N802
        parsed = urlparse(self.path)
        path = parsed.path
        t0 = time.time()
        kw = (parse_qs(parsed.query).get('kw') or [''])[0]

        if path == '/s0c/sources.json':
            body = json.dumps(build_sources(PORT), ensure_ascii=False).encode('utf-8')
            self._send(200, body, 'application/json; charset=utf-8')
            log_event('sources_json')
            return

        if path.startswith('/marker/'):
            log_event('marker', name=path[len('/marker/'):])
            self._send(200, b'ok', 'text/plain')
            return

        seg = path.split('/')  # ['', 's0c', 's{i}', 'action']
        if len(seg) >= 3 and seg[1] == 's0c' and seg[2] in {f's{i}' for i in range(7)}:
            i = int(seg[2][1:])
            req_id = f'{threading.get_ident()}-{round(t0, 3)}'
            log_event('search_start', id=req_id, src=i, kw=kw, path=path)
            time.sleep(DELAY[i])
            if self._client_gone():
                log_event('search_end', id=req_id, src=i,
                          elapsed=round(time.time() - t0, 3), result='aborted')
                try:
                    self.connection.close()
                except Exception:
                    pass
                return

            if i == 0:
                body, ctype = html_list('书甲', '作者甲', 10), 'text/html'
            elif i == 1:
                if seg[3] == 'start':
                    loc = f'http://127.0.0.1:{PORT}/s0c/s1/final?kw={kw}'
                    self.send_response(302)
                    self.send_header('Location', loc)
                    self.send_header('Content-Length', '0')
                    self.end_headers()
                    log_event('search_end', id=req_id, src=i, note='redirect',
                              elapsed=round(time.time() - t0, 3), result='redirected')
                    return
                body, ctype = html_list('书乙', '作者乙', 11), 'text/html'
            elif i == 2:
                body, ctype = html_detail('书丙', '作者丙'), 'text/html'
            elif i == 3:
                body, ctype = html_list('书丁', '作者丁', 13), 'text/html'
            elif i == 4:
                body, ctype = html_detail('书戊', '作者戊'), 'text/html'
            elif i == 5:
                body, ctype = html_list('书己', '作者己', 15), 'text/html'
            else:
                body, ctype = HTML_EMPTY, 'text/html'

            ok = self._send(200, body, f'{ctype}; charset=utf-8')
            log_event('search_end', id=req_id, src=i,
                      elapsed=round(time.time() - t0, 3),
                      result='done' if ok else 'aborted')
            return

        self._send(200, b'ok', 'text/plain')
        log_event('misc', path=path)

    def _client_gone(self) -> bool:
        try:
            r, _, _ = select.select([self.connection], [], [], 0)
            if r and self.connection.recv(1, socket.MSG_PEEK) == b'':
                return True
        except (OSError, ValueError):
            return True
        return False

    def _send(self, code: int, body: bytes, ctype: str) -> bool:
        try:
            self.send_response(code)
            self.send_header('Content-Type', ctype)
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return True
        except (BrokenPipeError, ConnectionResetError, ConnectionAbortedError, OSError):
            return False


class Server(ThreadingHTTPServer):
    daemon_threads = True
    request_queue_size = 128
    allow_reuse_address = True


def main():
    global LOG_FP, PORT
    ap = argparse.ArgumentParser()
    ap.add_argument('--port', type=int, default=8090)
    ap.add_argument('--log', required=True)
    args = ap.parse_args()
    PORT = args.port
    LOG_FP = Path(args.log).open('w', encoding='utf-8')
    srv = Server(('0.0.0.0', PORT), Handler)
    log_event('server_start', port=PORT, mode='s0c')
    try:
        srv.serve_forever(poll_interval=0.2)
    except KeyboardInterrupt:
        pass


if __name__ == '__main__':
    sys.exit(main())
