# -*- coding: utf-8 -*-
# 批9b-2 mock：线程数并发验收（搜索 6+2 源 / 两本书各 20 章）
# 记录：每个请求 START/END、路径、UA、章节、当前在途与历史最大在途；
# 正文请求延迟 150~300ms，搜索请求延迟 800ms，便于形成稳定并发窗口。
import json
import random
import re
import struct
import sys
import threading
import time
import zlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import unquote

sys.stdout.reconfigure(encoding='utf-8')
sys.stderr.reconfigure(encoding='utf-8')

HOST = '192.168.100.52'
PORT = 18092
BASE = f'http://{HOST}:{PORT}'
LOG = r'D:/OH-WorkSpace/LegadoTeam/legado/tmp_debug/device_acceptance_20261031_batch9b2/server/mock_access9b2.log'
SRC_JSON = r'D:/OH-WorkSpace/LegadoTeam/legado/tmp_debug/device_acceptance_20261031_batch9b2/data/qa9b2_sources.json'

BOOKS = {
    'a': ['QAB2A-1'],
    'b': ['QAB2B-1'],
    's1': ['QAS1-1'],
    's2': ['QAS2-1'],
    's3': ['QAS3-1'],
    's4': ['QAS4-1'],
    's5': ['QAS5-1'],
    's6': ['QAS6-1'],
}

LOCK = threading.Lock()
LOCK_LOG = threading.Lock()
STATE = {
    'search': 0,
    'search_max': 0,
    'content': 0,
    'content_max': 0,
    'book': {},          # book -> in-flight
    'book_max': {},      # book -> max in-flight
    'book_count': {},    # book -> total content requests
    'path_count': {},    # path -> total
    'chapter_count': {}, # book/index -> total
    'started': time.strftime('%Y-%m-%d %H:%M:%S'),
}


def log(line):
    with LOCK_LOG:
        with open(LOG, 'a', encoding='utf-8') as f:
            f.write(line + '\n')


def enter(group, book=None, index=None):
    """登记请求进入，返回 (search_inflight, search_max, content_inflight, content_max)"""
    with LOCK:
        key = 'search' if group == 'search' else 'content'
        STATE[key] += 1
        if STATE[key] > STATE[key + '_max']:
            STATE[key + '_max'] = STATE[key]
            log(f"{time.strftime('%Y-%m-%d %H:%M:%S')}\tMAX\t{group}\tinflight={STATE[key]}")
        if book is not None:
            STATE['book'][book] = STATE['book'].get(book, 0) + 1
            if STATE['book'][book] > STATE['book_max'].get(book, 0):
                STATE['book_max'][book] = STATE['book'][book]
                log(f"{time.strftime('%Y-%m-%d %H:%M:%S')}\tMAX_BOOK\t{book}\tinflight={STATE['book'][book]}")
            STATE['book_count'][book] = STATE['book_count'].get(book, 0) + 1
            ck = f'{book}#{index}'
            STATE['chapter_count'][ck] = STATE['chapter_count'].get(ck, 0) + 1
        p = group
        STATE['path_count'][p] = STATE['path_count'].get(p, 0) + 1
        return STATE['search'], STATE['search_max'], STATE['content'], STATE['content_max']


def leave(group, book=None):
    with LOCK:
        key = 'search' if group == 'search' else 'content'
        STATE[key] = max(0, STATE[key] - 1)
        if book is not None:
            STATE['book'][book] = max(0, STATE['book'].get(book, 1) - 1)


def png_bytes(r, g, b, w=60, h=80):
    def chunk(t, d):
        c = t + d
        return struct.pack('>I', len(d)) + c + struct.pack('>I', zlib.crc32(c) & 0xffffffff)
    ihdr = struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0)
    raw = b''
    for _ in range(h):
        raw += b'\x00' + bytes([r, g, b]) * w
    return (b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', ihdr)
            + chunk(b'IDAT', zlib.compress(raw)) + chunk(b'IEND', b''))


def book_obj(name, prefix):
    return {
        'name': name,
        'author': 'QA9B2作者',
        'kind': '测试',
        'bookUrl': f'{BASE}/{prefix}/book/{name}',
        'coverUrl': f'{BASE}/cover/{name}.png',
        'intro': f'{name} 简介：批9b-2 线程数验收用书。',
        'tocUrl': f'{BASE}/{prefix}/toc/{name}',
    }


def chapters(name, prefix, n=20):
    return [{'title': f'第{i}章', 'url': f'{BASE}/{prefix}/content/{name}/{i}'}
            for i in range(1, n + 1)]


