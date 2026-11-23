#!/usr/bin/env python3
"""QA 9b-1 SQL 生成器（验收夹具，非产品代码）。

用法:
  python gen_qa9b1_sql.py s1   --base-ms <device_now_ms>
  python gen_qa9b1_sql.py s2   --base-ms <device_now_ms>
  python gen_qa9b1_sql.py grid --base-ms <device_now_ms> --lo -4000 --hi 8000 --step 100
  python gen_qa9b1_sql.py grid --base-ms <device_now_ms> --lo -2000 --hi 2000 --step 1
  python gen_qa9b1_sql.py bulk --base-ms <device_now_ms> --count 20000
  python gen_qa9b1_sql.py trigger-on
  python gen_qa9b1_sql.py trigger-off
  python gen_qa9b1_sql.py cleanup

base-ms 为设备侧 epoch 毫秒（由设备 sqlite3 计算，避免主机/设备时钟偏差）。
输出到 stdout。
"""
import argparse
import sys

SRC = "https://qa9b1.example/source"
SRC_NAME = "QA9B1测试源"

HEADER = f"""
PRAGMA foreign_keys=ON;
INSERT OR REPLACE INTO book_sources
  (bookSourceUrl, bookSourceName, bookSourceType, lastUpdateTime, respondTime, weight)
  VALUES ('{SRC}', '{SRC_NAME}', 0, 0, 0, 0);
"""


def q(s: str) -> str:
    return "'" + s.replace("'", "''") + "'"


def row(url: str, name: str, t: int) -> str:
    return (
        "INSERT OR REPLACE INTO searchBooks "
        "(bookUrl,origin,originName,type,name,author,tocUrl,time,originOrder) VALUES "
        f"({q(url)},{q(SRC)},{q(SRC_NAME)},0,{q(name)},{q('QA作者')},"
        f"{q(SRC + '/toc/' + name)}, {t}, 0);"
    )


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("mode")
    ap.add_argument("--base-ms", type=int)
    ap.add_argument("--lo", type=int, default=-4000)
    ap.add_argument("--hi", type=int, default=8000)
    ap.add_argument("--step", type=int, default=100)
    ap.add_argument("--count", type=int, default=20000)
    a = ap.parse_args()

    if a.mode == "s1":
        base = a.base_ms
        assert base is not None
        day = 86400000
        print(HEADER)
        print("DELETE FROM searchBooks WHERE bookUrl LIKE 'qa9b1_%';")
        print(row("qa9b1_s1_2d", "QA旧书-2天", base - 2 * day))
        print(row("qa9b1_s1_1d1m", "QA旧书-1天1分", base - day - 60000))
        print(row("qa9b1_s1_1h", "QA新书-1小时", base - 3600000))
        print(f"-- base_ms={base}")
        return 0

    if a.mode == "s2":
        base = a.base_ms
        assert base is not None
        day = 86400000
        print(HEADER)
        print("DELETE FROM searchBooks WHERE bookUrl LIKE 'qa9b1_%';")
        print(row("qa9b1_s2_3d", "QA旧书S2-3天", base - 3 * day))
        print(row("qa9b1_s2_2d", "QA旧书S2-2天", base - 2 * day))
        print(row("qa9b1_s2_1h", "QA新书S2-1小时", base - 3600000))
        print(f"-- base_ms={base}")
        return 0

    if a.mode == "grid":
        base = a.base_ms
        assert base is not None
        day = 86400000
        print(HEADER)
        print("DELETE FROM searchBooks WHERE bookUrl LIKE 'qa9b1_%';")
        print("BEGIN;")
        i = 0
        off = a.lo
        while off <= a.hi:
            t = base - day + off
            print(row(f"qa9b1_g_{off}", f"QA边界{off:+d}ms", t))
            i += 1
            off += a.step
        print("COMMIT;")
        print(f"-- grid rows={i} base_ms={base} lo={a.lo} hi={a.hi} step={a.step}")
        return 0

    if a.mode == "bulk":
        base = a.base_ms
        assert base is not None
        day = 86400000
        print(HEADER)
        print("DELETE FROM searchBooks WHERE bookUrl LIKE 'qa9b1_%';")
        print("BEGIN;")
        for i in range(a.count):
            print(row(f"qa9b1_bulk_{i}", f"QA批量旧书{i}", base - 2 * day - i))
        print("COMMIT;")
        print(f"-- bulk rows={a.count} base_ms={base}")
        return 0

    if a.mode == "trigger-on":
        print("DROP TRIGGER IF EXISTS qa9b1_fail_delete;")
        print(
            "CREATE TRIGGER qa9b1_fail_delete BEFORE DELETE ON searchBooks "
            "BEGIN SELECT RAISE(ABORT, 'QA9B1 injected delete failure'); END;"
        )
        return 0

    if a.mode == "trigger-off":
        print("DROP TRIGGER IF EXISTS qa9b1_fail_delete;")
        return 0

    if a.mode == "cleanup":
        print("DROP TRIGGER IF EXISTS qa9b1_fail_delete;")
        print(f"DELETE FROM book_sources WHERE bookSourceUrl = '{SRC}';")
        print("DELETE FROM searchBooks WHERE bookUrl LIKE 'qa9b1_%';")
        return 0

    print(f"unknown mode: {a.mode}", file=sys.stderr)
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
