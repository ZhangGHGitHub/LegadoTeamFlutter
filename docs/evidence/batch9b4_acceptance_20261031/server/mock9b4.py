# -*- coding: utf-8 -*-
# 批9b-4 mock：全局/书源 UserAgent 验收（端口 18090）
# 每个请求把 路径 + User-Agent（含重复头列表）写入 mock_access9b4.log
import json, re, struct, sys, time, zlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import unquote

sys.stdout.reconfigure(encoding='utf-8')
sys.stderr.reconfigure(encoding='utf-8')

HOST = '192.168.100.52'
PORT = 18090
BASE = f'http://{HOST}:{PORT}'
LOG = r'D:/OH-WorkSpace/LegadoTeam/legado/tmp_debug/device_acceptance_20261031_batch9b4/server/mock_access9b4.log'
SRC_JSON = r'D:/OH-WorkSpace/LegadoTeam/legado/tmp_debug/device_acceptance_20261031_batch9b4/data/qa9b4_sources.json'
RSS_JSON = r'D:/OH-WorkSpace/LegadoTeam/legado/tmp_debug/device_acceptance_20261031_batch9b4/data/qa9b4_rss_sources.json'


def png_bytes(r, g, b, w=40, h=60):
    def chunk(t, d):
        c = t + d
        return struct.pack('>I', len(d)) + c + struct.pack('>I', zlib.crc32(c) & 0xffffffff)
    ihdr = struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0)
    raw = b''
    for _ in range(h):
        raw += b'\x00' + bytes([r, g, b]) * w
    return (b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', ihdr)
            + chunk(b'IDAT', zlib.compress(raw)) + chunk(b'IEND', b''))


def book(name, prefix):
    return {
        'name': name,
        'author': 'QA9B4作者',
        'kind': '测试',
        'bookUrl': f'{BASE}/{prefix}/book/{name}',
        'coverUrl': f'{BASE}/cover/{name}.png',
        'intro': f'{name} 简介：批9b-4 UA 验收用书。',
        'tocUrl': f'{BASE}/{prefix}/toc/{name}',
    }


def chapters(name, prefix):
    return [{'title': f'第{i}章', 'url': f'{BASE}/{prefix}/content/{name}/{i}'}
            for i in range(1, 4)]


RSS_XML = '''<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0"><channel>
<title>QA9B4 RSS</title><link>{base}/rss</link><description>QA9B4</description>
<item><title>QA9B4 RSS 文章一</title><link>{base}/rss/article/1</link>
<pubDate>Fri, 31 Oct 2026 12:00:00 GMT</pubDate><description>RSS 摘要一</description></item>
<item><title>QA9B4 RSS 文章二</title><link>{base}/rss/article/2</link>
<pubDate>Thu, 30 Oct 2026 12:00:00 GMT</pubDate><description>RSS 摘要二</description></item>
</channel></rss>'''.format(base=BASE)

ARTICLE_HTML = '''<!DOCTYPE html><html><head><meta charset="utf-8"><title>QA9B4 RSS 文章</title></head>
<body><h1>QA9B4 RSS 文章</h1><div id="content"><p>这是 QA9B4 RSS 正文段落一。</p><p>正文段落二。</p></div></body></html>'''


class H(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def log_message(self, *a):
        pass

    def _log(self):
        uas = self.headers.get_all('User-Agent') or []
        ua = ' | '.join(uas) if uas else '(none)'
        with open(LOG, 'a', encoding='utf-8') as f:
            f.write(f"{time.strftime('%Y-%m-%d %H:%M:%S')}\t{self.command}\t{self.path}\tUA={ua}\n")

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
        self._log()
        p = self.path
        try:
            if p == '/health':
                self._json({'ok': True, 'server': 'qa9b4-mock', 'time': time.time()})
            elif p.startswith('/sources'):
                with open(SRC_JSON, 'rb') as f:
                    body = f.read()
                self._send(body, 'application/json; charset=utf-8')
            elif p.startswith('/rsssources'):
                with open(RSS_JSON, 'rb') as f:
                    body = f.read()
                self._send(body, 'application/json; charset=utf-8')
            elif re.match(r'^/(a|b)/search', p):
                prefix = p.split('/')[1]
                name = 'QA9B4A-1' if prefix == 'a' else 'QA9B4B-1'
                self._json([book(name, prefix)])
            elif re.match(r'^/(a|b)/book/', p):
                prefix = p.split('/')[1]
                name = unquote(p.rsplit('/', 1)[-1].split('?')[0])
                self._json(book(name, prefix))
            elif re.match(r'^/(a|b)/toc/', p):
                prefix = p.split('/')[1]
                name = unquote(p.rsplit('/', 1)[-1].split('?')[0])
                self._json({'chapters': chapters(name, prefix)})
            elif re.match(r'^/(a|b)/content/', p):
                m = re.match(r'^/(a|b)/content/([^/]+)/(\d+)', p)
                prefix, name, idx = m.group(1), unquote(m.group(2)), int(m.group(3))
                paras = ''.join(f'<p>QA9B4 {name} 第{idx}章 段落{k}。这是 UA 验收正文内容。</p>' for k in range(1, 8))
                self._json({'title': f'第{idx}章', 'content': paras})
            elif p.startswith('/cover/'):
                self._send(png_bytes(30, 120, 220), 'image/png')
            elif p.startswith('/rss/feed.xml') or p == '/rss':
                self._send(RSS_XML.encode('utf-8'), 'application/rss+xml; charset=utf-8')
            elif p.startswith('/rss/article/'):
                self._send(ARTICLE_HTML.encode('utf-8'), 'text/html; charset=utf-8')
            else:
                self._json({'error': 'not found', 'path': p}, code=404)
        except BrokenPipeError:
            pass
        except Exception as e:
            try:
                self._json({'error': repr(e)}, code=500)
            except Exception:
                pass


if __name__ == '__main__':
    srv = ThreadingHTTPServer(('0.0.0.0', PORT), H)
    print(f'qa9b4 mock listening on {BASE}', flush=True)
    srv.serve_forever()
