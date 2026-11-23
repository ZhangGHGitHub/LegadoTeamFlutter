# -*- coding: utf-8 -*-
# 批9a mock 服务器：多章书源 / 漫画源（真实 PNG）/ 坏章
# 端口 18090。所有路径访问记录到 mock_access9a.log。
#
# 端点：
#   /search?q=KEY           → 3 本文本书（QA9A文A/B/C）
#   /explore?page=N         → 5 本文本书（QA9A发现P{N}书{i}）
#   /manga/search           → 3 本漫画书（QA9A漫A/B/C）
#   /manga/toc/{n}          → n 章目录 JSON
#   /book/{name}            → 书籍详情 JSON
#   /content/{name}/{i}     → 第 i 章正文（文本）；name=QA9A坏章书 时 i==3 返回 500
#   /mangapage/{name}/{i}/{j} → 漫画第 i 章 j 图 PNG（20x30 红/蓝 PNG）
#   /health                 → {"ok": true}
import json, re, struct, time
import sys
sys.stdout.reconfigure(encoding='utf-8')
sys.stderr.reconfigure(encoding='utf-8')
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HOST = '192.168.100.52'
PORT = 18090
LOG = r'D:/OH-WorkSpace/LegadoTeam/legado/tmp_debug/device_acceptance_20261031_batch9a/server/mock_access9a.log'

def png_bytes(r, g, b):
    import struct as _s, zlib as _z
    def chunk(t, d):
        c = t + d
        return _s.pack('>I', len(d)) + c + _s.pack('>I', _z.crc32(c) & 0xffffffff)
    ihdr = _s.pack('>IIBBBBB', 20, 30, 8, 2, 0, 0, 0)
    raw = b''
    for _ in range(30):
        raw += b'\x00' + bytes([r, g, b]) * 20
    return (b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', ihdr)
            + chunk(b'IDAT', _z.compress(raw)) + chunk(b'IEND', b''))

def book_json(name, stype=0):
    return {"name": name, "author": "QA9A作者", "kind": "测试",
            "bookUrl": f"http://{HOST}:{PORT}/book/{name}",
            "coverUrl": "", "intro": f"{name} 简介"}

def chapter_list(n):
    return [{"title": f"第{i}章", "url": f"/ch/{i}"} for i in range(1, n + 1)]

class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def _json(self, obj, code=200):
        body = json.dumps(obj, ensure_ascii=False).encode('utf-8')
        self.send_response(code)
        self.send_header('Content-Type', 'application/json; charset=utf-8')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def _png(self, data):
        self.send_response(200)
        self.send_header('Content-Type', 'image/png')
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        self.wfile.write(data)
    def _hit(self):
        with open(LOG, 'a', encoding='utf-8') as f:
            f.write(f"{time.strftime('%H:%M:%S')} {self.path}\n")
    def do_GET(self):
        self._hit()
        p = self.path
        if '/tocjson' in p:
            m2 = re.search(r'/tocjson/([^/?]+)', p)
            from urllib.parse import unquote as _uq
            nm = _uq(m2.group(1)) if m2 else 'QA9A文A'
            self._json([{"title": f"第{i}章",
                         "url": f"http://{HOST}:{PORT}/content/{nm}/{i}"}
                        for i in range(1, 9)])
        elif '/sources' in p:
            with open(r'D:/OH-WorkSpace/LegadoTeam/legado/tmp_debug/device_acceptance_20261031_batch9a/data/qa9a_sources.json', 'rb') as f:
                body = f.read()
            self.send_response(200)
            self.send_header('Content-Type', 'application/json; charset=utf-8')
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        elif '/search' in p and '/manga' not in p:
            self._json([book_json(f"QA9A文{c}") for c in 'ABC'])
        elif p.startswith('/manga/search'):
            self._json([book_json(f"QA9A漫{c}") for c in 'ABC'])
        elif p.startswith('/manga/toc/'):
            n = int(re.search(r'/manga/toc/(\d+)', p).group(1))
            self._json(chapter_list(n))
        elif p.startswith('/content/'):
            m = re.match(r'/content/([^/]+)/(\d+)', p)
            from urllib.parse import unquote
            name, idx = unquote(m.group(1)), int(m.group(2))
            if name == 'QA9A坏章书' and idx == 3:
                self._json({"error": "qa9a simulated broken chapter"}, code=500)
                return
            self._json({"title": f"第{idx}章",
                        "content": f"{name} 第{idx}章正文。\n" + ''.join(
                            f"QA9A段落{idx}-{k}。这是模拟的正文内容，用于测试预下载与阅读流程。" for k in range(1, 12))})
        elif p.startswith('/mangacontent/'):
            m = re.match(r'/mangacontent/([^/]+)/(\d+)', p)
            if not m:
                self._json({"error": "bad path"}, code=404); return
            from urllib.parse import unquote
            name, idx = unquote(m.group(1)), int(m.group(2))
            img = f"http://{HOST}:{PORT}/mangapage/{name}/{idx}/1"
            body = img.encode('utf-8')
            self.send_response(200)
            self.send_header('Content-Type', 'text/plain; charset=utf-8')
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        elif p.startswith('/mangapage/'):
            m = re.match(r'/mangapage/([^/]+)/(\d+)/(\d+)', p)
            if not m:
                self._json({"error": "bad path"}, code=404); return
            _, idx_s, img_s = m.groups()
            idx, img = int(idx_s), int(img_s)
            self._png(png_bytes(220, 30, (idx * 40 + img * 17) % 256))
        elif p == '/' or '/health' in p:
            self._json({"ok": True, "server": "qa9a-mock"})
        elif p.startswith('/book/'):
            self._json(book_json(p.split('/')[-1]))
        else:
            self._json({"error": "not found"}, code=404)
    def do_POST(self):
        self._hit()
        ln = int(self.headers.get('Content-Length') or 0)
        self.rfile.read(ln)
        self._json([book_json("QA9APOST书")])

print(f'qa9a-mock on {PORT}')
ThreadingHTTPServer(('0.0.0.0', PORT), H).serve_forever()
