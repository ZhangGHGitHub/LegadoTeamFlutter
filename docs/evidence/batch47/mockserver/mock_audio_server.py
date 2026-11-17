# -*- coding: utf-8 -*-
"""批47 mock 音频/书源服务器（HLS 真机验证用）。

职责：
1. GET /sources.json                → 音频书源 JSON（bookSourceType=1，指向本服务）
2. GET /search?kw=...               → 搜索/详情最小响应
3. GET /toc                         → 目录 JSON（2 章：MP3 章 + HLS 章）
4. GET /chap/{n}                    → 章节页（ruleContent 从中取播放 URL）
5. GET /media/plain.mp3             → 普通 MP3（批 0 断网复验用）
6. GET /media/hls/playlist.m3u8     → HLS（.m3u8 结尾，接受任意 query）
7. GET /media/hlsnoext              → 无扩展名 HLS 端点（Content-Type: application/vnd.apple.mpegurl）
8. GET /media/seg_XXX.ts            → HLS 分段（可要求 Referer / UA）

鉴权模式（--gate）：
- none  ：全放行
- referer：segment 请求必须带 Referer: http://<host>:<port>/ref-ok
- ua    ：segment 请求必须带自定义 User-Agent: LegadoTestUA

所有请求以 JSONL 落盘（路径、headers 摘要、状态码、时间戳），作为机器可读证据。
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlparse, parse_qs

MEDIA_DIR = Path(__file__).resolve().parent.parent / "mock_media"
LOG_PATH: Path | None = None
LOG_LOCK = threading.Lock()
GATE = "none"
PUBLIC_HOST = "127.0.0.1"
PORT = 8099

M3U8_CT = "application/vnd.apple.mpegurl"
TS_CT = "video/mp2t"


def log_event(kind: str, **fields) -> None:
    rec = {"ts": round(time.time(), 3), "kind": kind, **fields}
    line = json.dumps(rec, ensure_ascii=False)
    with LOG_LOCK:
        print(line, flush=True)
        if LOG_PATH is not None:
            with LOG_PATH.open("a", encoding="utf-8") as fp:
                fp.write(line + "\n")


def base_url() -> str:
    return f"http://{PUBLIC_HOST}:{PORT}"


def build_source() -> dict:
    """音频书源（bookSourceType=1）：搜索/详情/目录/正文均指向本服务。"""
    b = base_url()
    return {
        "bookSourceUrl": f"{b}/home",
        "bookSourceName": "QA47-AUDIO-MOCK",
        "bookSourceGroup": "QA47",
        "bookSourceType": 1,
        "enabled": True,
        "enabledExplore": True,
        "header": "",
        "searchUrl": f"{b}/search?kw={{{{key}}}}",
        "ruleSearch": {
            "bookList": "$.books[*]",
            "name": "$.name",
            "author": "$.author",
            "bookUrl": "$.bookUrl",
        },
        "ruleBookInfo": {
            "name": "$.name",
            "author": "$.author",
            "tocUrl": f"{b}/toc",
        },
        "ruleToc": {
            "chapterList": "$.chapters[*]",
            "chapterName": "$.title",
            "chapterUrl": "$.url",
        },
        "ruleContent": {
            "content": "$.mediaUrl",
        },
    }


def chapter_payload() -> dict:
    b = base_url()
    return {
        "chapters": [
            {"title": "第1章 MP3", "url": f"{b}/chap/0"},
            {"title": "第2章 HLS-query", "url": f"{b}/chap/1"},
            {"title": "第3章 HLS-noext", "url": f"{b}/chap/2"},
            {"title": "第4章 HLS-gated", "url": f"{b}/chap/3"},
        ]
    }


def chapter_media(index: int) -> str:
    b = base_url()
    if index == 0:
        return f"{b}/media/plain.mp3"
    if index == 1:
        # ① .m3u8 结尾 + query token
        return f"{b}/media/hls/playlist.m3u8?t=123&sign=abc"
    if index == 2:
        # ② 无扩展名端点，Content-Type: application/vnd.apple.mpegurl
        return f"{b}/media/hlsnoext"
    # ④ 分段受 Referer/UA 保护的 HLS（缺口 B）
    return f"{b}/media/hls_gated/playlist.m3u8"


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):  # 静音默认 stderr 日志
        pass

    # ---------- helpers ----------
    def _send(self, code: int, body: bytes, ctype: str = "application/json; charset=utf-8"):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        try:
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            log_event("write_aborted", path=self.path)

    def _json(self, obj, code: int = 200):
        self._send(code, json.dumps(obj, ensure_ascii=False).encode("utf-8"))

    def _file(self, path: Path, ctype: str):
        if not path.exists():
            self._send(404, b"not found", "text/plain")
            return
        self._send(200, path.read_bytes(), ctype)

    def _gate_ok(self) -> bool:
        if GATE == "referer":
            ref = self.headers.get("Referer", "")
            return ref.startswith(base_url() + "/ref-ok")
        if GATE == "ua":
            return "LegadoTestUA" in (self.headers.get("User-Agent", "") or "")
        return True

    # ---------- routes ----------
    def do_GET(self):
        parsed = urlparse(self.path)
        path = parsed.path
        q = parse_qs(parsed.query)
        log_event(
            "request",
            path=self.path,
            range=self.headers.get("Range"),
            ua=(self.headers.get("User-Agent") or "")[:60],
            referer=self.headers.get("Referer"),
        )

        if path == "/sources.json":
            self._json([build_source()])
            return
        if path == "/search":
            b = base_url()
            self._json({
                "books": [{
                    "name": "QA47 听书测试书",
                    "author": "QA",
                    "bookUrl": f"{b}/book/1",
                }]
            })
            return
        if path == "/toc":
            self._json(chapter_payload())
            return
        if path.startswith("/chap/"):
            try:
                idx = int(path.rsplit("/", 1)[1])
            except ValueError:
                self._json({"error": "bad chapter"}, 400)
                return
            self._json({"mediaUrl": chapter_media(idx)})
            return

        # 媒体
        if path == "/media/plain.mp3":
            self._file(MEDIA_DIR / "ch_plain.mp3", "audio/mpeg")
            return
        if path == "/media/hls/playlist.m3u8":
            self._file(MEDIA_DIR / "hls" / "playlist.m3u8", M3U8_CT)
            return
        if path == "/media/hlsnoext":
            # 无扩展名端点：同一份 playlist，靠 Content-Type 识别
            self._file(MEDIA_DIR / "hls" / "playlist.m3u8", M3U8_CT)
            return
        if path.startswith("/media/seg_") or path.startswith("/media/hls/seg_"):
            self._file(MEDIA_DIR / "hls" / Path(path).name, TS_CT)
            return
        if path == "/media/hls_gated/playlist.m3u8":
            self._file(MEDIA_DIR / "hls_gated" / "playlist.m3u8", M3U8_CT)
            return
        if path.startswith("/media/hls_gated/seg_"):
            if not self._gate_ok():
                log_event("gated_denied", path=self.path,
                          referer=self.headers.get("Referer"),
                          ua=self.headers.get("User-Agent"))
                self._send(403, b"forbidden: need referer/ua", "text/plain")
                return
            self._file(MEDIA_DIR / "hls_gated" / Path(path).name, TS_CT)
            return

        self._send(404, b"not found", "text/plain")


def main():
    global LOG_PATH, GATE, PUBLIC_HOST, PORT
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=8099)
    ap.add_argument("--host", default="0.0.0.0")
    ap.add_argument("--public-host", default="127.0.0.1")
    ap.add_argument("--gate", default="none", choices=["none", "referer", "ua"])
    ap.add_argument("--log", default="")
    args = ap.parse_args()
    PORT = args.port
    GATE = args.gate
    PUBLIC_HOST = args.public_host
    if args.log:
        LOG_PATH = Path(args.log)
        LOG_PATH.parent.mkdir(parents=True, exist_ok=True)
        LOG_PATH.write_text("", encoding="utf-8")
    log_event("start", port=PORT, gate=GATE, public_host=PUBLIC_HOST,
              media_dir=str(MEDIA_DIR))
    srv = ThreadingHTTPServer((args.host, PORT), Handler)
    print(f"[mock] listening on {args.host}:{PORT} gate={GATE} public={PUBLIC_HOST}", flush=True)
    srv.serve_forever()


if __name__ == "__main__":
    main()