class H(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def log_message(self, *a):
        pass

    def _ua(self):
        uas = self.headers.get_all('User-Agent') or []
        return ' | '.join(uas) if uas else '(none)'

    def _send(self, body, ctype):
        self.send_response(200)
        self.send_header('Content-Type', ctype)
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _json(self, obj, code=200):
        body = json.dumps(obj, ensure_ascii=False).encode('utf-8')
        self.send_response(code)
        self.send_header('Content-Type', 'application/json; charset=utf-8')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        p = self.path
        ua = self._ua()
        path_only = p.split('?')[0]
        try:
            if path_only == '/health':
                self._json({'ok': True, 'server': 'qa9b2-mock', 'time': time.time()})
                return
            if path_only == '/sources':
                log(f"{time.strftime('%Y-%m-%d %H:%M:%S')}\tGET\t/sources\tUA={ua}")
                with open(SRC_JSON, 'rb') as f:
                    self._send(f.read(), 'application/json; charset=utf-8')
                return
            if path_only == '/stats':
                with LOCK:
                    data = {
                        'search_inflight': STATE['search'],
                        'search_max': STATE['search_max'],
                        'content_inflight': STATE['content'],
                        'content_max': STATE['content_max'],
                        'book_inflight': dict(STATE['book']),
                        'book_max': dict(STATE['book_max']),
                        'book_count': dict(STATE['book_count']),
                        'chapter_count': dict(STATE['chapter_count']),
                        'path_count': dict(STATE['path_count']),
                    }
                self._json(data)
                return
            if path_only == '/reset':
                with LOCK:
                    STATE.update({
                        'search': 0, 'search_max': 0, 'content': 0, 'content_max': 0,
                        'book': {}, 'book_max': {}, 'book_count': {},
                        'path_count': {}, 'chapter_count': {},
                        'started': time.strftime('%Y-%m-%d %H:%M:%S'),
                    })
                log(f"{time.strftime('%Y-%m-%d %H:%M:%S')}\tRESET\t{ua}")
                self._json({'ok': True})
                return

            if path_only.startswith('/cover/'):
                self._send(png_bytes(40, 110, 210), 'image/png')
                return

            m = re.match(r'^/(s[1-6]|a|b)/(search|book|toc|content)(?:/([^/]+))?(?:/(\d+))?', path_only)
            if not m:
                self._json({'error': 'not found'}, 404)
                return
            prefix, kind, name, idx = m.group(1), m.group(2), m.group(3), m.group(4)
            name = unquote(name) if name else None

            if kind == 'search':
                group = 'search'
                si, sm, ci, cm = enter(group)
                log(f"{time.strftime('%Y-%m-%d %H:%M:%S')}\tSTART\t{p}\tgroup=search\tinflight_search={si}\tmax_search={sm}\tUA={ua}")
                t0 = time.time()
                time.sleep(0.8)
                names = BOOKS.get(prefix, [])
                out = [book_obj(n, prefix) for n in names]
                # 换源回归：S1 额外返回 A 书同名镜像（20 章，独立 URL）
                if prefix == 's1':
                    out.append({
                        'name': 'QAB2A-1',
                        'author': 'QA9B2作者-镜像',
                        'kind': '测试',
                        'bookUrl': f'{BASE}/s1/book/QAB2A-1',
                        'coverUrl': f'{BASE}/cover/QAB2A-1.png',
                        'intro': 'QAB2A-1 镜像源（换源回归）。',
                        'tocUrl': f'{BASE}/s1/toc/QAB2A-1',
                    })
                self._json(out)
                leave(group)
                log(f"{time.strftime('%Y-%m-%d %H:%M:%S')}\tEND\t{p}\tgroup=search\tdur={time.time()-t0:.3f}\tinflight_search={STATE['search']}\tUA={ua}")
                return

            if kind == 'book':
                log(f"{time.strftime('%Y-%m-%d %H:%M:%S')}\tSTART\t{p}\tgroup=book\tUA={ua}")
                self._json(book_obj(name, prefix))
                log(f"{time.strftime('%Y-%m-%d %H:%M:%S')}\tEND\t{p}\tgroup=book\tUA={ua}")
                return

            if kind == 'toc':
                log(f"{time.strftime('%Y-%m-%d %H:%M:%S')}\tSTART\t{p}\tgroup=toc\tUA={ua}")
                self._json({'chapters': chapters(name, prefix, 20)})
                log(f"{time.strftime('%Y-%m-%d %H:%M:%S')}\tEND\t{p}\tgroup=toc\tUA={ua}")
                return

            if kind == 'content':
                i = int(idx)
                group = 'content'
                si, sm, ci, cm = enter(group, book=name, index=i)
                log(f"{time.strftime('%Y-%m-%d %H:%M:%S')}\tSTART\t{p}\tgroup=content\tbook={name}\tidx={i}"
                    f"\tinflight_content={ci}\tmax_content={cm}\tbook_inflight={STATE['book'].get(name)}"
                    f"\tbook_max={STATE['book_max'].get(name)}\tUA={ua}")
                t0 = time.time()
                time.sleep(random.uniform(0.15, 0.30))
                paras = ''.join(
                    f'<p>QA9B2 {name} 第{i}章 段落{k}。批9b-2 并发验收正文。</p>'
                    for k in range(1, 9))
                self._json({'title': f'第{i}章', 'content': paras})
                leave(group, book=name)
                log(f"{time.strftime('%Y-%m-%d %H:%M:%S')}\tEND\t{p}\tgroup=content\tbook={name}\tidx={i}"
                    f"\tdur={time.time()-t0:.3f}\tinflight_content={STATE['content']}"
                    f"\tUA={ua}")
                return
        except BrokenPipeError:
            pass
        except Exception as e:  # noqa: BLE001
            log(f"{time.strftime('%Y-%m-%d %H:%M:%S')}\tERROR\t{p}\t{e}")
            try:
                self._json({'error': str(e)}, 500)
            except Exception:
                pass


if __name__ == '__main__':
    open(LOG, 'a', encoding='utf-8').close()
    srv = ThreadingHTTPServer(('0.0.0.0', PORT), H)
    srv.daemon_threads = True
    log(f"{time.strftime('%Y-%m-%d %H:%M:%S')}\tBOOT\tport={PORT}\tBASE={BASE}")
    print(f'mock9b2 listening on {BASE}', flush=True)
    srv.serve_forever()
