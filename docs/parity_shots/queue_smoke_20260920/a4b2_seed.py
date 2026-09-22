# -*- coding: utf-8 -*-
"""A4B 实机验证：向 Test(192.168.1.19:5555) 的 legado.db 注入一本
零进度未读书（type=8 入书架、durChapterIndex=0/durChapterPos=0），
并预置 chapters + cached_chapters，使阅读器可离线显示首章正文
（get_chapter_content_full 命中 (book_url, chapter_url) 缓存，不触网）。
用法:
  python a4b2_seed.py seed    # 停应用→注入→校验
  python a4b2_seed.py remove  # 删除注入数据（清理）
  python a4b2_seed.py check   # 查询当前状态
"""
import subprocess
import time

ADB = r"D:\Android\platform-tools\adb.exe"
DEV = "192.168.1.19:5555"
PKG = "io.legado.flutter_legado"
DB = "app_flutter/legado.db"

BOOK_URL = "https://a4b2.local/shelf/book"
NAME = "A4B未读测试书"
AUTHOR = "A4B测试"
ORIGIN = "https://api.midureader.com"
ORIGIN_NAME = "米读小说"
CHAPTERS = [
    ("https://a4b2.local/ch/0", "第一章 起点",
     "斗罗大陆测试·第一章。清晨，海神湖畔的雾还未散，少年背着一把木剑走出院落。\n"
     "他今年十二岁，却已拥有远超同龄人的坚韧。为了查清父母的失踪真相，他踏上修行之路。\n"
     "风卷起地上的落叶，少年的脚步没有停。他知道，前方等待着他的，是比想象中更残酷的考验。"),
    ("https://a4b2.local/ch/1", "第二章 前行",
     "斗罗大陆测试·第二章。修行路上，他第一次遇见了同行的伙伴。\n"
     "两人互不相识，却在同一座山门前停下。山门之内，藏着一段被尘封的往事。\n"
     "随着门扉缓缓开启，一股磅礴的气息扑面而来。"),
    ("https://a4b2.local/ch/2", "第三章 远方",
     "斗罗大陆测试·第三章。三人的小队正式成立，向着远方的武魂城进发。\n"
     "道路漫长，危险与机遇并存。而少年的眼神，始终望向更远的地方。"),
]


def sh(cmd: str) -> str:
    r = subprocess.run([ADB, "-s", DEV, "shell", cmd],
                       capture_output=True, timeout=120)
    return r.stdout.decode("utf-8", "replace") + r.stderr.decode("utf-8", "replace")


def sql(queries: str) -> str:
    """在设备上以 run-as 执行 sqlite3（多语句用分号连接）。"""
    # 设备侧 sh 命令：run-as pkg sqlite3 db "SQL"
    dev_cmd = f'run-as {PKG} sqlite3 {DB} "{queries}"'
    return sh(dev_cmd)


def now_ms() -> int:
    return int(time.time() * 1000)


def seed() -> None:
    print("==> force-stop", PKG)
    sh(f"am force-stop {PKG}")
    time.sleep(1)

    now = now_ms()
    stmts = []
    # books：type=8（文本位），无 notShelf(0x400) → 入书架；零进度
    stmts.append(
        "INSERT OR REPLACE INTO books "
        "(bookUrl,name,author,type,origin,originName,tocUrl,totalChapterNum,"
        "durChapterIndex,durChapterPos,durChapterTitle,lastCheckTime) "
        f"VALUES ('{BOOK_URL}','{NAME}','{AUTHOR}',8,'{ORIGIN}','{ORIGIN_NAME}',"
        f"'{BOOK_URL}/toc',3,0,0,'',0);"
    )
    for idx, (url, title, _content) in enumerate(CHAPTERS):
        stmts.append(
            "INSERT OR REPLACE INTO chapters "
            "(url,title,isVolume,baseUrl,bookUrl,[index],isVip,isPay) "
            f"VALUES ('{url}','{title}',0,'{BOOK_URL}','{BOOK_URL}',"
            f"{idx},0,0);"
        )
    for i, (url, title, content) in enumerate(CHAPTERS):
        # 转义单引号（内容里无单引号，保险起见）
        c = content.replace("'", "''")
        stmts.append(
            "INSERT OR REPLACE INTO cached_chapters "
            "(book_url,chapter_index,chapter_title,chapter_url,content,cached_at,size_bytes) "
            f"VALUES ('{BOOK_URL}',{i},'{title}','{url}','{c}',{now},{len(content.encode('utf-8'))});"
        )
    out = sql(";".join([]) or "".join(stmts))
    print("seed SQL 执行返回:", out.strip() or "(ok)")

    # 校验
    chk = sql(
        f"SELECT 'book='||name||' dci='||durChapterIndex||' dcp='||durChapterPos "
        f"FROM books WHERE bookUrl='{BOOK_URL}'; "
        f"SELECT 'chapters='||COUNT(*) FROM chapters WHERE bookUrl='{BOOK_URL}'; "
        f"SELECT 'cached='||COUNT(*) FROM cached_chapters WHERE book_url='{BOOK_URL}';"
    )
    print(chk.strip())


def remove() -> None:
    print("==> force-stop", PKG)
    sh(f"am force-stop {PKG}")
    time.sleep(1)
    out = sql(
        f"DELETE FROM cached_chapters WHERE book_url='{BOOK_URL}'; "
        f"DELETE FROM chapters WHERE bookUrl='{BOOK_URL}'; "
        f"DELETE FROM books WHERE bookUrl='{BOOK_URL}';"
    )
    print("remove 返回:", out.strip() or "(ok)")
    chk = sql(f"SELECT 'books_left='||COUNT(*) FROM books WHERE bookUrl='{BOOK_URL}';")
    print(chk.strip())


def check() -> None:
    out = sql(
        f"SELECT name,durChapterIndex,durChapterPos FROM books WHERE bookUrl='{BOOK_URL}'; "
        f"SELECT 'ch='||COUNT(*) FROM chapters WHERE bookUrl='{BOOK_URL}'; "
        f"SELECT 'cc='||COUNT(*) FROM cached_chapters WHERE book_url='{BOOK_URL}';"
    )
    print(out.strip())


if __name__ == "__main__":
    import sys
    cmd = sys.argv[1] if len(sys.argv) > 1 else "check"
    {"seed": seed, "remove": remove, "check": check}[cmd]()
