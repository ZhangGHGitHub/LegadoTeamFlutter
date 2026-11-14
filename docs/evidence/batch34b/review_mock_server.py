# -*- coding: utf-8 -*-
"""批34b 段评 mock 服务（QA25 段评源，端口 8925）。

仅用于设备验收：GET /review/summary 返回段落徽标计数，
GET /review/detail 返回段评详情列表。请求以 JSONL 落盘。
"""
from __future__ import annotations

import json
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse

LOG_PATH = sys.argv[1] if len(sys.argv) > 1 else ""
LOCK = threading.Lock()
FP = open(LOG_PATH, "a", encoding="utf-8") if LOG_PATH else None


def log(obj) -> None:
    line = json.dumps(obj, ensure_ascii=False)
    with LOCK:
        print(line, flush=True)
        if FP:
            FP.write(line + "\n")
            FP.flush()


SUMMARY = {
    "data": [
        {"idx": 2, "token": "second", "cnt": 2},
        {"idx": 3, "token": "third", "cnt": 1},
    ]
}

DETAIL = {
    "comments": [
        {
            "id": "c1",
            "user": "书友甲",
            "text": "段评详情测试一：阅读正常。",
            "tag": "热",
        },
        {
            "id": "c2",
            "user": "书友乙",
            "text": "段评详情测试二：批34 回归。",
            "tag": "新",
        },
    ]
}


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):  # noqa: N802
        path = urlparse(self.path).path
        log({"ts": round(time.time(), 3), "method": "GET", "path": path, "query": urlparse(self.path).query})
        if path == "/review/summary":
            body = SUMMARY
        elif path == "/review/detail":
            body = DETAIL
        elif path == "/review/reply":
            body = {"data": []}
        else:
            self.send_response(404)
            self.end_headers()
            return
        raw = json.dumps(body, ensure_ascii=False).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def log_message(self, fmt, *args):
        pass


if __name__ == "__main__":
    srv = ThreadingHTTPServer(("0.0.0.0", 8925), Handler)
    srv.daemon_threads = True
    log({"ts": round(time.time(), 3), "kind": "server_start", "port": 8925})
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass
