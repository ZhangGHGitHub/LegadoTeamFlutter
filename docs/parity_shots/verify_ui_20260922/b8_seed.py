# -*- coding: utf-8 -*-
"""b8 补验（P2-21 08 屏「在读/最新/共N章」三行块）种子脚本。

复用 vui2_seed.py 的全部机制（同 DB 路径 app_flutter/legado.db、同 run-as
sqlite3 通道、同 BOOK_URL、同 3 章目录+离线正文、同 force-stop 时机），
仅把进度字段改成两个场景：

  场景 A（存储值优先）：
    durChapterTitle='引子 测试标题'（≠ 目录任何章标题，可证存储值优先）
    + durChapterIndex=1 + durChapterPos=1234(>0)
    + latestChapterTitle='测试最新章'（普通标题 → 最新行直出）
    期望：在读 · 引子 测试标题 / 最新 · 测试最新章 / 共 3 章 | 已读 2 章

  场景 B（目录回落，off-by-one 回归证明）：
    durChapterTitle=''（空 → 回落目录）+ 同 dci=1 + dcp=1234
    + latestChapterTitle='已完结'（状态词 → E5 回落目录末章）
    期望：在读 · 第二章 前行（chapters[1]，非第一章 起点）/
          最新 · 第三章 远方（末章回落，无「（全书完）」后缀）/
          共 3 章 | 已读 2 章（N=dci+1=2，2≠3 非已读完）

用法（在 docs/parity_shots/verify_ui_20260922/ 下或任意 cwd）：
  python b8_seed.py seed_a    # 场景 A 落库（停应用→注入→快照）
  python b8_seed.py seed_b    # 场景 B 落库（UPDATE 进度字段→快照）
  python b8_seed.py remove    # 清理（复用 vui2_seed.remove 三表删除）
  python b8_seed.py verify    # 清理后复核（books 残留 0 + 基线原样）
"""
import sys
import time

import vui2_seed as V  # 同目录复用：DB 路径/BOOK_URL/CHAPTERS/sql/sh/force_stop/remove

BOOK_URL = V.BOOK_URL


def sql(queries: str) -> str:
    return V.sql(queries)


def now_ms() -> int:
    return int(time.time() * 1000)


def _insert_book(dci: int, dcp: int, dtitle: str, ltitle: str) -> None:
    q = (
        "PRAGMA busy_timeout=5000; "
        "INSERT OR REPLACE INTO books "
        "(bookUrl,name,author,type,origin,originName,tocUrl,totalChapterNum,"
        "latestChapterTitle,durChapterIndex,durChapterPos,durChapterTitle,lastCheckTime) "
        f"VALUES ('{BOOK_URL}','{V.NAME}','{V.AUTHOR}',8,'{V.ORIGIN}','{V.ORIGIN_NAME}',"
        f"'{BOOK_URL}/toc',3,'{ltitle}',{dci},{dcp},'{dtitle}',{now_ms()});"
    )
    print("[books]", sql(q).strip() or "(ok)")


def _seed_toc() -> None:
    ch_stmts = []
    for idx, (url, title, _content) in enumerate(V.CHAPTERS):
        ch_stmts.append(
            "INSERT OR REPLACE INTO chapters "
            "(url,title,isVolume,baseUrl,bookUrl,[index],isVip,isPay) "
            f"VALUES ('{url}','{title}',0,'{BOOK_URL}','{BOOK_URL}',"
            f"{idx},0,0);"
        )
    print("[chapters]",
          sql("PRAGMA busy_timeout=5000; " + "".join(ch_stmts)).strip() or "(ok)")
    cc_stmts = []
    for i, (url, title, content) in enumerate(V.CHAPTERS):
        c = content.replace("'", "''")
        cc_stmts.append(
            "INSERT OR REPLACE INTO cached_chapters "
            "(book_url,chapter_index,chapter_title,chapter_url,content,cached_at,size_bytes) "
            f"VALUES ('{BOOK_URL}',{i},'{title}','{url}','{c}',{now_ms()}, "
            f"{len(content.encode('utf-8'))});"
        )
    print("[cached_chapters]",
          sql("PRAGMA busy_timeout=5000; " + "".join(cc_stmts)).strip() or "(ok)")


def db_snapshot(scene: str) -> None:
    out = sql(
        "SELECT bookUrl||' | '||name||' | type='||type||' | dci='||durChapterIndex||' | dcp='||durChapterPos||' | dt=['||durChapterTitle||'] | lt=['||COALESCE(latestChapterTitle,'NULL')||'] | total='||totalChapterNum "
        f"FROM books WHERE bookUrl='{BOOK_URL}'; "
        f"SELECT 'chapters='||COUNT(*) FROM chapters WHERE bookUrl='{BOOK_URL}'; "
        f"SELECT 'cached='||COUNT(*) FROM cached_chapters WHERE book_url='{BOOK_URL}'; "
        f"SELECT '[index]='||[index]||' '||title "
        f"FROM chapters WHERE bookUrl='{BOOK_URL}' ORDER BY [index];"
    )
    print(f"=== db_snapshot 场景 {scene} ===")
    print(out.strip())


def seed_a() -> None:
    V.force_stop()
    _insert_book(dci=1, dcp=1234, dtitle="引子 测试标题", ltitle="测试最新章")
    _seed_toc()
    db_snapshot("A")


def seed_b() -> None:
    V.force_stop()
    _insert_book(dci=1, dcp=1234, dtitle="", ltitle="已完结")
    _seed_toc()
    db_snapshot("B")


def remove() -> None:
    V.remove()


def verify() -> None:
    V.force_stop()
    out = sql(
        "SELECT 'seed_left='||COUNT(*) FROM books WHERE bookUrl='" + BOOK_URL + "'; "
        "SELECT 'ch_left='||COUNT(*) FROM chapters WHERE bookUrl='" + BOOK_URL + "'; "
        "SELECT 'cc_left='||COUNT(*) FROM cached_chapters WHERE book_url='" + BOOK_URL + "';"
    )
    print("=== 清理后复核 ===")
    print(out.strip())
    print("=== 基线全量（应 = b8_db_before.txt 的 2 条 + 表计数）===")
    V.before()


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else "verify"
    {"seed_a": seed_a, "seed_b": seed_b, "remove": remove, "verify": verify}[cmd]()
