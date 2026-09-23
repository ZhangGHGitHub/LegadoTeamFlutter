# -*- coding: utf-8 -*-
"""p29b 场景 B 专用：种一本【真正的本地书】(origin='loc_book') 到
io.legado.flutter_legado 的 legado.db，使文字阅读器 isOnline=false，
从而验证阅读器菜单不渲染 换源/刷新正文/缓存当前章 三项（对齐 P2-9 fix）。

与共享工具 vui2_seed.py 的区别：vui2_seed 的 ORIGIN 非空（走在线路径，
isOnline=true），无法验证「本地书不渲染」断言；本脚本 ORIGIN='loc_book'
(BookType.localTag)，是本地书判定基准。不改 vui2_seed.py（共享工具）。

用法:
  python p29b_locseed.py seed     # 停应用→注入→校验
  python p29b_locseed.py remove   # 清理
  python p29b_locseed.py check
  python p29b_locseed.py before   # 记录 books 全量基线
"""
import subprocess
import time

ADB = r"D:\Android\platform-tools\adb.exe"
DEV = "127.0.0.1:16384"
PKG = "io.legado.flutter_legado"
DB = "app_flutter/legado.db"

BOOK_URL = "https://p29b.local/shelf/locbook"
NAME = "P29B本地验证书"
AUTHOR = "P29B本地"
ORIGIN = "loc_book"          # BookType.localTag → isOnline=false
ORIGIN_NAME = "P29B本地书"
# type = text(8) + local(0x1000=4096) = 4104；不设 notShelf(1024) → 入书架
TYPE = 8 + 4096
CHAPTERS = [
    ("https://p29b.local/loc/ch/0", "第一章 起点",
     "P29B本地正文·第一章。晨雾未散，少年背着木剑走出院落，踏上了修行之路。\n"
     "他今年十二岁，却已拥有远超同龄人的坚韧。为了查清父母失踪的真相，他必须变强。\n"
     "风卷起落叶，少年的脚步没有停。前方等待着他的，是比想象中更残酷的考验。"),
    ("https://p29b.local/loc/ch/1", "第二章 同行",
     "P29B本地正文·第二章。修行路上，他第一次遇见了同行的伙伴。\n"
     "两人互不相识，却在同一座山门前停下。山门之内，藏着一段被尘封的往事。"),
    ("https://p29b.local/loc/ch/2", "第三章 远方",
     "P29B本地正文·第三章。小队正式成立，向着远方的城邦进发。P29B本地正文·终。"),
]


def sh(cmd: str) -> str:
    r = subprocess.run([ADB, "-s", DEV, "shell", cmd],
                       capture_output=True, timeout=120)
    return r.stdout.decode("utf-8", "replace") + r.stderr.decode("utf-8", "replace")


def sql(queries: str) -> str:
    return sh(f'run-as {PKG} sqlite3 {DB} "{queries}"')


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
        f"VALUES ('{BOOK_URL}','{NAME}','{AUTHOR}',{TYPE},'{ORIGIN}',"
        f"'{ORIGIN_NAME}','{BOOK_URL}/toc',3,0,0,'',0);"
    )
    print("[books] 返回:", out.strip() or "(ok)")
    ch_stmts = []
    for idx, (url, title, _c) in enumerate(CHAPTERS):
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
            f"cached_at,size_bytes) VALUES ('{BOOK_URL}',{i},'{title}',"
            f"'{url}','{c}',{now},{len(content.encode('utf-8'))});"
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


def check(verbose: bool = False) -> None:
    q = (
        f"SELECT 'book='||name||' type='||type||' origin='||origin||"
        f"' dci='||durChapterIndex FROM books WHERE bookUrl='{BOOK_URL}'; "
        f"SELECT 'chapters='||COUNT(*) FROM chapters WHERE bookUrl='{BOOK_URL}'; "
        f"SELECT 'cached='||COUNT(*) FROM cached_chapters WHERE book_url='{BOOK_URL}';"
    )
    if verbose:
        q += (
            f" SELECT 'ch0_head='||SUBSTR(content,1,20) FROM cached_chapters "
            f"WHERE book_url='{BOOK_URL}' AND chapter_index=0;"
        )
    print(sql(q).strip())


def before() -> None:
    out = sql(
        "SELECT bookUrl||' | '||name||' | type='||type||"
        " ' | origin='||COALESCE(origin,'(null)') FROM books; "
        "SELECT 'ch_total='||COUNT(*) FROM chapters; "
        "SELECT 'cc_total='||COUNT(*) FROM cached_chapters;"
    )
    print(out.strip())


if __name__ == "__main__":
    import sys
    cmd = sys.argv[1] if len(sys.argv) > 1 else "check"
    {"seed": seed, "remove": remove, "check": lambda: check(),
     "before": before}[cmd]()
