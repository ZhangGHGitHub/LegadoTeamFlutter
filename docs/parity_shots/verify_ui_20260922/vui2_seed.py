# -*- coding: utf-8 -*-
"""VUI2 补验（Test2 = MuMu 127.0.0.1:16384）：向 io.legado.flutter_legado 的
legado.db 注入一本零进度未读文字书（type=8 文本位、入书架、
durChapterIndex=0/durChapterPos=0），并预置 chapters + cached_chapters，
使文字阅读器可离线显示首章正文（get_chapter_content_full 命中
(book_url, chapter_url) 缓存，零网络）。

思路复用 docs/parity_shots/queue_smoke_20260920/a4b2_seed.py（该脚本面向
192.168.1.19:5555；本机改为 127.0.0.1:16384，run-as 通道相同）。
DB 路径：/data/data/io.legado.flutter_legado/app_flutter/legado.db
（MuMu adbd 无 su，但装的是 debug 包 → run-as 可用）。

用法:
  python vui2_seed.py seed     # 停应用→注入→校验
  python vui2_seed.py remove   # 删除注入数据（清理）
  python vui2_seed.py check    # 查询当前状态
  python vui2_seed.py before   # 记录注入前基线（books 全量）
"""
import subprocess
import time

ADB = r"D:\Android\platform-tools\adb.exe"
DEV = "127.0.0.1:16384"
PKG = "io.legado.flutter_legado"
DB = "app_flutter/legado.db"

BOOK_URL = "https://vui2.local/shelf/book"
NAME = "VUI2补验书"
AUTHOR = "VUI2补验"
ORIGIN = "https://vui2.local/origin"  # 非空：走在线书路径（无注册书源→不联网补目录）
ORIGIN_NAME = "VUI2本地源"
CHAPTERS = [
    ("https://vui2.local/ch/0", "第一章 起点",
     "VUI2正文·第一章起点。清晨，海神湖畔的雾还未散去，少年背着一把木剑走出院落。\n"
     "他今年十二岁，却已拥有远超同龄人的坚韧。为了查清父母失踪的真相，他踏上了修行之路。\n"
     "风卷起地上的落叶，少年的脚步没有停。他知道，前方等待着他的，是比想象中更残酷的考验。\n"
     "湖边的芦苇在晨风中摇曳，远处隐约传来钟声。少年握紧手中的木剑，目光坚定地望向山门的方向。\n"
     "这一去，便是万里。他不知道等待自己的究竟是什么，但父母的失踪像一根刺，扎在他心里。\n"
     "少年最后回头望了一眼院落，那里有他生活了十二年的家。然后他转身，头也不回地走入了晨雾之中。\n"
     "晨雾渐渐散去，少年的身影越来越远，最终消失在山路的拐角处。新的旅程，就此开始。"),
    ("https://vui2.local/ch/1", "第二章 前行",
     "VUI2正文·第二章前行。修行路上，他第一次遇见了同行的伙伴。\n"
     "两人互不相识，却在同一座山门前停下。山门之内，藏着一段被尘封的往事。\n"
     "随着门扉缓缓开启，一股磅礴的气息扑面而来。少年深吸一口气，握紧了手中的木剑。\n"
     "同行的是个沉默的少年，背负着一把比他人还高的长剑。两人相视点头，不必多言。\n"
     "山门内的石阶盘旋而上，两侧的石壁上刻满了古老的符文，散发着微弱的蓝光。\n"
     "每走一段，空气便凝重一分。少年感到体内的灵力在微微躁动，仿佛在回应着这座山门的气息。\n"
     "走到石阶尽头，是一座环形广场。广场中央立着一块巨大的石碑，上面刻着四个大字：武魂圣地。\n"
     "两位少年同时驻足，望向石碑。风从山谷中涌来，吹动了他们的衣角。征程继续，而远方还有更远的路。"),
    ("https://vui2.local/ch/2", "第三章 远方",
     "VUI2正文·第三章远方。三人的小队正式成立，向着远方的武魂城进发。\n"
     "道路漫长，危险与机遇并存。而少年的眼神，始终望向更远的地方。\n"
     "第三天的清晨，队伍在河边休整。少年坐在岸边，看着河水缓缓流过，心中默默盘算着行程。\n"
     "按照地图上的标记，再有七天的路程，便能望见武魂城的方向。七天，说长不长，说短不短。\n"
     "伙伴们在身后搭起了帐篷。篝火升起来，照亮了三张年轻的面孔。这一夜，没有人睡着。\n"
     "远方，武魂城的灯火在夜色中若隐若现，像是一颗跳动的心脏。少年知道，那里有答案，\n"
     "也有新的挑战。他闭上眼睛，把这份信念压入心底。明日，继续前行。VUI2补验正文·终。"),
]


def sh(cmd: str) -> str:
    r = subprocess.run([ADB, "-s", DEV, "shell", cmd],
                       capture_output=True, timeout=120)
    return r.stdout.decode("utf-8", "replace") + r.stderr.decode("utf-8", "replace")


def sql(queries: str) -> str:
    """在设备上以 run-as 执行 sqlite3（多语句用分号连接）。"""
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
        f"VALUES ('{BOOK_URL}','{NAME}','{AUTHOR}',8,'{ORIGIN}','{ORIGIN_NAME}',"
        f"'{BOOK_URL}/toc',3,0,0,'',0);"
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
            "(book_url,chapter_index,chapter_title,chapter_url,content,cached_at,size_bytes) "
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


def check(verbose: bool = False) -> None:
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
            f"WHERE book_url='{BOOK_URL}' AND chapter_index=0; "
            f" SELECT 'ch1_head='||SUBSTR(content,1,24) FROM cached_chapters "
            f"WHERE book_url='{BOOK_URL}' AND chapter_index=1;"
        )
    print(sql(q).strip())


def before() -> None:
    out = sql(
        "SELECT bookUrl||' | '||name||' | type='||type||"
        " ' | dci='||durChapterIndex||' | shelf_bit='||"
        "(CASE WHEN type & 1024 THEN 1 ELSE 0 END) FROM books; "
        "SELECT 'ch_total='||COUNT(*) FROM chapters; "
        "SELECT 'cc_total='||COUNT(*) FROM cached_chapters;"
    )
    print(out.strip())


if __name__ == "__main__":
    import sys
    cmd = sys.argv[1] if len(sys.argv) > 1 else "check"
    {"seed": seed, "remove": remove, "check": lambda: check(),
     "before": before}[cmd]()
