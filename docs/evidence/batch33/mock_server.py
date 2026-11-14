# -*- coding: utf-8 -*-
"""批33 设备验收 mock 源站（文件 API 策略化）。

职责：
1. GET /b33/sources.json           → 返回 5 个最小书源（A/B/C/D1/D2），书源正文规则
                                      用 @js 调 java.downloadFile / readTxtFile /
                                      unzipFile / getTxtInFolder
2. GET /b33/text.txt               → UTF-8 文本标记文件（A 场景）
3. GET /b33/d2.txt                 → D2 源自有文件（跨源隔离对照）
4. GET /b33/bin.bin                → 非 UTF-8 二进制（含 0x00 0xff 0x80 0x1f）
5. GET /b33/pack.zip               → 真 zip（hello.txt + raw.bin），解压成功即证明
                                      下载字节未被 UTF-8 解码破坏
6. GET /b33/huge.bin               → 40MiB，带 Content-Length（快拒路径）
   GET /b33/huge_chunked.bin       → 40MiB，chunked（流式累计中止路径）
7. GET /b33/search|book|toc|ch    → 阅读主流程回归用 JSON/HTML（源 A）
8. 全部请求以 JSONL 落盘（--log），并写 manifest.json（文本/二进制 sha256 与长度）

用法：
  python mock_server.py --port 8099 --log <jsonl> --manifest <json> --a-hash <hex>
                        [--sandbox-base /data/user/0/io.legado.flutter_legado/cache/js_cache/js_files]
"""
from __future__ import annotations

import argparse
import hashlib
import io
import json
import os
import sys
import threading
import time
import zipfile
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

BIND_HOST = "0.0.0.0"
HOST = "192.168.100.52"  # 宿主 LAN IP（guest 192.168.100.63 可直连，2026-11-15 实测）
PORT = 8099
LOG_PATH = None
MANIFEST_PATH = None
A_HASH = ""
SANDBOX_BASE = "/data/user/0/io.legado.flutter_legado/cache/js_cache/js_files"
LOG_LOCK = threading.Lock()
LOG_FP = None

TEXT = (
    "BATCH33_TEXT_OK\n"
    "批33 设备验收：java.downloadFile + java.readTxtFile 生产环境可用\n"
).encode("utf-8")

D2_TEXT = "BATCH33_D2_OWN_FILE\nD2 源自己的文件，不应出现在 A 源目录\n".encode("utf-8")

# 非 UTF-8 二进制：0x00/0xff/0x80/0x1f 全覆盖 + 可识别 ASCII 尾巴
BIN = bytes(range(256)) * 16 + b"\x00\xff\x80\x1fB33BIN\x00\xfe" * 64

ZIP_HELLO = "BATCH33_ZIP_ENTRY_OK"
ZIP_RAW = b"\x00\xff\x80\x1fZIPRAWBIN\x00\xfe" * 32


def build_zip() -> bytes:
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED) as zf:
        zf.writestr("hello.txt", ZIP_HELLO + "\n")
        zf.writestr("raw.bin", ZIP_RAW)
        # deflate 真正压缩（模拟真实压缩包字节，非纯 stored）
        zf.writestr("big.txt", ("B33" * 20000) + "\n")
    return buf.getvalue()


ZIP = build_zip()

HUGE_SIZE = 40 * 1024 * 1024  # 40MiB > 32MiB 单文件上限


def log_event(kind: str, **fields) -> None:
    rec = {"ts": round(time.time(), 3), "kind": kind, **fields}
    line = json.dumps(rec, ensure_ascii=False)
    with LOG_LOCK:
        print(line, flush=True)
        if LOG_FP is not None:
            LOG_FP.write(line + "\n")
            LOG_FP.flush()


