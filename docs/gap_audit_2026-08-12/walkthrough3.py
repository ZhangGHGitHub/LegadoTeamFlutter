# -*- coding: utf-8 -*-
import re
import subprocess
import time
from pathlib import Path
import sys

sys.stdout.reconfigure(encoding="utf-8")

ADB = r"D:\Android\platform-tools\adb.exe"
DEV = "emulator-5556"
OUT = Path(r"D:\OH-WorkSpace\LegadoTeam\legado\docs\gap_audit_2026-08-12")
PKG = "io.legado.flutter_legado"
ACT = "io.legado.flutter.MainActivity"
ORIG = "com.legado.app.release"


def adb(*a):
    subprocess.run([ADB, "-s", DEV, *a], capture_output=True)


def dump(name):
    adb("shell", "uiautomator", "dump", "/sdcard/ui_dump.xml")
    p = OUT / f"{name}.xml"
    adb("pull", "/sdcard/ui_dump.xml", str(p))
    return p.read_text(encoding="utf-8")


def shot(name):
    adb("shell", "screencap", "-p", f"/sdcard/{name}.png")
    adb("pull", f"/sdcard/{name}.png", str(OUT / f"{name}.png"))


def parse(xml):
    nodes = []
    for m in re.finditer(
        r'content-desc="([^"]*)"[^>]*bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"', xml
    ):
        desc = m.group(1).replace("&#10;", "\n")
        if not desc:
            continue
        x1, y1, x2, y2 = map(int, m.groups()[1:])
        nodes.append(
            {"desc": desc, "cx": (x1 + x2) // 2, "cy": (y1 + y2) // 2, "bounds": (x1, y1, x2, y2)}
        )
    return nodes


def labels(nodes):
    out = []
    for n in nodes:
        d = n["desc"].split("\n")[0][:40]
        if d not in out:
            out.append(d)
    return " | ".join(out[:40])


def find(nodes, s):
    for n in nodes:
        if s in n["desc"]:
            return n
    return None


def tap(n):
    if not n:
        return False
    adb("shell", "input", "tap", str(n["cx"]), str(n["cy"]))
    time.sleep(1.0)
    return True


def longpress(n):
    if not n:
        return False
    x, y = n["cx"], n["cy"]
    adb("shell", "input", "swipe", str(x), str(y), str(x), str(y), "1200")
    time.sleep(1.2)
    return True


def back():
    adb("shell", "input", "keyevent", "4")
    time.sleep(0.8)


notes = []

# Reset flutter
adb("shell", "am", "force-stop", PKG)
time.sleep(0.8)
adb("shell", "am", "start", "-n", f"{PKG}/{ACT}")
time.sleep(3)
# bookshelf tab
adb("shell", "input", "tap", "90", "1220")
time.sleep(1.5)
dump("02b_flutter_bookshelf")
shot("02b_flutter_bookshelf")
nodes = parse((OUT / "02b_flutter_bookshelf.xml").read_text(encoding="utf-8"))
print("bookshelf:", labels(nodes))
notes.append(labels(nodes))

# title longpress
title = None
for n in nodes:
    if n["desc"] == "重生高考前99天":
        title = n
        break
if not title:
    for n in nodes:
        if "重生高考前99天" in n["desc"] and "\n" not in n["desc"] and n["bounds"][1] > 500:
            title = n
            break
print("title", title)
if title:
    longpress(title)
    dump("03_flutter_longpress_title")
    shot("03_flutter_longpress_title")
    print("title LP:", labels(parse(dump("03_flutter_longpress_title"))))
    notes.append("titleLP:" + labels(parse((OUT / "03_flutter_longpress_title.xml").read_text(encoding="utf-8"))))
    back()

# menu + remote
adb("shell", "am", "start", "-n", f"{PKG}/{ACT}")
time.sleep(1.5)
adb("shell", "input", "tap", "90", "1220")
time.sleep(0.8)
nodes = parse(dump("tmp"))
if tap(find(nodes, "Show menu")):
    dump("24_flutter_bookshelf_menu")
    shot("24_flutter_bookshelf_menu")
    nodes = parse((OUT / "24_flutter_bookshelf_menu.xml").read_text(encoding="utf-8"))
    print("menu:", labels(nodes))
    notes.append("menu:" + labels(nodes))
    if tap(find(nodes, "远程")):
        time.sleep(1)
        dump("25_flutter_remote")
        shot("25_flutter_remote")
        print("remote:", labels(parse(dump("25_flutter_remote"))))
        notes.append("remote:" + labels(parse((OUT / "25_flutter_remote.xml").read_text(encoding="utf-8"))))
        back()

# search record stub
adb("shell", "am", "start", "-n", f"{PKG}/{ACT}")
time.sleep(1.5)
adb("shell", "input", "tap", "90", "1220")
time.sleep(0.5)
nodes = parse(dump("tmp"))
if tap(find(nodes, "搜索")):
    time.sleep(1)
    dump("18_flutter_search")
    shot("18_flutter_search")
    nodes = parse(dump("tmp"))
    m = find(nodes, "Show menu") or find(nodes, "更多")
    if tap(m):
        dump("19_flutter_search_menu")
        shot("19_flutter_search_menu")
        nodes = parse((OUT / "19_flutter_search_menu.xml").read_text(encoding="utf-8"))
        print("search menu:", labels(nodes))
        notes.append("searchMenu:" + labels(nodes))
        n = find(nodes, "搜索记录") or find(nodes, "记录")
        if tap(n):
            time.sleep(0.8)
            dump("19b_search_record_stub")
            shot("19b_search_record_stub")
            print("record stub:", labels(parse(dump("19b_search_record_stub"))))
    back()

# mine top: sources + MCP + backup + autotask
adb("shell", "am", "start", "-n", f"{PKG}/{ACT}")
time.sleep(1.5)
adb("shell", "input", "tap", "630", "1220")  # 我的
time.sleep(1)
# scroll to top
for _ in range(3):
    adb("shell", "input", "swipe", "360", "400", "360", "1100", "300")
    time.sleep(0.4)
dump("07b_flutter_mine_top")
shot("07b_flutter_mine_top")
nodes = parse((OUT / "07b_flutter_mine_top.xml").read_text(encoding="utf-8"))
print("mine top:", labels(nodes))
notes.append("mineTop:" + labels(nodes))

if tap(find(nodes, "书源管理")):
    time.sleep(1)
    dump("08_flutter_sources")
    shot("08_flutter_sources")
    nodes = parse(dump("tmp"))
    m = find(nodes, "更多选项") or find(nodes, "Show menu") or find(nodes, "更多")
    if tap(m):
        dump("40_source_overflow")
        shot("40_source_overflow")
        print("src overflow:", labels(parse((OUT / "40_source_overflow.xml").read_text(encoding="utf-8"))))
        notes.append("srcOverflow:" + labels(parse((OUT / "40_source_overflow.xml").read_text(encoding="utf-8"))))
    back()

# reopen mine top
adb("shell", "am", "start", "-n", f"{PKG}/{ACT}")
time.sleep(1)
adb("shell", "input", "tap", "630", "1220")
time.sleep(0.8)
for _ in range(3):
    adb("shell", "input", "swipe", "360", "400", "360", "1100", "300")
    time.sleep(0.3)
nodes = parse(dump("tmp"))
for key, fname in [
    ("定时任务", "14_flutter_autotask"),
    ("TXT", "16_flutter_txttoc"),
    ("词典", "15_flutter_dict"),
    ("备份", "13_flutter_backup"),
    ("MCP", "17_flutter_mcp"),
]:
    n = find(nodes, key)
    if not n:
        # swipe down a bit
        adb("shell", "input", "swipe", "360", "900", "360", "500", "300")
        time.sleep(0.5)
        nodes = parse(dump("tmp"))
        n = find(nodes, key)
    if tap(n):
        time.sleep(1)
        dump(fname)
        shot(fname)
        print(fname, labels(parse((OUT / f"{fname}.xml").read_text(encoding="utf-8"))))
        notes.append(fname + ":" + labels(parse((OUT / f"{fname}.xml").read_text(encoding="utf-8")))[:90])
        back()
        time.sleep(0.5)
        nodes = parse(dump("tmp"))

# Reader
adb("shell", "am", "start", "-n", f"{PKG}/{ACT}")
time.sleep(1.5)
adb("shell", "input", "tap", "90", "1220")
time.sleep(0.8)
nodes = parse(dump("tmp"))
if tap(find(nodes, "99+")):
    time.sleep(2.5)
    dump("20_flutter_reader_or_info")
    shot("20_flutter_reader_or_info")
    nodes = parse((OUT / "20_flutter_reader_or_info.xml").read_text(encoding="utf-8"))
    print("after tap book:", labels(nodes))
    btn = find(nodes, "继续阅读") or find(nodes, "开始阅读")
    if tap(btn):
        time.sleep(2.5)
    dump("21_flutter_reader")
    shot("21_flutter_reader")
    print("reader:", labels(parse(dump("21_flutter_reader"))))
    adb("shell", "input", "tap", "360", "640")
    time.sleep(1)
    dump("22_flutter_reader_menu")
    shot("22_flutter_reader_menu")
    nodes = parse((OUT / "22_flutter_reader_menu.xml").read_text(encoding="utf-8"))
    print("rmenu:", labels(nodes))
    notes.append("readerMenu:" + labels(nodes))
    if tap(find(nodes, "目录")):
        time.sleep(1)
        dump("23_flutter_toc")
        shot("23_flutter_toc")
        print("toc:", labels(parse(dump("23_flutter_toc"))))
        back()
    back()

# Original Remote + ReadRecord with correct component
adb("shell", "am", "force-stop", ORIG)
time.sleep(0.5)
adb("shell", "am", "start", "-n", f"{ORIG}/io.legado.app.ui.main.MainActivity")
time.sleep(2.5)
# ensure mine not covering - tap bookshelf
adb("shell", "input", "tap", "90", "1220")
time.sleep(1)
shot("30_orig_bookshelf")
dump("30_orig_bookshelf")
texts = [t for t in re.findall(r'text="([^"]+)"', (OUT / "30_orig_bookshelf.xml").read_text(encoding="utf-8")) if t]
print("orig bs:", " | ".join(texts[:20]))

# start activities explicitly and wait
for act, name in [
    ("io.legado.app.ui.about.ReadRecordActivity", "35_orig_read_record"),
    ("io.legado.app.ui.book.import.remote.RemoteBookActivity", "36_orig_remote"),
    ("io.legado.app.ui.book.source.manage.BookSourceActivity", "37_orig_sources"),
]:
    adb("shell", "am", "start", "-n", f"{ORIG}/{act}")
    time.sleep(2.5)
    shot(name)
    dump(name)
    xml = (OUT / f"{name}.xml").read_text(encoding="utf-8")
    texts = [t for t in re.findall(r'text="([^"]+)"', xml) if t]
    descs = [t for t in re.findall(r'content-desc="([^"]+)"', xml) if t]
    print(name, "texts:", " | ".join(texts[:20]), "descs:", " | ".join(descs[:10]))
    notes.append(name + ":" + " | ".join(texts[:15]))

(OUT / "walkthrough_notes3.txt").write_text("\n".join(notes), encoding="utf-8")
print("DONE")
