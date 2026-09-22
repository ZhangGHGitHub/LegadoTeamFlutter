# -*- coding: utf-8 -*-
"""A4B 实机验证 UI 辅助（Test 192.168.1.19:5555 专用）
用法:
  python a4b2_ui.py dump [out.xml]           # uiautomator dump 到本地
  python a4b2_ui.py find <text>              # 在最新 dump 中找 text/content-desc 匹配节点，打印中心坐标
  python a4b2_ui.py tap <text>               # dump + 找节点 + 点按
  python a4b2_ui.py tapxy X Y                # 坐标点按
  python a4b2_ui.py shot <name>              # 截图 <name>.png（exec-out）
  python a4b2_ui.py swipe X1 Y1 X2 Y2 [ms]  # 滑动
  python a4b2_ui.py key <BACK|HOME>          # 按键
  python a4b2_ui.py logcat <name>            # 抓 logcat -d 全文到 <name>.log
设备: 192.168.1.19:5555；包 io.legado.flutter_legado
"""
import re
import subprocess
import sys
import os

ADB = r"D:\Android\platform-tools\adb.exe"
DEV = "192.168.1.19:5555"
OUTDIR = os.path.dirname(os.path.abspath(__file__))
LAST_DUMP = os.path.join(OUTDIR, "_last_dump.xml")


def run(*args, binary=False):
    r = subprocess.run([ADB, "-s", DEV, *args], capture_output=True,
                       timeout=120)
    if binary:
        return r.stdout
    return r.stdout.decode("utf-8", "replace")


def dump():
    out = os.path.join(OUTDIR, "_device_dump.xml")
    run("shell", "uiautomator", "dump", "/sdcard/_a4b2_dump.xml")
    data = run("exec-out", "cat", "/sdcard/_a4b2_dump.xml", binary=True)
    text = data.decode("utf-8", "replace")
    if "<node" not in text:
        raise SystemExit(f"dump 失败: {text[:200]}")
    with open(LAST_DUMP, "w", encoding="utf-8") as f:
        f.write(text)
    return text


def parse_nodes(xml):
    """返回 (text, content_desc, bounds_center, full_attrs) 列表"""
    nodes = []
    for m in re.finditer(r"<node\b[^>]*?/>", xml):
        s = m.group(0)
        text = re.search(r'text="([^"]*)"', s)
        desc = re.search(r'content-desc="([^"]*)"', s)
        b = re.search(r'bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"', s)
        checked = re.search(r'checked="(\w+)"', s)
        cls = re.search(r'class="([^"]*)"', s)
        nodes.append({
            "text": text.group(1) if text else "",
            "desc": desc.group(1) if desc else "",
            "center": (
                (int(b.group(1)) + int(b.group(3))) // 2,
                (int(b.group(2)) + int(b.group(4))) // 2,
            ) if b else None,
            "checked": checked.group(1) if checked else None,
            "class": cls.group(1) if cls else "",
            "raw": s[:300],
        })
    return nodes


def find(text):
    """返回 (节点列表, xml)。优先精确匹配 text/desc，否则子串匹配
    （tab 的 content-desc 形如 '发现\\nTab 3 of 5'，含换行，只能子串命中）。"""
    xml = dump()
    nodes = parse_nodes(xml)
    exact = [n for n in nodes if n["text"] == text or n["desc"] == text]
    if exact:
        return exact, xml
    sub = [n for n in nodes if text in n["text"] or text in n["desc"]]
    return sub, xml


def main():
    cmd = sys.argv[1]
    if cmd == "dump":
        dump()
        print(f"dump 已保存 {LAST_DUMP}")
    elif cmd == "find":
        want = sys.argv[2]
        hits, _ = find(want)
        if not hits:
            # 模糊兜底
            xml = open(LAST_DUMP, encoding="utf-8").read()
            hits = [n for n in parse_nodes(xml) if want in n["text"] or want in n["desc"]]
        for h in hits[:8]:
            print(f'{h["text"] or h["desc"]} @ {h["center"]} checked={h["checked"]} cls={h["class"]}')
        if not hits:
            print(f"[!] 未找到: {want}")
    elif cmd == "tap":
        want = sys.argv[2]
        hits, _ = find(want)
        hits = [h for h in hits if h["center"]]
        if not hits:
            sys.exit(f"[!] 未找到可点节点: {want}")
        x, y = hits[0]["center"]
        run("shell", "input", "tap", str(x), str(y))
        print(f"tap {want} @ ({x},{y})")
    elif cmd == "tapxy":
        x, y = sys.argv[2], sys.argv[3]
        run("shell", "input", "tap", x, y)
        print(f"tapxy ({x},{y})")
    elif cmd == "longpress":
        x, y = sys.argv[2], sys.argv[3]
        # uiautomator 长按：input swipe x y x y 800
        run("shell", "input", "swipe", x, y, x, y, "800")
        print(f"longpress ({x},{y})")
    elif cmd == "swipe":
        x1, y1, x2, y2 = (int(v) for v in sys.argv[2:6])
        ms = sys.argv[6] if len(sys.argv) > 6 else "300"
        run("shell", "input", "swipe", str(x1), str(y1), str(x2), str(y2), ms)
        print(f"swipe ({x1},{y1})->({x2},{y2}) {ms}ms")
    elif cmd == "key":
        run("shell", "input", "keyevent", sys.argv[2])
        print(f"key {sys.argv[2]}")
    elif cmd == "shot":
        data = run("exec-out", "screencap", "-p", binary=True)
        p = os.path.join(OUTDIR, f"{sys.argv[2]}.png")
        with open(p, "wb") as f:
            f.write(data)
        print(f"shot -> {p} ({len(data)//1024}KB)")
    elif cmd == "logcat":
        data = run("shell", "logcat", "-d")
        p = os.path.join(OUTDIR, f"{sys.argv[2]}.log")
        with open(p, "w", encoding="utf-8") as f:
            f.write(data)
        print(f"logcat -> {p} ({len(data)//1024}KB)")
    else:
        raise SystemExit("unknown cmd")


if __name__ == "__main__":
    main()
