#!/usr/bin/env python
"""QA 2b-2c 设备交互辅助脚本（仅本机 MuMu 验收使用，不修改应用代码）。

扩展自 2b-2b dev.py：增加长按 / 文本输入 / 滑动 / 多击 / 按键。
"""
import os
import re
import subprocess
import sys
import time
import xml.etree.ElementTree as ET

ADB = r"D:\Program Files\MuMuPlayer\nx_main\adb.exe"
SERIAL = "192.168.100.62:5555"
BASE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SHOTS = os.path.join(BASE, "shots")
DATA = os.path.join(BASE, "data")
os.makedirs(SHOTS, exist_ok=True)
os.makedirs(DATA, exist_ok=True)

ENV = dict(os.environ, MSYS_NO_PATHCONV="1")


def run(args, binary=False, check=True):
    p = subprocess.run([ADB, "-s", SERIAL] + args, capture_output=True, env=ENV)
    if check and p.returncode != 0:
        raise SystemExit(f"adb 失败 {args}: {p.stderr.decode('utf-8', 'replace')}")
    return p.stdout if binary else p.stdout.decode("utf-8", "replace")


def dump_tree():
    # 已知设备限制：uiautomator dump 写出成功后进程自杀（exit 139），
    # 因此忽略退出码，以拉取到的 XML 是否可解析为准。
    subprocess.run(
        [ADB, "-s", SERIAL, "shell", "uiautomator", "dump",
         "/data/local/tmp/ui.xml"],
        capture_output=True, env=ENV,
    )
    time.sleep(0.4)
    xml = run(["exec-out", "cat", "/data/local/tmp/ui.xml"])
    return ET.fromstring(xml)


def save_tree(name):
    tree = dump_tree()
    path = os.path.join(DATA, name + ".xml")
    with open(path, "w", encoding="utf-8") as f:
        f.write(ET.tostring(tree, encoding="unicode"))
    return tree, path


def node_label(n):
    d = (n.get("content-desc") or "").replace("\n", " / ")
    t = (n.get("text") or "").replace("\n", " / ")
    return d or t


def bounds(n):
    m = re.match(r"\[(\d+),(\d+)\]\[(\d+),(\d+)\]", n.get("bounds", ""))
    if not m:
        return None
    return tuple(map(int, m.groups()))


def matches(n, q, use_text):
    v = n.get("text") if use_text else n.get("content-desc")
    return bool(v) and q in v


def center(b):
    return (b[0] + b[2]) // 2, (b[1] + b[3]) // 2


def cmd_find(argv):
    q = argv[0]
    use_text = "--text" in argv
    idx = 0
    if "--index" in argv:
        idx = int(argv[argv.index("--index") + 1])
    tree = dump_tree()
    hits = [n for n in tree.iter("node") if matches(n, q, use_text)]
    for n in hits:
        b = bounds(n)
        print(
            f"{n.get('class')} | {node_label(n)!r} | {b} | "
            f"center={center(b) if b else None} | clickable={n.get('clickable')} | "
            f"en={n.get('enabled')}"
        )
    if len(hits) <= idx:
        raise SystemExit(f"未找到第 {idx} 个匹配: {q}（共 {len(hits)}）")
    b = bounds(hits[idx])
    print(f"CENTER {b[0] + (b[2] - b[0]) // 2} {b[1] + (b[3] - b[1]) // 2}")


def cmd_dump(argv):
    name = argv[0]
    tree, path = save_tree(name)
    grep = None
    if "--grep" in argv:
        grep = argv[argv.index("--grep") + 1]
    count = 0
    for n in tree.iter("node"):
        label = node_label(n)
        if not label:
            continue
        if grep and grep not in label:
            continue
        b = bounds(n)
        print(
            f"{label!r} {b} clickable={n.get('clickable')} "
            f"sel={n.get('selected')}"
        )
        count += 1
        if count > 160:
            print("... 截断")
            break
    print("SAVED", path)


def cmd_shot(argv):
    name = argv[0]
    png = run(["exec-out", "screencap", "-p"], binary=True)
    path = os.path.join(SHOTS, name + ".png")
    with open(path, "wb") as f:
        f.write(png)
    print("SAVED", path, len(png), "bytes")


def cmd_tap(argv):
    x, y = argv[0], argv[1]
    run(["shell", "input", "tap", x, y])
    print("TAPPED", x, y)


def cmd_longpress(argv):
    x, y = argv[0], argv[1]
    dur = argv[2] if len(argv) > 2 else "900"
    run(["shell", "input", "swipe", x, y, x, y, dur])
    print("LONGPRESS", x, y, dur)


def cmd_swipe(argv):
    x1, y1, x2, y2 = argv[:4]
    dur = argv[4] if len(argv) > 4 else "300"
    run(["shell", "input", "swipe", x1, y1, x2, y2, dur])
    print("SWIPED", x1, y1, x2, y2, dur)


def cmd_text(argv):
    # ASCII only（本批不需要中文输入到应用）
    run(["shell", "input", "text", argv[0].replace(" ", "%s")])
    print("TEXT", argv[0])


def cmd_tap_desc(argv):
    q = argv[0]
    use_text = "--text" in argv
    idx = 0
    if "--index" in argv:
        idx = int(argv[argv.index("--index") + 1])
    tree = dump_tree()
    hits = [n for n in tree.iter("node") if matches(n, q, use_text)]
    if len(hits) <= idx:
        raise SystemExit(f"未找到第 {idx} 个匹配: {q}（共 {len(hits)}）")
    b = bounds(hits[idx])
    x, y = center(b)
    run(["shell", "input", "tap", str(x), str(y)])
    print("TAPPED", q, "at", x, y, "bounds", b)


def cmd_back(argv):
    run(["shell", "input", "keyevent", "4"])
    print("BACK")


def cmd_key(argv):
    run(["shell", "input", "keyevent", argv[0]])
    print("KEY", argv[0])


if __name__ == "__main__":
    if len(sys.argv) < 2:
        raise SystemExit(__doc__)
    cmd, argv = sys.argv[1], sys.argv[2:]
    {
        "shot": cmd_shot,
        "dump": cmd_dump,
        "find": cmd_find,
        "tap": cmd_tap,
        "tap_desc": cmd_tap_desc,
        "longpress": cmd_longpress,
        "swipe": cmd_swipe,
        "text": cmd_text,
        "back": cmd_back,
        "key": cmd_key,
    }[cmd](argv)
