"""设备 UI 辅助：dump / find / tap / screenshot（Flutter 语义文本多在 content-desc）。

用法：
  python ui.py dump [label]              # 拉取 UI 树并打印可交互节点
  python ui.py tap "文本"                 # 按文本/content-desc 精确或包含匹配后点击
  python ui.py tapx X Y                   # 直接坐标点击
  python ui.py find "文本"                # 只查找不点击
  python ui.py shot name                  # 截图到 evidence 目录

所有 dump 落在 evidence/screens 下，便于事后核对。
"""
import os
import re
import subprocess
import sys
import time
import xml.etree.ElementTree as ET

ADB = r"D:\Program Files\MuMuPlayer\nx_main\adb.exe"
SERIAL = "192.168.100.62:5555"
HERE = os.path.dirname(os.path.abspath(__file__))
SHOTS = os.path.join(HERE, "screens")
os.makedirs(SHOTS, exist_ok=True)


def adb(*args, binary=False):
    cmd = [ADB, "-s", SERIAL] + list(args)
    r = subprocess.run(cmd, capture_output=True)
    return r.stdout if binary else r.stdout.decode("utf-8", "replace")


def dump_raw():
    adb("shell", "uiautomator dump /data/local/tmp/ui.xml")
    time.sleep(0.4)
    out = adb("shell", "cat /data/local/tmp/ui.xml")
    return out


def parse(xml_text):
    try:
        root = ET.fromstring(xml_text)
    except Exception as e:
        print("PARSE_ERR", e)
        return []
    nodes = []
    for n in root.iter("node"):
        b = n.get("bounds", "")
        m = re.match(r"\[(\d+),(\d+)\]\[(\d+),(\d+)\]", b)
        if not m:
            continue
        x1, y1, x2, y2 = map(int, m.groups())
        nodes.append({
            "text": n.get("text", ""),
            "desc": n.get("content-desc", ""),
            "cls": n.get("class", ""),
            "clickable": n.get("clickable") == "true",
            "scrollable": n.get("scrollable") == "true",
            "bounds": (x1, y1, x2, y2),
            "cx": (x1 + x2) // 2,
            "cy": (y1 + y2) // 2,
        })
    return nodes


def label(n):
    t = n["text"].strip()
    d = n["desc"].strip()
    if t and d:
        return "%s | %s" % (t, d)
    return t or d


def cmd_dump(args):
    tag = args[0] if args else "ui"
    xml_text = dump_raw()
    path = os.path.join(SHOTS, "ui_%s.xml" % tag)
    with open(path, "w", encoding="utf-8") as f:
        f.write(xml_text)
    nodes = parse(xml_text)
    print("# dump -> %s (%d nodes)" % (path, len(nodes)))
    for n in nodes:
        l = label(n)
        if l or n["clickable"] or n["scrollable"]:
            flags = "".join([
                "C" if n["clickable"] else "-",
                "S" if n["scrollable"] else "-",
            ])
            print("%s %-18s %s" % (flags, n["cls"].split(".")[-1], l))


def match(nodes, needle):
    exact = [n for n in nodes if label(n) == needle]
    if exact:
        return exact
    contains = [n for n in nodes if needle in label(n)]
    return contains


def cmd_find(args):
    needle = args[0]
    nodes = parse(dump_raw())
    hits = match(nodes, needle)
    if not hits:
        print("NOT_FOUND %r" % needle)
        return 2
    for n in hits:
        print("FOUND %-60r clickable=%s bounds=%s center=(%d,%d)" % (
            label(n), n["clickable"], n["bounds"], n["cx"], n["cy"]))
    return 0


def cmd_tap(args):
    needle = args[0]
    nodes = parse(dump_raw())
    hits = match(nodes, needle)
    if not hits:
        print("NOT_FOUND %r" % needle)
        return 2
    # 优先可点击节点
    cand = [n for n in hits if n["clickable"]] or hits
    n = cand[0]
    adb("shell", "input", "tap", str(n["cx"]), str(n["cy"]))
    print("TAP %r at (%d,%d)" % (label(n)[:60], n["cx"], n["cy"]))
    return 0



def type_text(text):
    """逐段输入文本：双引号用 SHIFT+APOSTROPHE 组合键产生（input text 会吞引号）。"""
    buf = ""
    for ch in text:
        if ch == '"':
            if buf:
                adb("shell", "input", "text", buf)
                buf = ""
            adb("shell", "input", "keycombination", "59", "75")
        else:
            buf += ch
    if buf:
        adb("shell", "input", "text", buf)


def cmd_replace(args):
    """replace <y> <text>：点字段 -> 长按 -> 全选 -> 输入新文本。"""
    y = int(args[0])
    text = args[1]
    adb("shell", "input", "tap", "540", str(y))
    time.sleep(0.8)
    adb("shell", "input", "swipe", "540", str(y), "540", str(y), "900")
    time.sleep(1.6)
    nodes = parse(dump_raw())
    hits = match(nodes, "Select all")
    if not hits:
        print("NO_SELECT_ALL")
        return 2
    adb("shell", "input", "tap", str(hits[0]["cx"]), str(hits[0]["cy"]))
    time.sleep(0.8)
    type_text(text)
    time.sleep(0.5)
    print("REPLACED y=%d with %r" % (y, text))
    return 0


def cmd_text(args):
    """直接以 argv 传文本给 input text，避免 shell 引号转义问题。"""
    text = args[0]
    out = adb("shell", "input", "text", text)
    print("TEXT %r %s" % (text, out.strip()))
    return 0


def cmd_tapx(args):
    x, y = args[0], args[1]
    adb("shell", "input", "tap", x, y)
    print("TAPXY", x, y)
    return 0


def cmd_shot(args):
    name = args[0] if args else "shot"
    data = adb("exec-out", "screencap", "-p", binary=True)
    path = os.path.join(SHOTS, name + ".png")
    with open(path, "wb") as f:
        f.write(data)
    print("SHOT %s %d bytes" % (path, len(data)))
    return 0


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 1
    cmd, args = sys.argv[1], sys.argv[2:]
    fn = {
        "dump": cmd_dump,
        "find": cmd_find,
        "tap": cmd_tap,
        "text": cmd_text,
        "replace": cmd_replace,
        "tapx": cmd_tapx,
        "shot": cmd_shot,
    }.get(cmd)
    if not fn:
        print("unknown command", cmd)
        return 1
    return fn(args) or 0


if __name__ == "__main__":
    sys.exit(main())
