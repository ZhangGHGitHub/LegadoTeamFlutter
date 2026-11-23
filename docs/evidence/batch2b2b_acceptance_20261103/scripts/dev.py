#!/usr/bin/env python
"""QA 设备交互辅助脚本（仅本机 MuMu 验收使用，不修改应用代码）。

用法:
  python dev.py shot <name>
  python dev.py dump <name> [--grep 文本]
  python dev.py find <文本> [--index N] [--text]   # 打印匹配节点与中心坐标
  python dev.py tap <x> <y>
  python dev.py tap_desc <文本> [--index N] [--text]
  python dev.py back
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


def run(args, binary=False):
    env = dict(os.environ, MSYS_NO_PATHCONV="1")
    p = subprocess.run([ADB, "-s", SERIAL] + args, capture_output=True, env=env)
    if p.returncode != 0:
        raise SystemExit(f"adb 失败 {args}: {p.stderr.decode('utf-8', 'replace')}")
    return p.stdout if binary else p.stdout.decode("utf-8", "replace")


def dump_tree():
    # 已知设备限制：uiautomator dump 写出成功后进程自杀（exit 139），
    # 因此忽略退出码，以拉取到的 XML 是否可解析为准。
    env = dict(os.environ, MSYS_NO_PATHCONV="1")
    subprocess.run(
        [ADB, "-s", SERIAL, "shell", "uiautomator", "dump", "/data/local/tmp/ui.xml"],
        capture_output=True,
        env=env,
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
    x1, y1, x2, y2 = map(int, m.groups())
    return x1, y1, x2, y2


def matches(n, q, use_text):
    v = n.get("text") if use_text else n.get("content-desc")
    return bool(v) and q in v


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
        label = node_label(n).replace("\n", " / ")
        print(f"{n.get('class')} | {label!r} | {b} | center={( (b[0]+b[2])//2, (b[1]+b[3])//2 ) if b else None} | clickable={n.get('clickable')} | en={n.get('enabled')}")
    if len(hits) <= idx:
        raise SystemExit(f"未找到第 {idx} 个匹配: {q}（共 {len(hits)}）")
    b = bounds(hits[idx])
    if not b:
        raise SystemExit("匹配节点无 bounds")
    print(f"CENTER {(b[0]+b[2])//2} {(b[1]+b[3])//2}")


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
        print(f"{label!r} {b} clickable={n.get('clickable')} sel={n.get('selected')}")
        count += 1
        if count > 120:
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
    x, y = (b[0] + b[2]) // 2, (b[1] + b[3]) // 2
    run(["shell", "input", "tap", str(x), str(y)])
    print("TAPPED", q, "at", x, y, "bounds", b)


def cmd_back(argv):
    run(["shell", "input", "keyevent", "4"])
    print("BACK")


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
        "back": cmd_back,
    }[cmd](argv)
