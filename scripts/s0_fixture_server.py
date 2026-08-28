# -*- coding: utf-8 -*-
"""S0 夹具服务器：为 P0-3 取消 e2e 与 P0-2 S0 双包对比提供离线可控书源响应。

职责：
1. GET /sources.json            → 返回 N 个最小书源 JSON（分组 P0-3E2E，指向本服务器）
2. GET /src/{i}?kw={kw}         → 延迟 DELAY 秒后返回固定 JSON 搜索结果（每源 3 本书）
3. GET /marker/{name}           → 记录阶段标记（A_START/A_STOP/B_START/B_END...）
4. 全部请求以 JSONL 落盘（时间戳、路径、完成/中断状态），作为机器可读证据

证据判定原理：
- 搜索并发 32、书源 40 → 停止时刻应有 ≤32 个「在飞」请求、8 个「排队」源从未请求；
- 会话取消 → 在飞请求的 TCP 连接被中止（写响应时 BrokenPipe/ConnectionReset → aborted）；
- 立即重搜 → B 阶段 40 源各被请求恰好一次 → 证明 A 排队源未请求且 B 干净执行。

用法：python scripts/s0_fixture_server.py [--port 8090] [--sources 40] [--delay 6] [--log <jsonl>]
"""
from __future__ import annotations

import argparse
import json
import socket
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlparse, parse_qs

DELAY = 6.0
N_SOURCES = 40
LOG_PATH: Path | None = None
LOG_LOCK = threading.Lock()
LOG_FP = None

HOST_BIND = "127.0.0.1"
# 书源内部使用的 host（默认 127.0.0.1，配合 adb reverse tcp:PORT tcp:PORT；
# 也可用 10.0.2.2 走模拟器 NAT——当前环境 NAT 不可达，故默认 reverse）
URL_HOST = "127.0.0.1"


def log_event(kind: str, **fields) -> None:
    rec = {"ts": round(time.time(), 3), "kind": kind, **fields}
    line = json.dumps(rec, ensure_ascii=False)
    with LOG_LOCK:
        print(line, flush=True)
        if LOG_FP is not None:
            LOG_FP.write(line + "\n")
            LOG_FP.flush()


def build_sources(n: int) -> list[dict]:
    """构造 N 个最小书源：JSONPath 列表规则，指向本机 /src/{i}。"""
    sources = []
    for i in range(n):
        sources.append(
            {
                "bookSourceUrl": f"http://{URL_HOST}:{PORT}/home/{i}",
                "bookSourceName": f"E2E-S{i:02d}",
                "bookSourceGroup": "P0-3E2E",
                "bookSourceType": 0,
                "enabled": True,
                "searchUrl": f"http://{URL_HOST}:{PORT}/src/{i}?kw={{{{key}}}}",
                # 注：Rust 解析器要求 JSON 规则显式带 @json: 前缀（裸 $. 会被当 CSS/XPath）
                "ruleSearch": {
                    "bookList": "@json:$.books[*]",
                    "name": "@json:$.name",
                    "author": "@json:$.author",
                    "bookUrl": "@json:$.url",
                    "kind": "@json:$.kind",
                    "intro": "@json:$.intro",
                },
            }
        )
    return sources


PORT = 8090


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):  # 静默默认 stderr 访问日志
        pass

    def do_GET(self):  # noqa: N802
        parsed = urlparse(self.path)
        path = parsed.path
        t_start = time.time()

        if path == "/sources.json":
            body = json.dumps(build_sources(N_SOURCES), ensure_ascii=False).encode("utf-8")
            self._send(200, body, "application/json; charset=utf-8")
            log_event("sources_json", bytes=len(body))
            return

        if path.startswith("/marker/"):
            name = path[len("/marker/"):]
            log_event("marker", name=name)
            self._send(200, b"ok", "text/plain")
            return

        if path.startswith("/src/"):
            try:
                idx = int(path[len("/src/"):].split("/")[0])
            except ValueError:
                self._send(404, b"not found", "text/plain")
                return
            kw = (parse_qs(parsed.query).get("kw") or [""])[0]
            req_id = f"{threading.get_ident()}-{round(t_start, 3)}"
            # 到达即打点：阶段归属以「请求到达时刻」为准（延迟期间客户端可能中止）
            log_event("search_start", id=req_id, src=idx, kw=kw)
            # 延迟响应：制造可控的「在飞」窗口
            time.sleep(DELAY)
            # 断开探测：延迟期间客户端连接被关闭（任务被 abort）→ EOF。
            # 直接 write 会因内核缓冲「成功」而漏报，必须先 peek。
            client_gone = False
            import select as _select
            try:
                r, _, _ = _select.select([self.connection], [], [], 0)
                if r:
                    if self.connection.recv(1, socket.MSG_PEEK) == b"":
                        client_gone = True
            except (OSError, ValueError):
                client_gone = True
            if client_gone:
                log_event("search_end", id=req_id, src=idx,
                          elapsed=round(time.time() - t_start, 3), result="aborted")
                try:
                    self.connection.close()
                except Exception:
                    pass
                return
            books = {
                "books": [
                    {
                        "name": f"E2E书{idx:02d}-{k}",
                        "author": f"作者{idx:02d}",
                        "url": f"http://{URL_HOST}:{PORT}/book/{idx}/{k}",
                        "kind": "测试",
                        "intro": f"夹具书籍 简介源{idx} 关键词{kw}",
                    }
                    for k in (kw or "kw", "alt1", "alt2")
                ]
            }
            body = json.dumps(books, ensure_ascii=False).encode("utf-8")
            ok = self._send(200, body, "application/json; charset=utf-8")
            log_event(
                "search_end",
                id=req_id,
                src=idx,
                elapsed=round(time.time() - t_start, 3),
                result="done" if ok else "aborted",
            )
            return

        # 其余路径（/home/i、/book/...）返回 200 空页，避免导入或详情阶段报错
        self._send(200, b"<html><body>fixture</body></html>", "text/html; charset=utf-8")
        log_event("misc", path=path)

    def _send(self, code: int, body: bytes, ctype: str) -> bool:
        """发送响应；客户端已断开时返回 False（在飞任务被中止的证据）。"""
        try:
            self.send_response(code)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return True
        except (BrokenPipeError, ConnectionResetError, ConnectionAbortedError, OSError):
            try:
                self.wfile.close()
            except Exception:
                pass
            return False


class Server(ThreadingHTTPServer):
    daemon_threads = True
    # 32 并发在飞 + 握手排队余量
    request_queue_size = 128
    allow_reuse_address = True


def main() -> int:
    global DELAY, N_SOURCES, LOG_PATH, LOG_FP, PORT, URL_HOST
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=8090)
    ap.add_argument("--sources", type=int, default=40)
    ap.add_argument("--delay", type=float, default=6.0)
    ap.add_argument("--log", default="")
    ap.add_argument("--url-host", default="127.0.0.1")
    args = ap.parse_args()

    PORT = args.port
    DELAY = args.delay
    N_SOURCES = args.sources
    URL_HOST = args.url_host
    if args.log:
        LOG_PATH = Path(args.log)
        LOG_PATH.parent.mkdir(parents=True, exist_ok=True)
        LOG_FP = LOG_PATH.open("w", encoding="utf-8")

    srv = Server((HOST_BIND, PORT), Handler)
    log_event("server_start", port=PORT, sources=N_SOURCES, delay=DELAY)
    try:
        srv.serve_forever(poll_interval=0.2)
    except KeyboardInterrupt:
        pass
    finally:
        log_event("server_stop")
        if LOG_FP:
            LOG_FP.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
