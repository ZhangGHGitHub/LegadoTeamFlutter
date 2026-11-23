# -*- coding: utf-8 -*-
# 批42 mock 服务器 v2：双端口 18080/18081 + /s2 前缀支持
import json, re, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HOST = '192.168.100.52'

def book_json(name):
    return {"name": name, "author": "QA作者", "kind": "测试", "bookUrl": f"http://{HOST}:18080/book/{name}", "coverUrl": "", "intro": f"{name} 简介"}

class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def _json(self, obj, code=200):
        body = json.dumps(obj, ensure_ascii=False).encode('utf-8')
        self.send_response(code)
        self.send_header('Content-Type', 'application/json; charset=utf-8')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def do_GET(self):
        p = self.path
        if '/search' in p:
            self._json([book_json(f"QA42搜索书{i}") for i in range(1, 4)])
        elif '/explore' in p:
            m = re.search(r'page=(\d+)', p)
            page = int(m.group(1)) if m else 1
            self._json([book_json(f"QA42发现P{page}书{i}") for i in range(1, 6)])
        elif '/slow' in p:
            time.sleep(8)
            self._json([book_json("QA42慢源书")])
        elif p == '/' or '/health' in p:
            self._json({"ok": True, "server": "qa42-mock2"})
        else:
            self._json([book_json("QA42默认书")])
    def do_POST(self):
        ln = int(self.headers.get('Content-Length') or 0)
        self.rfile.read(ln)
        self._json([book_json("QA42POST书")])

print('qa42-mock2 on 18080+18081')
t1 = ThreadingHTTPServer(('0.0.0.0', 18080), H)
t2 = ThreadingHTTPServer(('0.0.0.0', 18081), H)
import threading
threading.Thread(target=t2.serve_forever, daemon=True).start()
t1.serve_forever()
