# -*- coding: utf-8 -*-
"""批47：向设备 DB 注入 QA47 音频 mock 书源 + 书籍 + 章节。

用法（宿主执行）：
  python -I inject_mock_db.py --adb "D:/Program Files/MuMuPlayer/nx_main/adb.exe" \
      --device 192.168.100.63:5555 --host 192.168.100.52 --port 8099

做法：生成 SQL 文本 → adb push 到 /data/local/tmp → run-as sqlite3 执行 → 清理。
不修改应用代码，只写测试数据（可在结束时用 --clean 删除）。
"""
from __future__ import annotations

import argparse
import json
import subprocess
import sys
import time
from pathlib import Path

PKG = "io.legado.flutter_legado"
DB = f"/data/data/{PKG}/app_flutter/legado.db"
BOOK_URL = ""  # 由 host/port 生成


def sql_quote(s: str) -> str:
    return "'" + s.replace("'", "''") + "'"


def build_source(host: str, port: int) -> dict:
    b = f"http://{host}:{port}"
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
        "ruleContent": {"content": "$.mediaUrl"},
    }


def build_sql(host: str, port: int, clean: bool) -> str:
    b = f"http://{host}:{port}"
    book_url = f"{b}/book/1"
    src = build_source(host, port)
    now_ms = int(time.time() * 1000)

    stmts: list[str] = []
    if clean:
        stmts += [
            f"DELETE FROM chapters WHERE bookUrl = {sql_quote(book_url)};",
            f"DELETE FROM books WHERE bookUrl = {sql_quote(book_url)};",
            f"DELETE FROM book_sources WHERE bookSourceUrl = {sql_quote(src['bookSourceUrl'])};",
            f"DELETE FROM cached_chapters WHERE book_url = {sql_quote(book_url)};",
        ]
        return "\n".join(stmts)

    stmts.append(
        "INSERT OR REPLACE INTO book_sources ("
        "bookSourceUrl, bookSourceName, bookSourceGroup, bookSourceType, "
        "customOrder, enabled, enabledExplore, enabledCookieJar, "
        "lastUpdateTime, respondTime, weight, "
        "searchUrl, ruleSearch, ruleBookInfo, ruleToc, ruleContent, "
        "eventListener, customButton"
        ") VALUES ("
        f"{sql_quote(src['bookSourceUrl'])}, {sql_quote(src['bookSourceName'])}, "
        f"{sql_quote(src['bookSourceGroup'])}, {src['bookSourceType']}, "
        "0, 1, 1, 0, "
        f"{now_ms}, 0, 0, "
        f"{sql_quote(src['searchUrl'])}, "
        f"{sql_quote(json.dumps(src['ruleSearch'], ensure_ascii=False))}, "
        f"{sql_quote(json.dumps(src['ruleBookInfo'], ensure_ascii=False))}, "
        f"{sql_quote(json.dumps(src['ruleToc'], ensure_ascii=False))}, "
        f"{sql_quote(json.dumps(src['ruleContent'], ensure_ascii=False))}, "
        "0, 0);"
    )

    # 书籍：type=32 (BookType.audio)
    stmts.append(
        "INSERT OR REPLACE INTO books ("
        "bookUrl, tocUrl, origin, originName, name, author, type, "
        "\"group\", latestChapterTitle, latestChapterTime, "
        "totalChapterNum, durChapterIndex, canUpdate, "
        "durChapterTitle, wordCount"
        ") VALUES ("
        f"{sql_quote(book_url)}, {sql_quote(b + '/toc')}, "
        f"{sql_quote(src['bookSourceUrl'])}, {sql_quote(src['bookSourceName'])}, "
        f"'QA47 听书测试书', 'QA', 32, "
        "0, '第4章 HLS-gated', "
        f"{now_ms}, 4, 0, 1, "
        "'第1章 MP3', '');"
    )

    # 章节：index 0=MP3, 1=HLS(.m3u8+query), 2=HLS(noext), 3=HLS(gated)
    chapters = [
        (0, "第1章 MP3", f"{b}/chap/0"),
        (1, "第2章 HLS-query", f"{b}/chap/1"),
        (2, "第3章 HLS-noext", f"{b}/chap/2"),
        (3, "第4章 HLS-gated", f"{b}/chap/3"),
    ]
    for idx, title, url in chapters:
        stmts.append(
            "INSERT OR REPLACE INTO chapters ("
            "url, title, isVolume, baseUrl, bookUrl, \"index\", "
            "isVip, isPay"
            ") VALUES ("
            f"{sql_quote(url)}, {sql_quote(title)}, 0, "
            f"{sql_quote(b)}, {sql_quote(book_url)}, {idx}, 0, 0);"
        )
    return "\n".join(stmts)


def run(adb: str, device: str, args: list[str], check: bool = True) -> subprocess.CompletedProcess:
    cmd = [adb, "-s", device, *args]
    return subprocess.run(cmd, capture_output=True, text=True, encoding="utf-8", errors="replace", check=False)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--adb", required=True)
    ap.add_argument("--device", required=True)
    ap.add_argument("--host", default="192.168.100.52")
    ap.add_argument("--port", type=int, default=8099)
    ap.add_argument("--clean", action="store_true")
    ap.add_argument("--sql-out", default="")
    a = ap.parse_args()

    sql = build_sql(a.host, a.port, a.clean)
    if a.sql_out:
        Path(a.sql_out).write_text(sql, encoding="utf-8")
    local = Path(__file__).resolve().parent / ("_clean.sql" if a.clean else "_inject.sql")
    local.write_text(sql, encoding="utf-8")

    remote = "/data/local/tmp/qa47_inject.sql"
    r = run(a.adb, a.device, ["push", str(local), remote])
    if r.returncode != 0:
        print("PUSH FAILED:", r.stdout, r.stderr)
        return 1
    print("pushed", remote)

    # run-as 复制到应用可读位置再执行（重定向必须在设备侧 shell 内完成）
    run(a.adb, a.device, ["shell", f"run-as {PKG} cp {remote} files/qa47_inject.sql"])
    inner = f"run-as {PKG} sh -c 'sqlite3 {DB} < /data/data/{PKG}/files/qa47_inject.sql'"
    r = run(a.adb, a.device, ["shell", inner])
    print("sqlite rc:", r.returncode, r.stdout.strip(), r.stderr.strip()[:400])

    if a.clean:
        r = run(a.adb, a.device, ["shell", f"run-as {PKG} rm -f files/qa47_inject.sql"])
        run(a.adb, a.device, ["shell", f"rm -f {remote}"])
        print("cleaned")
        return 0

    # 校验
    r = run(a.adb, a.device, ["shell",
        f"run-as {PKG} sqlite3 {DB} \"select bookUrl,name,type from books where name like 'QA47%';\""
    ])
    print("books:", r.stdout.strip())
    r = run(a.adb, a.device, ["shell",
        f"run-as {PKG} sqlite3 {DB} \"select \\\"index\\\",title,url from chapters where bookUrl like '%{a.port}/book/1' order by \\\"index\\\";\""
    ])
    print("chapters:", r.stdout.strip())
    r = run(a.adb, a.device, ["shell",
        f"run-as {PKG} sqlite3 {DB} \"select bookSourceName,bookSourceType from book_sources where bookSourceGroup='QA47';\""
    ])
    print("source:", r.stdout.strip())
    return 0


if __name__ == "__main__":
    sys.exit(main())
