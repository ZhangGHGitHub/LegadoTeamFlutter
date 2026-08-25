# -*- coding: utf-8 -*-
"""Supplemental walkthrough — unicode-safe labels."""
import re
import subprocess
import sys
import time
from pathlib import Path

sys.stdout.reconfigure(encoding="utf-8")

ADB = r"D:\Android\platform-tools\adb.exe"
DEV = "emulator-5556"
OUT = Path(r"D:\OH-WorkSpace\LegadoTeam\legado\docs\gap_audit_2026-08-12")
PKG = "io.legado.flutter_legado"
ACT = "io.legado.flutter.MainActivity"
ORIG = "com.legado.app.release"

# Unicode-safe constants
L_BOOKSHELF = "\u4e66\u67b6"  # 书架
L_DISCOVER = "\u53d1\u73b0"  # 发现
L_RSS = "\u8ba2\u9605"  # 订阅
L_MINE = "\u6211\u7684"  # 我的
L_SEARCH = "\u641c\u7d22"  # 搜索
L_SHOW_MENU = "Show menu"
L_SOURCES = "\u4e66\u6e90\u7ba1\u7406"  # 书源管理
L_REPLACE = "\u66ff\u6362\u51c0\u5316"  # 替换净化
L_READ_REC = "\u9605\u8bfb\u8bb0\u5f55"  # 阅读记录
L_THEME = "\u4e3b\u9898\u8bbe\u7f6e"  # 主题设置
L_OTHER = "\u5176\u4ed6\u8bbe\u7f6e"  # 其他设置
L_BACKUP = "\u5907\u4efd"  # 备份
L_MCP = "MCP"
L_AUTOTASK = "\u5b9a\u65f6\u4efb\u52a1"  # 定时任务
L_BOOKMARK = "\u4e66\u7b7e"  # 书签
L_ABOUT = "\u5173\u4e8e"  # 关于
L_FILES = "\u6587\u4ef6\u7ba1\u7406"  # 文件管理
L_DICT = "\u8bcd\u5178"  # 词典
L_TXT = "TXT"
L_GROUP = "\u5206\u7ec4"  # 分组
L_MORE = "\u66f4\u591a"  # 更多
L_NEW = "\u65b0\u5efa"  # 新建
L_JS = "JS"
L_REMOTE = "\u8fdc\u7a0b"  # 远程
L_LOCAL = "\u672c\u5730"  # 本地
L_MANAGE = "\u4e66\u67b6\u7ba1\u7406"  # 书架管理
L_CACHE = "\u7f13\u5b58"  # 缓存
L_GROUPS = "\u5206\u7ec4\u7ba1\u7406"  # 分组管理
L_CONTINUE = "\u7ee7\u7eed\u9605\u8bfb"  # 继续阅读
L_START = "\u5f00\u59cb\u9605\u8bfb"  # 开始阅读
L_TOC = "\u76ee\u5f55"  # 目录
L_TITLE = "\u91cd\u751f\u9ad8\u8003\u524d99\u5929"  # 重生高考前99天
L_COVER = "99+"
L_RECORD = "\u8bb0\u5f55"  # 记录
L_GROUP_MANAGE = "\u5206\u7ec4\u7ba1\u7406"


def adb(*args):
    subprocess.run([ADB, "-s", DEV, *args], capture_output=True)


def dump(name):
    adb("shell", "uiautomator", "dump", "/sdcard/ui_dump.xml")
    local = OUT / f"{name}.xml"
    adb("pull", "/sdcard/ui_dump.xml", str(local))
    return local.read_text(encoding="utf-8")


def shot(name):
    adb("shell", "screencap", "-p", f"/sdcard/{name}.png")
    adb("pull", f"/sdcard/{name}.png", str(OUT / f"{name}.png"))


def parse(xml):
    pat = re.compile(
        r'content-desc="([^"]*)"[^>]*bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"'
    )
    nodes = []
    for m in pat.finditer(xml):
        desc = m.group(1).replace("&#10;", "\n")
        if not desc:
            continue
        x1, y1, x2, y2 = map(int, m.groups()[1:])
        nodes.append(
            {
                "desc": desc,
                "cx": (x1 + x2) // 2,
                "cy": (y1 + y2) // 2,
                "bounds": (x1, y1, x2, y2),
            }
        )
    return nodes


