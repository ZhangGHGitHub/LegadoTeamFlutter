# -*- coding: utf-8 -*-
"""P29 场景 3（本地书入口隐藏）：向 io.legado.flutter_legado 的
legado.db 注入一本本地书（origin='loc_book'，type=8|0x1000=4104 文本+local
位、入书架、durChapterIndex=0/durChapterPos=0），并预置 chapters +
cached_chapters，使文字阅读器可离线显示首章正文（get_chapter_content_full
命中 (book_url, chapter_url) 缓存，零网络）。

用法（与 vui2_seed.py 相同，本机 127.0.0.1:16384，run-as 通道）：
  python p29_local_seed.py before   # 记录注入前基线（books 全量）
  python p29_local_seed.py seed     # 停应用→注入→校验
  python p29_local_seed.py check    # 查询当前状态
  python p29_local_seed.py remove   # 删除注入数据（清理）
"""
import subprocess
import time

ADB = r"D:\Android\platform-tools\adb.exe"
DEV = "127.0.0.1:16384"
PKG = "io.legado.flutter_legado"
DB = "app_flutter/legado.db"

BOOK_URL = "https://p29.local/shelf/book"
NAME = "P29本地书"
AUTHOR = "P29验证"
ORIGIN = "loc_book"  # BookType.localTag：本地书标记
ORIGIN_NAME = "本地书"
TYPE_BITS = 8 | 0x1000  # text | local = 4104
CHAPTERS = [
    ("https://p29.local/ch/0", "第一章 本地起点",
     "P29本地正文·第一章本地起点。清晨，P29 验证书的第一行特征片段在此。\n"
     "第二段：本地书正文第二段，用于确认离线渲染。\n"
     "第三段：P29 本地书正文结束标记。"),
    ("https://p29.local/ch/1", "第二章 本地前行",
     "P29本地正文·第二章本地前行。\n第二段：本地书第二章正文。"),
    ("https://p29.local/ch/2", "第三章 本地远方",
     "P29本地正文·第三章本地远方。\n第二段：本地书第三章正文。P29 终。"),
]


def sh(cmd: str) -> str:
    r = subprocess.run([ADB, "-s", DEV, "shell", cmd],
                       capture_output=True, timeout=120)
    return r.stdout.decode("utf-8", "replace") + r.stderr.decode("utf-8", "replace")


def sql(queries: str) -> str:
    dev_cmd = f'run-as {PKG} sqlite3 {DB} "{queries}"'
    return sh(dev_cmd)


def now_ms() -> int:
    return int(time.time() * 1000)


def force_stop() -> None:
    print("==> force-stop", PKG)
    sh(f"am force-stop {PKG}")
    time.sleep(2)


def seed() -> None:
    force_stop()
    now = now_ms()

    out = sql(
        "PRAGMA busy_timeout=5000; "
        "INSERT OR REPLACE INTO books "
        "(bookUrl,name,author,type,origin,originName,tocUrl,totalChapterNum,"
        "durChapterIndex,durChapterPos,durChapterTitle,lastCheckTime) "
        f"VALUES ('{BOOK_URL}','{NAME}','{AUTHOR}',{TYPE_BITS},'{ORIGIN}',"
        f"'{ORIGIN_NAME}','{BOOK_URL}/toc',3,0,0,'',0);"
    )
    print("[books] 返回:", out.strip() or "(ok)")

    ch_stmts = []
    for idx, (url, title, _content) in enumerate(CHAPTERS):
        ch_stmts.append(
            "INSERT OR REPLACE INTO chapters "
            "(url,title,isVolume,baseUrl,bookUrl,[index],isVip,isPay) "
            f"VALUES ('{url}','{title}',0,'{BOOK_URL}','{BOOK_URL}',"
            f"{idx},0,0);"
        )
    out = sql("PRAGMA busy_timeout=5000; " + "".join(ch_stmts))
    print("[chapters] 返回:", out.strip() or "(ok)")

    cc_stmts = []
    for i, (url, title, content) in enumerate(CHAPTERS):
        c = content.replace("'", "''")
        cc_stmts.append(
            "INSERT OR REPLACE INTO cached_chapters "
            "(book_url,chapter_index,chapter_title,chapter_url,content,"
            "cached_at,size_bytes) "
            f"VALUES ('{BOOK_URL}',{i},'{title}','{url}','{c}',{now},"
            f"{len(content.encode('utf-8'))});"
        )
    out = sql("PRAGMA busy_timeout=5000; " + "".join(cc_stmts))
    print("[cached_chapters] 返回:", out.strip() or "(ok)")

    check(verbose=True)


def remove() -> None:
    force_stop()
    out = sql(
        "PRAGMA busy_timeout=5000; "
        f"DELETE FROM cached_chapters WHERE book_url='{BOOK_URL}'; "
        f"DELETE FROM chapters WHERE bookUrl='{BOOK_URL}'; "
        f"DELETE FROM books WHERE bookUrl='{BOOK_URL}';"
    )
    print("[remove] 返回:", out.strip() or "(ok)")
    check()


def check(verbose: bool = False) -> str:
    q = (
        f"SELECT 'book='||name||' dci='||durChapterIndex||"
        f"' dcp='||durChapterPos||' type='||type||' origin='||origin "
        f"FROM books WHERE bookUrl='{BOOK_URL}'; "
        f"SELECT 'chapters='||COUNT(*) FROM chapters WHERE bookUrl='{BOOK_URL}'; "
        f"SELECT 'cached='||COUNT(*) FROM cached_chapters WHERE book_url='{BOOK_URL}';"
    )
    if verbose:
        q += (
            f" SELECT 'ch0_head='||SUBSTR(content,1,24) FROM cached_chapters "
            f"WHERE book_url='{BOOK_URL}' AND chapter_index=0;"
        )
    return sql(q).strip()


def before() -> None:
    out = sql(
        "SELECT bookUrl||' | '||name||' | type='||type||"
        " ' | origin='||origin||' | notShelf='||"
        "(CASE WHEN type & 1024 THEN 1 ELSE 0 END) FROM books; "
        "SELECT 'ch_total='||COUNT(*) FROM chapters; "
        "SELECT 'cc_total='||COUNT(*) FROM cached_chapters;"
    )
    print(out.strip())


if __name__ == "__main__":
    import sys
    cmd = sys.argv[1] if len(sys.argv) > 1 else "check"
    {"seed": seed, "remove": remove, "check": lambda: print(check()),
     "before": before}[cmd]()