def sha256_hex(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def sandbox_dir_for(source_url: str) -> str:
    digest = hashlib.sha256(source_url.encode("utf-8")).hexdigest()
    return digest[:32]  # sha256 前 16 字节 = 32 个 hex 字符


SRC_A_URL = f"http://{HOST}:{PORT}/b33/source/A"
SRC_B_URL = f"http://{HOST}:{PORT}/b33/source/B"
SRC_C_URL = f"http://{HOST}:{PORT}/b33/source/C"
SRC_D1_URL = f"http://{HOST}:{PORT}/b33/source/D1"
SRC_D2_URL = f"http://{HOST}:{PORT}/b33/source/D2"

A_DIR = sandbox_dir_for(SRC_A_URL)
D2_DIR = sandbox_dir_for(SRC_D2_URL)


def a_abs_path() -> str:
    return f"{SANDBOX_BASE}/{A_DIR}/text.txt"


def a_abs_escape() -> str:
    return f"../{A_DIR}/text.txt"


def js_str(s: str) -> str:
    return json.dumps(s, ensure_ascii=False)


def build_sources() -> list[dict]:
    """5 个最小书源；正文规则全部走 @js + 文件 API（生产 allow_file_access=false）。"""
    a_content = (
        "@js:try{"
        'var u="http://%s:%d/b33/text.txt";'
        "var p=java.downloadFile(u);"
        "var t=java.readTxtFile(p);"
        'var f=java.getFile(p);'
        '"A_OK||"+p+"||"+f.getName()+"||"+t;'
        '}catch(e){"A_ERR||"+e;}'
    ) % (HOST, PORT)

    b_content = (
        "@js:var out='';"
        "try{"
        'var pb=java.downloadFile("http://%s:%d/b33/bin.bin");'
        'out+="B_BIN||"+pb+"||len="+java.readTxtFile(pb).length;'
        '}catch(e){out+="B_BIN_ERR||"+e;}'
        "try{"
        'var pz=java.downloadFile("http://%s:%d/b33/pack.zip");'
        "var d=java.unzipFile(pz);"
        'var t=java.readTxtFile(d+"/hello.txt");'
        'var r=java.readTxtFile(d+"/raw.bin");'
        'out+=";;B_ZIP||"+d+"||hello="+t.replace(/\\s+/g,"")+"||rawlen="+r.length;'
        '}catch(e){out+=";;B_ZIP_ERR||"+e;}'
        "out;"
    ) % (HOST, PORT, HOST, PORT)

    c_content = (
        "@js:var u=(''+baseUrl).indexOf('chunked')>=0"
        '?"http://%s:%d/b33/huge_chunked.bin"'
        ':"http://%s:%d/b33/huge.bin";'
        "try{var p=java.downloadFile(u);"
        '"C_UNEXPECTED_DOWNLOAD||"+p;}'
        'catch(e){"C_ERR||"+e;}'
    ) % (HOST, PORT, HOST, PORT)

    d1_content = (
        "@js:try{"
        'var p=java.downloadFile("http://%s:%d/b33/text.txt");'
        'var t=java.readTxtFile(p);'
        '"D1_OK||"+p+"||"+t.replace(/\\s+/g,"");'
        '}catch(e){"D1_ERR||"+e;}'
    ) % (HOST, PORT)

    d2_content = (
        "@js:var out='';"
        "try{"
        'var p=java.downloadFile("http://%s:%d/b33/d2.txt");'
        "var own=java.readTxtFile(p);"
        'out+="D2_PATH||"+p+"||"+own.replace(/\\s+/g,"");'
        '}catch(e){out+="D2_DL_ERR||"+e;}'
        "try{"
        'var f=java.getTxtInFolder(".");'
        'out+=";;D2_FOLDER||["+f.replace(/\\s+/g,"")+"]";'
        '}catch(e){out+=";;D2_FOLDER_ERR||"+e;}'
        "try{"
        'var up=java.getTxtInFolder("..");'
        'out+=";;D2_UP||["+up.replace(/\\s+/g,"")+"]";'
        '}catch(e){out+=";;D2_UP_ERR||"+e;}'
        "try{"
        "var r=java.readTxtFile(%s);"
        'out+=";;D2_READ_A_ABS||["+r.replace(/\\s+/g,"")+"]";'
        '}catch(e){out+=";;D2_READ_A_ABS_ERR||"+e;}'
        "try{"
        "var r2=java.readTxtFile(%s);"
        'out+=";;D2_READ_A_REL||["+r2.replace(/\\s+/g,"")+"]";'
        '}catch(e){out+=";;D2_READ_A_REL_ERR||"+e;}'
        "try{"
        "var g=java.getFile(%s);"
        'out+=";;D2_GET_A||exists="+g.exists();'
        '}catch(e){out+=";;D2_GET_A_ERR||"+e;}'
        "out;"
    ) % (
        HOST,
        PORT,
        js_str(a_abs_path()),
        js_str(a_abs_escape()),
        js_str(a_abs_path()),
    )

    def src(url: str, name: str, content: str) -> dict:
        return {
            "bookSourceUrl": url,
            "bookSourceName": name,
            "bookSourceGroup": "B33QA",
            "bookSourceType": 0,
            "bookSourceComment": "批33 设备验收 mock 源（文件 API 策略化）",
            "enabled": True,
            "enabledExplore": False,
            "enabledCookieJar": False,
            "searchUrl": f"http://{HOST}:{PORT}/b33/search?kw={{{{key}}}}",
            "ruleSearch": {
                "bookList": "$.data[*]",
                "name": "$.name",
                "author": "$.author",
                "bookUrl": "$.bookUrl",
                "intro": "$.intro",
                "kind": "$.kind",
                "lastChapter": "$.lastChapter",
            },
            "ruleBookInfo": {
                "init": "$.book",
                "name": "$.name",
                "author": "$.author",
                "intro": "$.intro",
                "tocUrl": "$.tocUrl",
            },
            "ruleToc": {
                "chapterList": "$.data[*]",
                "chapterName": "$.name",
                "chapterUrl": "$.url",
            },
            "ruleContent": {"content": content},
        }

    return [
        src(SRC_A_URL, "B33-A-文本下载", a_content),
        src(SRC_B_URL, "B33-B-二进制zip", b_content),
        src(SRC_C_URL, "B33-C-超限拒绝", c_content),
        src(SRC_D1_URL, "B33-D1-下载方", d1_content),
        src(SRC_D2_URL, "B33-D2-跨源探测", d2_content),
    ]


JSON_SEARCH = {
    "data": [
        {
            "name": "B33书A",
            "author": "b33qa",
            "bookUrl": f"http://{HOST}:{PORT}/b33/book/1",
            "intro": "批33 文件 API 验收书",
            "kind": "测试",
            "lastChapter": "第2章 B33A",
        }
    ]
}

JSON_BOOK = {
    "book": {
        "name": "B33书A",
        "author": "b33qa",
        "intro": "批33 文件 API 验收书",
        "tocUrl": f"http://{HOST}:{PORT}/b33/toc/1",
    }
}

JSON_TOC = {
    "data": [
        {"name": "第1章 B33A", "url": f"http://{HOST}:{PORT}/b33/ch/a"},
        {"name": "第2章 B33A", "url": f"http://{HOST}:{PORT}/b33/ch/a2"},
    ]
}

CHAPTER_HTML = (
    "<html><head><meta charset='utf-8'><title>{title}</title></head>"
    "<body><div id='content'>{body}</div></body></html>"
)


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "B33Mock/1.0"

    def log_message(self, fmt, *args):  # 静默标准日志，用 JSONL
        pass

    # ---- 工具 ----
    def send_bytes(self, path: str, data: bytes, ctype: str, status: int = 200):
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Connection", "close")
        self.end_headers()
        try:
            self.wfile.write(data)
            log_event(
                "http", path=path, status=status, bytes=len(data), aborted=False
            )
        except (BrokenPipeError, ConnectionResetError, ConnectionAbortedError) as e:
            log_event(
                "http",
                path=path,
                status=status,
                bytes=len(data),
                aborted=True,
                error=type(e).__name__,
            )
        self.close_connection = True

    def send_text(self, path: str, text: str, ctype="text/plain; charset=utf-8", status=200):
        self.send_bytes(path, text.encode("utf-8"), ctype, status)

    def send_json(self, path: str, obj, status=200):
        self.send_bytes(
            path,
            json.dumps(obj, ensure_ascii=False).encode("utf-8"),
            "application/json; charset=utf-8",
            status,
        )

    def send_huge(self, path: str, chunked: bool, size: int):
        chunk = 64 * 1024
        sent = 0
        started = time.time()
        try:
            self.send_response(200)
            self.send_header("Content-Type", "application/octet-stream")
            if chunked:
                self.send_header("Transfer-Encoding", "chunked")
            else:
                self.send_header("Content-Length", str(size))
            self.send_header("Connection", "close")
            self.end_headers()
            payload = b"\x5a" * chunk
            remaining = size
            while remaining > 0:
                n = min(chunk, remaining)
                if chunked:
                    self.wfile.write(b"%x\r\n" % n)
                    self.wfile.write(payload[:n])
                    self.wfile.write(b"\r\n")
                else:
                    self.wfile.write(payload[:n])
                self.wfile.flush()
                sent += n
                remaining -= n
            if chunked:
                self.wfile.write(b"0\r\n\r\n")
                self.wfile.flush()
            log_event(
                "http",
                path=path,
                status=200,
                chunked=chunked,
                bytes=sent,
                aborted=False,
                ms=round((time.time() - started) * 1000),
            )
        except (BrokenPipeError, ConnectionResetError, ConnectionAbortedError) as e:
            log_event(
                "http",
                path=path,
                status=200,
                chunked=chunked,
                bytes=sent,
                aborted=True,
                error=type(e).__name__,
                ms=round((time.time() - started) * 1000),
            )
        self.close_connection = True

    # ---- 路由 ----
    def do_GET(self):
        parsed = urlparse(self.path)
        path = parsed.path
        qs = parse_qs(parsed.query)

        if path == "/b33/health":
            self.send_text(path, "B33_MOCK_OK")
        elif path == "/b33/sources.json":
            self.send_bytes(
                path,
                json.dumps(build_sources(), ensure_ascii=False).encode("utf-8"),
                "application/json; charset=utf-8",
            )
        elif path == "/b33/source.json":  # 单源 A（便于单独导入）
            self.send_json(path, build_sources()[0])
        elif path.startswith("/b33/ch/"):
            title = path.rsplit("/", 1)[-1]
            self.send_text(
                path,
                CHAPTER_HTML.format(title=title, body="mock chapter " + title),
                "text/html; charset=utf-8",
            )
        elif path == "/b33/text.txt":
            self.send_bytes(path, TEXT, "text/plain; charset=utf-8")
        elif path == "/b33/d2.txt":
            self.send_bytes(path, D2_TEXT, "text/plain; charset=utf-8")
        elif path == "/b33/bin.bin":
            self.send_bytes(path, BIN, "application/octet-stream")
        elif path == "/b33/pack.zip":
            self.send_bytes(path, ZIP, "application/zip")
        elif path == "/b33/huge.bin":
            self.send_huge(path, chunked=False, size=HUGE_SIZE)
        elif path == "/b33/huge_chunked.bin":
            self.send_huge(path, chunked=True, size=HUGE_SIZE)
        elif path == "/b33/reviews.json":
            self.send_json(
                path,
                {
                    "data": [
                        {
                            "paragraph": 1,
                            "count": 3,
                            "key": "r1",
                            "name": "b33qa",
                            "avatar": "",
                            "content": "b33 段评：文件 API 验收通过",
                            "badge": "",
                            "postTime": "2026-11-15",
                        }
                    ]
                },
            )
        elif path == "/b33/search":
            kw = (qs.get("kw") or [""])[0]
            log_event("search", kw=kw)
            self.send_json(path, JSON_SEARCH)
        elif path == "/b33/book/1":
            self.send_json(path, JSON_BOOK)
        elif path == "/b33/toc/1":
            self.send_json(path, JSON_TOC)
        elif path.startswith("/b33/source/"):
            self.send_text(path, "B33_SOURCE_HOME " + path, "text/html; charset=utf-8")
        else:
            self.send_text(path, "not found", "text/plain; charset=utf-8", 404)


def write_manifest(path: str) -> None:
    sources = build_sources()
    manifest = {
        "generated_at": time.strftime("%Y-%m-%d %H:%M:%S"),
        "host": f"{HOST}:{PORT}",
        "sandbox_base_predicted": SANDBOX_BASE,
        "source_urls": {
            "A": SRC_A_URL,
            "B": SRC_B_URL,
            "C": SRC_C_URL,
            "D1": SRC_D1_URL,
            "D2": SRC_D2_URL,
        },
        "sandbox_dir": {"A": A_DIR, "D2": D2_DIR},
        "a_abs_path": a_abs_path(),
        "files": {
            "text.txt": {
                "len": len(TEXT),
                "sha256": sha256_hex(TEXT),
                "content": TEXT.decode("utf-8"),
            },
            "d2.txt": {"len": len(D2_TEXT), "sha256": sha256_hex(D2_TEXT)},
            "bin.bin": {"len": len(BIN), "sha256": sha256_hex(BIN)},
            "pack.zip": {
                "len": len(ZIP),
                "sha256": sha256_hex(ZIP),
                "entries": ["hello.txt", "raw.bin", "big.txt"],
                "hello_sha256": sha256_hex(ZIP_HELLO.encode("utf-8")),
            },
            "huge.bin": {"len": HUGE_SIZE, "note": "40MiB, Content-Length"},
            "huge_chunked.bin": {"len": HUGE_SIZE, "note": "40MiB, chunked"},
        },
        "sources": sources,
    }
    with open(path, "w", encoding="utf-8") as fp:
        json.dump(manifest, fp, ensure_ascii=False, indent=2)


def main() -> int:
    global PORT, LOG_PATH, MANIFEST_PATH, A_HASH, SANDBOX_BASE, LOG_FP
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=8099)
    ap.add_argument("--log", default="")
    ap.add_argument("--manifest", default="")
    ap.add_argument("--sandbox-base", default="")
    args = ap.parse_args()
    PORT = args.port
    if args.sandbox_base:
        SANDBOX_BASE = args.sandbox_base.rstrip("/")
    if args.log:
        LOG_PATH = args.log
        LOG_FP = open(LOG_PATH, "a", encoding="utf-8")
    if args.manifest:
        write_manifest(args.manifest)
    httpd = ThreadingHTTPServer((BIND_HOST, PORT), Handler)
    httpd.daemon_threads = True
    log_event("server_start", host=HOST, port=PORT, sandbox_base=SANDBOX_BASE)
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        log_event("server_stop")
        if LOG_FP is not None:
            LOG_FP.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
