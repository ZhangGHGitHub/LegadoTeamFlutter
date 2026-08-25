# -*- coding: utf-8 -*-
"""UI dump helpers + walkthrough driver for gap audit."""
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
ORIG_PKG = "com.legado.app.release"
ORIG_ACT = "io.legado.app.ui.welcome.WelcomeActivity"


def adb(*args, check=False):
    r = subprocess.run([ADB, "-s", DEV, *args], capture_output=True)
    out = (r.stdout or b"") + (r.stderr or b"")
    try:
        text = out.decode("utf-8")
    except Exception:
        text = out.decode("gbk", errors="replace")
    if check and r.returncode != 0:
        raise RuntimeError(f"adb {args} failed: {text}")
    return text


def dump(name: str):
    adb("shell", "uiautomator", "dump", "/sdcard/ui_dump.xml")
    local = OUT / f"{name}.xml"
    adb("pull", "/sdcard/ui_dump.xml", str(local))
    return local.read_text(encoding="utf-8")


def shot(name: str):
    adb("shell", "screencap", "-p", f"/sdcard/{name}.png")
    adb("pull", f"/sdcard/{name}.png", str(OUT / f"{name}.png"))


def parse_nodes(xml: str):
    # Flutter Semantics: content-desc carries labels
    pat = re.compile(
        r'content-desc="([^"]*)"[^>]*bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"'
        r'|bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"[^>]*content-desc="([^"]*)"'
    )
    nodes = []
    for m in pat.finditer(xml):
        if m.group(1) is not None:
            desc, x1, y1, x2, y2 = m.group(1), *map(int, m.groups()[1:5])
        else:
            x1, y1, x2, y2 = map(int, m.groups()[5:9])
            desc = m.group(10)
        if not desc:
            continue
        nodes.append(
            {
                "desc": desc.replace("&#10;", "\n"),
                "cx": (x1 + x2) // 2,
                "cy": (y1 + y2) // 2,
                "bounds": (x1, y1, x2, y2),
            }
        )
    return nodes


def find(nodes, substr: str):
    for n in nodes:
        if substr in n["desc"]:
            return n
    return None


def tap_node(n):
    adb("shell", "input", "tap", str(n["cx"]), str(n["cy"]))
    time.sleep(1.0)


def long_press(n, ms=1000):
    x, y = n["cx"], n["cy"]
    adb(
        "shell",
        "input",
        "swipe",
        str(x),
        str(y),
        str(x),
        str(y),
        str(ms),
    )
    time.sleep(1.2)


def tap_xy(x, y):
    adb("shell", "input", "tap", str(x), str(y))
    time.sleep(1.0)


def back():
    adb("shell", "input", "keyevent", "4")
    time.sleep(0.8)


def start_flutter():
    adb("shell", "am", "start", "-n", f"{PKG}/{ACT}")
    time.sleep(2.5)


def start_original():
    # try MainActivity directly
    adb("shell", "am", "start", "-n", f"{ORIG_PKG}/io.legado.app.ui.main.MainActivity")
    time.sleep(2.5)