def find(nodes, substr):
    if not nodes:
        return None
    for n in nodes:
        if substr in n["desc"]:
            return n
    return None


def find_exact(nodes, text):
    for n in nodes:
        if n["desc"] == text:
            return n
    return None


def tap(n):
    if not n:
        return False
    adb("shell", "input", "tap", str(n["cx"]), str(n["cy"]))
    time.sleep(1.0)
    return True


def longpress(n, ms=1200):
    if not n:
        return False
    x, y = n["cx"], n["cy"]
    adb("shell", "input", "swipe", str(x), str(y), str(x), str(y), str(ms))
    time.sleep(1.2)
    return True


def back():
    adb("shell", "input", "keyevent", "4")
    time.sleep(0.8)


def start_flutter():
    adb("shell", "am", "start", "-n", f"{PKG}/{ACT}")
    time.sleep(2.2)


def labels(nodes, limit=45):
    out = []
    for n in nodes:
        d = n["desc"].split("\n")[0][:40]
        if d not in out:
            out.append(d)
    return " | ".join(out[:limit])


def go_mine():
    start_flutter()
    nodes = parse(dump("tmp"))
    tap(find(nodes, L_MINE))
    time.sleep(0.8)
    return parse(dump("tmp"))


def main():
    notes = []
    OUT.mkdir(parents=True, exist_ok=True)

    # --- Title long-press ---
    start_flutter()
    nodes = parse(dump("tmp"))
    print("bookshelf:", labels(nodes))
    title = find_exact(nodes, L_TITLE)
    if not title:
        # fallback: title-only node under cover (y>500)
        for n in nodes:
            if L_TITLE in n["desc"] and n["bounds"][1] >= 500 and "\n" not in n["desc"]:
                title = n
                break
    print("title:", title)
    if title:
        longpress(title)
        xml = dump("03_flutter_longpress_title")
        shot("03_flutter_longpress_title")
        nodes = parse(xml)
        print("after title LP:", labels(nodes))
        joined = " ".join(x["desc"] for x in nodes)
        sheet = any(k in joined for k in ["\u67e5\u770b\u8be6\u60c5", "\u7f6e\u9876", "\u7f16\u8f91", "\u5206\u4eab", "\u5220\u9664"])
        info = "\u4e66\u7c4d\u4fe1\u606f" in joined
        notes.append(f"title_longpress sheet={sheet} info={info} labels={labels(nodes)[:120]}")
        back()

    # --- Bookshelf menu ---
    start_flutter()
    if tap(find(parse(dump("tmp")), L_SHOW_MENU)):
        xml = dump("24_flutter_bookshelf_menu")
        shot("24_flutter_bookshelf_menu")
        nodes = parse(xml)
        print("bs menu:", labels(nodes))
        notes.append(f"bookshelf_menu: {labels(nodes)}")
        for key, fname in [
            (L_REMOTE, "25_flutter_remote"),
            (L_LOCAL, "26_flutter_local"),
            (L_MANAGE, "27_flutter_manage"),
            (L_CACHE, "28_flutter_cache"),
            (L_GROUPS, "29_flutter_groups"),
        ]:
            n = find(nodes, key)
            if not n:
                print("menu miss", key)
                continue
            tap(n)
            time.sleep(1.0)
            dump(fname)
            shot(fname)
            print(fname, labels(parse((OUT / f"{fname}.xml").read_text(encoding="utf-8"))))
            notes.append(f"{key}->{fname}: {labels(parse((OUT / f'{fname}.xml').read_text(encoding='utf-8')))[:90]}")
            back()
            start_flutter()
            tap(find(parse(dump("tmp")), L_SHOW_MENU))
            nodes = parse(dump("tmp"))

    # --- Search menu ---
    start_flutter()
    if tap(find(parse(dump("tmp")), L_SEARCH)):
        time.sleep(1)
        dump("18_flutter_search")
        shot("18_flutter_search")
        m = find(parse(dump("tmp")), L_SHOW_MENU) or find(parse(dump("tmp")), L_MORE)
        if tap(m):
            xml = dump("19_flutter_search_menu")
            shot("19_flutter_search_menu")
            nodes = parse(xml)
            print("search menu:", labels(nodes))
            notes.append(f"search_menu: {labels(nodes)}")
            n = find(nodes, L_RECORD) or find(nodes, "\u641c\u7d22\u8bb0\u5f55")
            if tap(n):
                time.sleep(0.8)
                dump("19b_search_record_stub")
                shot("19b_search_record_stub")
                print("search record stub:", labels(parse(dump("19b_search_record_stub"))))
                notes.append(f"search_record: {labels(parse(dump('19b_search_record_stub')))[:100]}")
        back()

    # --- Source overflow / JS stub / group ---
    nodes = go_mine()
    print("mine:", labels(nodes))
    if tap(find(nodes, L_SOURCES)):
        time.sleep(1)
        dump("08_flutter_sources")
        shot("08_flutter_sources")
        nodes = parse(dump("tmp"))
        m = find(nodes, "\u66f4\u591a\u9009\u9879") or find(nodes, L_SHOW_MENU) or find(nodes, L_MORE)
        if tap(m):
            xml = dump("40_source_overflow")
            shot("40_source_overflow")
            nodes = parse(xml)
            print("source overflow:", labels(nodes))
            notes.append(f"source_overflow: {labels(nodes)}")
            n = find(nodes, L_NEW)
            if tap(n):
                time.sleep(0.5)
                xml = dump("41_source_new_menu")
                shot("41_source_new_menu")
                nodes = parse(xml)
                print("new menu:", labels(nodes))
                js = find(nodes, L_JS)
                if tap(js):
                    time.sleep(0.8)
                    dump("42_js_source_stub")
                    shot("42_js_source_stub")
                    notes.append(f"js_stub: {labels(parse(dump('42_js_source_stub')))[:100]}")
        back()
        # reopen sources for group
        nodes = go_mine()
        tap(find(nodes, L_SOURCES))
        time.sleep(0.8)
        g = find(parse(dump("tmp")), L_GROUP)
        if tap(g):
            time.sleep(0.6)
            xml = dump("43_source_group")
            shot("43_source_group")
            nodes = parse(xml)
            print("group popup:", labels(nodes))
            notes.append(f"source_group: {labels(nodes)}")
            gm = find(nodes, L_GROUP_MANAGE) or find(nodes, "\u7ba1\u7406")
            if tap(gm):
                time.sleep(0.8)
                dump("44_source_group_manage_stub")
                shot("44_source_group_manage_stub")
                notes.append(
                    f"group_manage_stub: {labels(parse(dump('44_source_group_manage_stub')))[:100]}"
                )

    # --- Mine scroll items ---
    nodes = go_mine()
    for i in range(5):
        dump(f"50_mine_scroll_{i}")
        shot(f"50_mine_scroll_{i}")
        nodes = parse(dump(f"50_mine_scroll_{i}"))
        print(f"mine{i}:", labels(nodes))
        for key, fname in [
            (L_BACKUP, "13_flutter_backup"),
            ("WebDAV", "13b_webdav"),
            (L_MCP, "17_flutter_mcp"),
            (L_AUTOTASK, "14_flutter_autotask"),
            (L_BOOKMARK, "51_bookmarks"),
            (L_ABOUT, "52_about"),
            (L_FILES, "53_files"),
            (L_DICT, "15_flutter_dict"),
            (L_TXT, "16_flutter_txttoc"),
            (L_THEME, "11_flutter_theme"),
            (L_OTHER, "12_flutter_other"),
            (L_REPLACE, "09_flutter_replace"),
        ]:
            if (OUT / f"{fname}.png").exists() and fname not in (
                "13_flutter_backup",
                "17_flutter_mcp",
                "14_flutter_autotask",
            ):
                # still allow re-capture for key stubs
                if fname not in ("13_flutter_backup", "17_flutter_mcp", "14_flutter_autotask", "51_bookmarks", "52_about", "53_files", "15_flutter_dict", "16_flutter_txttoc"):
                    continue
            n = find(nodes, key)
            if not n:
                continue
            if tap(n):
                time.sleep(1.0)
                dump(fname)
                shot(fname)
                print(fname, labels(parse((OUT / f"{fname}.xml").read_text(encoding="utf-8"))))
                notes.append(f"opened {key} -> {fname}")
                # MCP: capture snackbar-ish screen
                back()
                time.sleep(0.5)
                # re-sync mine
                if not find(parse(dump("tmp")), L_SOURCES):
                    nodes = go_mine()
                else:
                    nodes = parse(dump("tmp"))
        adb("shell", "input", "swipe", "360", "1000", "360", "450", "350")
        time.sleep(0.7)

    # --- Reader path ---
    start_flutter()
    cover = find(parse(dump("tmp")), L_COVER)
    if tap(cover):
        time.sleep(2.5)
        dump("20_flutter_reader_or_info")
        shot("20_flutter_reader_or_info")
        nodes = parse(dump("20_flutter_reader_or_info"))
        print("book tap:", labels(nodes))
        btn = find(nodes, L_CONTINUE) or find(nodes, L_START)
        if tap(btn):
            time.sleep(2.5)
        dump("21_flutter_reader")
        shot("21_flutter_reader")
        print("reader:", labels(parse(dump("21_flutter_reader"))))
        adb("shell", "input", "tap", "360", "640")
        time.sleep(1)
        dump("22_flutter_reader_menu")
        shot("22_flutter_reader_menu")
        nodes = parse(dump("22_flutter_reader_menu"))
        print("reader menu:", labels(nodes))
        notes.append(f"reader_menu: {labels(nodes)[:140]}")
        if tap(find(nodes, L_TOC)):
            time.sleep(1)
            dump("23_flutter_toc")
            shot("23_flutter_toc")
            print("toc:", labels(parse(dump("23_flutter_toc"))))
            notes.append(f"toc: {labels(parse(dump('23_flutter_toc')))[:100]}")
            back()
        back()

    # --- Original compare ---
    adb("shell", "am", "force-stop", ORIG)
    time.sleep(0.4)
    adb("shell", "am", "start", "-n", f"{ORIG}/io.legado.app.ui.main.MainActivity")
    time.sleep(3)
    for i, name in enumerate(["bookshelf", "discover", "rss", "mine"]):
        x = 90 + i * 180
        adb("shell", "input", "tap", str(x), "1220")
        time.sleep(1.3)
        shot(f"3{i}_orig_{name}")
        dump(f"3{i}_orig_{name}")
        xml = (OUT / f"3{i}_orig_{name}.xml").read_text(encoding="utf-8")
        texts = [t for t in re.findall(r'text="([^"]+)"', xml) if t]
        print(f"orig {name}:", " | ".join(texts[:25]))
        notes.append(f"orig_{name}: {' | '.join(texts[:18])}")

    adb("shell", "am", "start", "-n", f"{ORIG}/io.legado.app.ui.about.ReadRecordActivity")
    time.sleep(2)
    shot("35_orig_read_record")
    dump("35_orig_read_record")
    texts = [t for t in re.findall(r'text="([^"]+)"', (OUT / "35_orig_read_record.xml").read_text(encoding="utf-8")) if t]
    print("orig readrec:", " | ".join(texts[:25]))
    notes.append(f"orig_read_record: {' | '.join(texts[:18])}")

    adb(
        "shell",
        "am",
        "start",
        "-n",
        f"{ORIG}/io.legado.app.ui.book.import.remote.RemoteBookActivity",
    )
    time.sleep(2)
    shot("36_orig_remote")
    dump("36_orig_remote")
    texts = [t for t in re.findall(r'text="([^"]+)"', (OUT / "36_orig_remote.xml").read_text(encoding="utf-8")) if t]
    print("orig remote:", " | ".join(texts[:25]))
    notes.append(f"orig_remote: {' | '.join(texts[:18])}")

    # Flutter remote
    start_flutter()
    if tap(find(parse(dump("tmp")), L_SHOW_MENU)):
        nodes = parse(dump("tmp"))
        if tap(find(nodes, L_REMOTE)):
            time.sleep(1)
            dump("25_flutter_remote")
            shot("25_flutter_remote")
            print("flutter remote:", labels(parse(dump("25_flutter_remote"))))
            notes.append(f"flutter_remote: {labels(parse(dump('25_flutter_remote')))[:120]}")

    (OUT / "walkthrough_notes2.txt").write_text("\n".join(notes), encoding="utf-8")
    print("DONE", len(notes))


if __name__ == "__main__":
    main()
