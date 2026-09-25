# -*- coding: utf-8 -*-
"""swd 轮（2026-09-25，MuMu 192.168.100.63:5555）种子/清理/还原脚本。

面向 io.legado.flutter_legado 的 app_flutter/legado.db（run-as sqlite3，
WAL 感知；写操作前先 force-stop）。机制复用同目录 vui2_seed.py，
端点/包名改为本轮 MuMu NAT 设备。

注入内容（全部为本轮验证夹具，移除后即还原）：
  R1 书（换源主链路验证，8092 夹具）：
    books  R1换源验证书   bookUrl=http://127.0.0.1:8092/r1va/detail
           origin=http://127.0.0.1:8092/r1v/home/a originName=R1VA
           type=8 total=3 latest='第三章 终局' dci=0 dcp=0
    chapters 3 行（url .../r1va/content?i=N&tok=TK777）
    cached_chapters 3 行（正文标记 R1VA正文『…』）
  W2 书（目录派生字段验证，8093 夹具，SWA 3 章 vs SWB 5 章）：
    books  R1换源验证书2  bookUrl=http://127.0.0.1:8093/wa/detail
           origin=http://127.0.0.1:8093/r1w/home/a originName=SWA
           type=8 total=3 latest='第三章 三' dci=0 dcp=0
    chapters 3 行（url .../wa/content?i=N）
    cached_chapters 3 行（正文标记 SWA正文『…』）
  书源（R1VA/R1VB、SWA/SWB）不在此脚本注入——走应用自带导入深链
  （legado://import/bookSource?src=http://127.0.0.1:8092/r1v/sources.json
   与 :8093/r1w/sources.json），顺带回归导入管线；remove 时按 URL 删除。

用法:
  python swd_seed.py seed      # force-stop→注入两书→快照
  python swd_seed.py check     # 查询当前状态
  python swd_seed.py remove    # force-stop→删除全部夹具残留（含上轮遗留孤儿）
  python swd_seed.py restore   # force-stop→斗破苍穹进度/两 caches 配置还原→快照
  python swd_seed.py before    # books 全量基线 dump
"""
import subprocess
import sys
import time

ADB = r"D:\Android\platform-tools\adb.exe"
DEV = "192.168.100.63:5555"
PKG = "io.legado.flutter_legado"
DB = "app_flutter/legado.db"

# ── R1 书（8092 夹具，目录 3 章）────────────────────────────────────────
R1_BOOK_URL = "http://127.0.0.1:8092/r1va/detail"
R1_NAME = "R1换源验证书"
R1_AUTHOR = "R1作者"
R1_ORIGIN = "http://127.0.0.1:8092/r1v/home/a"
R1_ORIGIN_NAME = "R1VA"
R1_TOC = "http://127.0.0.1:8092/r1va/toc"
R1_CHAPTERS = [
    ("http://127.0.0.1:8092/r1va/content?i=0&tok=TK777", "第一章 起源",
     "R1VA正文『第一章 起源』标准段落内容R1换源验证书"),
    ("http://127.0.0.1:8092/r1va/content?i=1&tok=TK777", "第二章 风波",
     "R1VA正文『第二章 风波』标准段落内容R1换源验证书"),
    ("http://127.0.0.1:8092/r1va/content?i=2&tok=TK777", "第三章 终局",
     "R1VA正文『第三章 终局』标准段落内容R1换源验证书"),
]

# ── W2 书（8093 夹具，SWA 3 章；换源目标 SWB 5 章）──────────────────────
W2_BOOK_URL = "http://127.0.0.1:8093/wa/detail"
W2_NAME = "R1换源验证书2"
W2_AUTHOR = "R1作者2"
W2_ORIGIN = "http://127.0.0.1:8093/r1w/home/a"
W2_ORIGIN_NAME = "SWA"
W2_TOC = "http://127.0.0.1:8093/wa/toc"
W2_CHAPTERS = [
    ("http://127.0.0.1:8093/wa/content?i=0", "第一章 一",
     "SWA正文『第一章 一』标准段落内容R1换源验证书2"),
    ("http://127.0.0.1:8093/wa/content?i=1", "第二章 二",
     "SWA正文『第二章 二』标准段落内容R1换源验证书2"),
    ("http://127.0.0.1:8093/wa/content?i=2", "第三章 三",
     "SWA正文『第三章 三』标准段落内容R1换源验证书2"),
]

# 换源后可能出现的新 bookUrl 形态（remove 时一并清理）
R1VB_BOOK_URL = "http://127.0.0.1:8092/r1vb/detail?vid=VID123"
W2B_BOOK_URL = "http://127.0.0.1:8093/wb/detail"