def summarize(name, xml):
    nodes = parse_nodes(xml)
    labels = []
    for n in nodes:
        d = n["desc"].split("\n")[0][:40]
        if d not in labels:
            labels.append(d)
    print(f"\n=== {name} ===")
    print(" | ".join(labels[:50]))
    return nodes


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    notes = []

    # ---- Flutter core walkthrough ----
    start_flutter()
    xml = dump("02_flutter_bookshelf")
    shot("02_flutter_bookshelf")
    nodes = summarize("02_flutter_bookshelf", xml)
    notes.append(("书架", "有书「重生高考前99天」；底栏书架/发现/订阅/我的", "ok"))

    # Long-press book title (behavior deviation check)
    title = find(nodes, "重生高考前99天")
    if title and title["bounds"][1] > 500:  # title under cover
        long_press(title)
        xml = dump("03_flutter_longpress_title")
        shot("03_flutter_longpress_title")
        n2 = summarize("03_flutter_longpress_title", xml)
        sheet = any(
            k in " ".join(x["desc"] for x in n2)
            for k in ["查看详情", "置顶", "编辑", "分组", "导出", "分享", "删除"]
        )
        notes.append(
            (
                "书架标题长按",
                "底部菜单" if sheet else "未见底部菜单",
                "行为偏离" if sheet else "check",
            )
        )
        back()
        time.sleep(0.5)

    # Long-press cover
    start_flutter()
    xml = dump("tmp")
    nodes = parse_nodes(xml)
    cover = find(nodes, "99+")
    if cover:
        long_press(cover)
        xml = dump("04_flutter_longpress_cover")
        shot("04_flutter_longpress_cover")
        n2 = summarize("04_flutter_longpress_cover", xml)
        is_info = any("书籍信息" in x["desc"] or "开始阅读" in x["desc"] or "换源" in x["desc"] for x in n2)
        sheet = any(k in " ".join(x["desc"] for x in n2) for k in ["查看详情", "置顶", "编辑信息"])
        notes.append(
            (
                "书架封面长按",
                "书籍详情" if is_info else ("底部菜单" if sheet else "未知"),
                "ok" if is_info else "行为偏离?",
            )
        )
        back()

    # Discover tab
    start_flutter()
    xml = dump("tmp")
    nodes = parse_nodes(xml)
    tab = find(nodes, "发现")
    if tab:
        tap_node(tab)
        xml = dump("05_flutter_discover")
        shot("05_flutter_discover")
        summarize("05_flutter_discover", xml)
        notes.append(("发现", "Tab 可进", "ok"))

    # RSS tab
    tab = find(parse_nodes(dump("tmp")), "订阅")
    if tab:
        tap_node(tab)
        xml = dump("06_flutter_rss")
        shot("06_flutter_rss")
        summarize("06_flutter_rss", xml)
        notes.append(("订阅", "Tab 可进", "ok"))

    # Mine tab
    tab = find(parse_nodes(dump("tmp")), "我的")
    if tab:
        tap_node(tab)
        xml = dump("07_flutter_mine")
        shot("07_flutter_mine")
        nodes = summarize("07_flutter_mine", xml)
        notes.append(("我的", "Tab 可进", "ok"))

        # Enter 书源管理
        src = find(nodes, "书源管理")
        if src:
            tap_node(src)
            xml = dump("08_flutter_sources")
            shot("08_flutter_sources")
            summarize("08_flutter_sources", xml)
            notes.append(("书源管理", "可进", "ok"))
            back()

        # refresh mine
        xml = dump("tmp")
        nodes = parse_nodes(xml)
        for label, fname in [
            ("替换净化", "09_flutter_replace"),
            ("阅读记录", "10_flutter_read_record"),
            ("主题设置", "11_flutter_theme"),
            ("其他设置", "12_flutter_other"),
            ("备份与恢复", "13_flutter_backup"),
            ("定时任务", "14_flutter_autotask"),
            ("词典", "15_flutter_dict"),
            ("TXT目录规则", "16_flutter_txttoc"),
        ]:
            # may need scroll - try find
            n = find(nodes, label)
            if not n:
                # swipe up on mine list
                adb("shell", "input", "swipe", "360", "900", "360", "400", "300")
                time.sleep(0.6)
                nodes = parse_nodes(dump("tmp"))
                n = find(nodes, label)
            if n:
                tap_node(n)
                xml = dump(fname)
                shot(fname)
                summarize(fname, xml)
                notes.append((label, "可进", "ok"))
                back()
                time.sleep(0.5)
                nodes = parse_nodes(dump("tmp"))
            else:
                notes.append((label, "入口未找到(可能需滚动)", "miss"))

        # MCP stub check
        nodes = parse_nodes(dump("tmp"))
        mcp = find(nodes, "MCP")
        if mcp:
            tap_node(mcp)
            time.sleep(0.8)
            xml = dump("17_flutter_mcp_tap")
            shot("17_flutter_mcp_tap")
            summarize("17_flutter_mcp_tap", xml)
            notes.append(("MCP服务", "点击后截图", "桩?"))

    # Search from bookshelf
    start_flutter()
    nodes = parse_nodes(dump("tmp"))
    search = find(nodes, "搜索")
    if search:
        tap_node(search)
        xml = dump("18_flutter_search")
        shot("18_flutter_search")
        summarize("18_flutter_search", xml)
        notes.append(("搜索", "可进", "ok"))
        # open menu for 显示搜索记录 stub
        menu = find(parse_nodes(dump("tmp")), "Show menu") or find(
            parse_nodes(dump("tmp")), "更多"
        )
        if menu:
            tap_node(menu)
            xml = dump("19_flutter_search_menu")
            shot("19_flutter_search_menu")
            summarize("19_flutter_search_menu", xml)
        back()

    # Open book -> reader
    start_flutter()
    nodes = parse_nodes(dump("tmp"))
    book = find(nodes, "99+") or find(nodes, "重生高考前99天")
    if book:
        tap_node(book)
        time.sleep(2.0)
        xml = dump("20_flutter_reader_or_info")
        shot("20_flutter_reader_or_info")
        nodes = summarize("20_flutter_reader_or_info", xml)
        # if book info, tap 开始阅读 / 继续阅读
        read_btn = find(nodes, "开始阅读") or find(nodes, "继续阅读") or find(nodes, "阅读")
        if read_btn:
            tap_node(read_btn)
            time.sleep(2.5)
            xml = dump("21_flutter_reader")
            shot("21_flutter_reader")
            summarize("21_flutter_reader", xml)
            notes.append(("阅读器", "已打开", "ok"))
            # tap center to show menu
            tap_xy(360, 640)
            time.sleep(0.8)
            xml = dump("22_flutter_reader_menu")
            shot("22_flutter_reader_menu")
            summarize("22_flutter_reader_menu", xml)
            # TOC if available
            nodes = parse_nodes(xml)
            toc = find(nodes, "目录")
            if toc:
                tap_node(toc)
                time.sleep(1.0)
                xml = dump("23_flutter_toc")
                shot("23_flutter_toc")
                summarize("23_flutter_toc", xml)
                notes.append(("目录", "可进", "ok"))
                back()
            back()
        else:
            notes.append(("阅读器", "点击书籍后未到阅读/详情", "check"))
            back()

    # Bookshelf menu: 远程书籍 / 本地
    start_flutter()
    nodes = parse_nodes(dump("tmp"))
    menu = find(nodes, "Show menu")
    if menu:
        tap_node(menu)
        xml = dump("24_flutter_bookshelf_menu")
        shot("24_flutter_bookshelf_menu")
        nodes = summarize("24_flutter_bookshelf_menu", xml)
        for label, fname in [
            ("添加远程", "25_flutter_remote"),
            ("远程", "25_flutter_remote"),
            ("添加本地", "26_flutter_local"),
            ("本地", "26_flutter_local"),
            ("书架管理", "27_flutter_manage"),
        ]:
            n = find(nodes, label)
            if n:
                tap_node(n)
                time.sleep(1.0)
                xml = dump(fname)
                shot(fname)
                summarize(fname, xml)
                notes.append((label, "菜单可进", "ok"))
                back()
                # reopen menu
                start_flutter()
                tap_node(find(parse_nodes(dump("tmp")), "Show menu"))
                nodes = parse_nodes(dump("tmp"))
                break

    # ---- Original home for structure compare ----
    start_original()
    xml = dump("30_orig_home")
    shot("30_orig_home")
    summarize("30_orig_home", xml)
    notes.append(("原版主界面", "截图对照", "ok"))

    # Original mine
    # try tap 我的 - may use different semantics
    nodes = parse_nodes(xml)
    mine = find(nodes, "我的")
    if mine:
        tap_node(mine)
        xml = dump("31_orig_mine")
        shot("31_orig_mine")
        summarize("31_orig_mine", xml)

    print("\n\n===== NOTES =====")
    for a, b, c in notes:
        print(f"- [{c}] {a}: {b}")

    (OUT / "walkthrough_notes.txt").write_text(
        "\n".join(f"[{c}] {a}: {b}" for a, b, c in notes), encoding="utf-8"
    )


if __name__ == "__main__":
    main()
