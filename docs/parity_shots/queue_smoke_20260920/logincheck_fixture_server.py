#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
loginCheckJs 实机探针 · 127.0.0.1 确定性夹具服务器
====================================================
供 5554 (LDPlayer) 经 `adb reverse tcp:18080 tcp:18080` 访问。

路径 → 响应体（取自 rust/legado-ffi/tests/fixtures/search_s0 的 response.bin）：
  /probeA/search*  -> login_check_pass/response.bin          （夺宝奇兵书列表, code 200）
  /probeC/search*  -> login_check_modified_response/response.bin （登录墙）
  /probeD/search*  -> login_check_second_adopt/response.bin  （登录墙）
  /probeE/search*  -> login_check_second_adopt/response.bin  （登录墙）
  /probeC/alt* /probeD/rec* -> 200 空（bookUrl 仅计算不抓取，防御性兜底）
每个请求落盘到 logincheck_fixture_requests.log（证明设备确实到达网络层）。
"""
import http.server
import os
import sys
import time
import datetime

PORT = 18080
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.abspath(os.path.join(SCRIPT_DIR, "..", "..", ".."))
FIX_DIR = os.path.join(
    REPO_ROOT, "rust", "legado-ffi", "tests", "fixtures", "search_s0"
)
LOG_FILE = os.path.join(SCRIPT_DIR, "logincheck_fixture_requests.log")


def _read_body(scenario: str) -> bytes:
    p = os.path.join(FIX_DIR, scenario, "response.bin")
    with open(p, "rb") as f:
        return f.read()


# 预读各场景响应体（服务器启动时读取，避免运行期依赖仓库文件）
BODY_A = _read_body("login_check_pass")
BODY_LOGIN_WALL = _read_body("login_check_modified_response")  # 与 second_adopt 同体


def log_line(method: str, path: str, query: str) -> None:
    ts = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S.%f")[:-3]
    line = f"{ts} {method} {path}{('?' + query) if query else ''}\n"
    with open(LOG_FILE, "a", encoding="utf-8") as f:
        f.write(line)
        f.flush()
    sys.stdout.write(line)
    sys.stdout.flush()


class Handler(http.server.BaseHTTPRequestHandler):
    def _serve(self):
        parsed = self.path.split("?", 1)
        path = parsed[0]
        query = parsed[1] if len(parsed) > 1 else ""
        log_line(self.command, path, query)

        if path.startswith("/probeA/search"):
            body = BODY_A
        elif path.startswith("/probeC/search"):
            body = BODY_LOGIN_WALL
        elif path.startswith("/probeD/search"):
            body = BODY_LOGIN_WALL
        elif path.startswith("/probeE/search"):
            body = BODY_LOGIN_WALL
        elif path.startswith("/probeC/alt") or path.startswith("/probeD/rec"):
            body = b""
        else:
            self.send_response(404)
            self.end_headers()
            self.wfile.write(b"not found")
            return

        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        self._serve()

    def do_POST(self):
        self._serve()

    def log_message(self, *args):  # 静音默认 stderr 日志
        pass


def main():
    # 重置请求日志（每次启动干净计数）
    open(LOG_FILE, "w", encoding="utf-8").close()
    print(f"[logincheck fixture] serving on 127.0.0.1:{PORT}")
    print(f"[logincheck fixture] FIX_DIR={FIX_DIR}")
    print(f"[logincheck fixture] request log -> {LOG_FILE}")
    httpd = http.server.ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
    httpd.serve_forever()


if __name__ == "__main__":
    main()