# 书源导入后 book_sources 新增行（按 bookSourceUrl 删除）
IMPORTED_SOURCE_URLS = [
    "http://127.0.0.1:8092/r1v/home/a",
    "http://127.0.0.1:8092/r1v/home/b",
    "http://127.0.0.1:8093/r1w/home/a",
    "http://127.0.0.1:8093/r1w/home/b",
]

# 斗破苍穹 还原基线（swd_db_baseline_books.txt，本轮安装后首个 dump）
DP_BOOK_URL = "https://bookshelf.html5.qq.com/qbread/api/novel/intro-info?bookid=1100468914"
DP_RESTORE = (
    "UPDATE books SET origin='https://www.deqixs.org',"
    "originName='📂得奇小说网',type=8,totalChapterNum=999,"
    "durChapterIndex=0,durChapterPos=3,"
    "latestChapterTitle='第999章 白狐引起的血案',"
    "durChapterTitle='第1章 陨落的天才',"
    "tocUrl='https://www.deqixs.org/198/' WHERE bookUrl='" + DP_BOOK_URL + "';"
)


def sh(cmd: str) -> str:
    r = subprocess.run([ADB, "-s", DEV, "shell", cmd],
                       capture_output=True, timeout=180)
    return r.stdout.decode("utf-8", "replace") + r.stderr.decode("utf-8", "replace")


def sql(queries: str) -> str:
    return sh(f'run-as {PKG} sqlite3 {DB} "{queries}"')


def now_ms() -> int:
    return int(time.time() * 1000)


def force_stop() -> None:
    print("==> force-stop", PKG)
    sh(f"am force-stop {PKG}")
    time.sleep(2)


def _seed_book(book_url: str, name: str, author: str, origin: str,
               origin_name: str, toc: str, latest: str,
               chapters: list) -> None:
    now = now_ms()
    out = sql(
        "PRAGMA busy_timeout=5000; "
        "INSERT OR REPLACE INTO books "
        "(bookUrl,name,author,type,origin,originName,tocUrl,totalChapterNum,"
        "latestChapterTitle,durChapterIndex,durChapterPos,durChapterTitle,"
        "lastCheckTime) "
        f"VALUES ('{book_url}','{name}','{author}',8,'{origin}','{origin_name}',"
        f"'{toc}',{len(chapters)},'{latest}',0,0,'',{now});"
    )
    print(f"[books {origin_name}]", out.strip() or "(ok)")
    out = sql("PRAGMA busy_timeout=5000; " + "".join(
        "INSERT OR REPLACE INTO chapters "
        "(url,title,isVolume,baseUrl,bookUrl,[index],isVip,isPay) "
        f"VALUES ('{u}','{t}',0,'{book_url}','{book_url}',{i},0,0);"
        for i, (u, t, _c) in enumerate(chapters)))
    print(f"[chapters {origin_name}]", out.strip() or "(ok)")
    out = sql("PRAGMA busy_timeout=5000; "
              f"DELETE FROM cached_chapters WHERE book_url='{book_url}';" + "".join(
                  "INSERT OR REPLACE INTO cached_chapters "
                  "(book_url,chapter_index,chapter_title,chapter_url,content,"
                  "cached_at,size_bytes) "
                  f"VALUES ('{book_url}',{i},'{t}','{u}',"
                  f"'{c.replace(chr(39), chr(39) * 2)}',{now_ms()},"
                  f"{len(c.encode('utf-8'))});"
                  for i, (u, t, c) in enumerate(chapters)))
    print(f"[cached_chapters {origin_name}]", out.strip() or "(ok)")


def seed() -> None:
    force_stop()
    _seed_book(R1_BOOK_URL, R1_NAME, R1_AUTHOR, R1_ORIGIN, R1_ORIGIN_NAME,
               R1_TOC, "第三章 终局", R1_CHAPTERS)
    _seed_book(W2_BOOK_URL, W2_NAME, W2_AUTHOR, W2_ORIGIN, W2_ORIGIN_NAME,
               W2_TOC, "第三章 三", W2_CHAPTERS)
    check()


def check() -> None:
    out = sql(
        "SELECT 'B1='||bookUrl||' o='||origin||' tot='||totalChapterNum||"
        "' lt=['||COALESCE(latestChapterTitle,'')||'] dci='||durChapterIndex||"
        "' dcp='||durChapterPos FROM books WHERE bookUrl IN "
        f"('{R1_BOOK_URL}','{W2_BOOK_URL}'); "
        "SELECT 'CH1='||COUNT(*) FROM chapters WHERE bookUrl='" + R1_BOOK_URL + "'; "
        "SELECT 'CC1='||COUNT(*) FROM cached_chapters WHERE book_url='" + R1_BOOK_URL + "'; "
        "SELECT 'CH2='||COUNT(*) FROM chapters WHERE bookUrl='" + W2_BOOK_URL + "'; "
        "SELECT 'CC2='||COUNT(*) FROM cached_chapters WHERE book_url='" + W2_BOOK_URL + "'; "
        "SELECT 'BS_fixture='||COUNT(*) FROM book_sources WHERE bookSourceUrl IN "
        "(" + ",".join(f"'{u}'" for u in IMPORTED_SOURCE_URLS) + ");"
    )
    print(out.strip())


def remove() -> None:
    force_stop()
    book_urls = [R1_BOOK_URL, R1VB_BOOK_URL, W2_BOOK_URL, W2B_BOOK_URL]
    in_list = ",".join(f"'{u}'" for u in book_urls)
    src_in = ",".join(f"'{u}'" for u in IMPORTED_SOURCE_URLS)
    out = sql(
        "PRAGMA busy_timeout=5000; "
        f"DELETE FROM cached_chapters WHERE book_url IN ({in_list}); "
        f"DELETE FROM chapters WHERE bookUrl IN ({in_list}); "
        f"DELETE FROM books WHERE bookUrl IN ({in_list}); "
        f"DELETE FROM book_sources WHERE bookSourceUrl IN ({src_in}); "
    )
    print("[remove fixture rows]", out.strip() or "(ok)")
    # 本轮搜索可能在 searchBooks 留痕（夹具 bookUrl）
    out2 = sql(
        "PRAGMA busy_timeout=5000; "
        "DELETE FROM searchBooks WHERE bookUrl LIKE 'http://127.0.0.1:8092%' "
        "OR bookUrl LIKE 'http://127.0.0.1:8093%';"
    )
    print("[remove searchBooks fixture rows]", out2.strip() or "(ok)")
    check()
    out = sql(
        "SELECT 'books_total='||COUNT(*) FROM books; "
        "SELECT 'ch_total='||COUNT(*) FROM chapters; "
        "SELECT 'cc_total='||COUNT(*) FROM cached_chapters; "
        "SELECT 'sb_total='||COUNT(*) FROM searchBooks; "
        "SELECT 'bs_total='||COUNT(*) FROM book_sources; "
        "SELECT 'orphan_r1va_cc='||COUNT(*) FROM cached_chapters "
        "WHERE book_url='" + R1_BOOK_URL + "';"
    )
    print(out.strip())


def restore() -> None:
    force_stop()
    out = sql("PRAGMA busy_timeout=5000; " + DP_RESTORE)
    print("[restore 斗破苍穹]", out.strip() or "(ok)")
    out = sql(
        "PRAGMA busy_timeout=5000; "
        "UPDATE caches SET value='false' WHERE key='config:changeSourceLoadToc'; "
        "UPDATE caches SET value='' WHERE key='config:searchGroup';"
    )
    print("[restore caches]", out.strip() or "(ok)")
    before()
    out = sql(
        "SELECT 'loadToc='||value FROM caches WHERE key='config:changeSourceLoadToc'; "
        "SELECT 'searchGroup=['||COALESCE(value,'NULL')||']' FROM caches "
        "WHERE key='config:searchGroup'; "
        "SELECT 'dp='||durChapterIndex||'/'||durChapterPos||' tot='||totalChapterNum||"
        "' lt=['||COALESCE(latestChapterTitle,'')||']' FROM books "
        "WHERE bookUrl='" + DP_BOOK_URL + "';"
    )
    print(out.strip())


def before() -> None:
    out = sql(
        "SELECT bookUrl||' | '||origin||' | '||COALESCE(originName,'')||' | '||name||"
        "' | type='||type||' | tot='||totalChapterNum||' | dci='||durChapterIndex||"
        "' | dcp='||durChapterPos||' | lt=['||COALESCE(latestChapterTitle,'')||'] "
        "FROM books ORDER BY bookUrl; "
        "SELECT 'books_total='||COUNT(*) FROM books; "
        "SELECT 'ch_total='||COUNT(*) FROM chapters; "
        "SELECT 'cc_total='||COUNT(*) FROM cached_chapters; "
        "SELECT 'bs_total='||COUNT(*) FROM book_sources;"
    )
    print(out.strip())


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else "check"
    {"seed": seed, "remove": remove, "restore": restore,
     "check": check, "before": before}[cmd]()
