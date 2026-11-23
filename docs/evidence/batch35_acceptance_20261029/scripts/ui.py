#!/usr/bin/env python3
"""批35 设备验收 UI 辅助：dump / 查找 / 点击 / 截图（MuMu 192.168.100.62:5555）"""
import re
import subprocess
import sys
import time
import xml.etree.ElementTree as ET

ADB = r"D:\Android\platform-tools\adb.exe"
SERIAL = "192.168.100.62:5555"
PKG = "io.legado.flutter_legado"
REMOTE = "/sdcard/qa35_ui.xml"


def adb(*args, timeout=60):
    return subprocess.run([ADB, "-s", SERIAL, *args], capture_output=True, text=True,
                          encoding="utf-8", errors="replace", timeout=timeout)


def display_id():
    out = adb("shell", "dumpsys window windows").stdout
    cur = "0"
    for line in out.splitlines():
        m = re.search(r"mDisplayId=(\d+)", line)
        if m:
            cur = m.group(1)
        if PKG in line:
            return cur
    return cur


def dump_xml(retries=3):
    for _ in range(retries):
        adb("shell", "rm", "-f", REMOTE)
        adb("shell", "uiautomator", "dump", REMOTE)
        r = adb("exec-out", "cat", REMOTE)
        if "<hierarchy" in r.stdout:
            return r.stdout
        time.sleep(0.5)
    return ""


def nodes(xml):
    if not xml.strip():
        return []
    root = ET.fromstring(xml)
    return list(root.iter("node"))


def parse_bounds(b):
    m = re.match(r"\[(\d+),(\d+)\]\[(\d+),(\d+)\]", b or "")
    if not m:
        return None
    return tuple(int(x) for x in m.groups())


def center(b):
    x1, y1, x2, y2 = b
    return (x1 + x2) // 2, (y1 + y2) // 2


def tap_xy(x, y):
    adb("shell", "input", "tap", str(x), str(y))
    time.sleep(0.6)


def find(needle, xml=None, exact=False):
    xml = xml or dump_xml()
    hits = []
    for n in nodes(xml):
        text = n.get("text") or ""
        desc = n.get("content-desc") or ""
        for val in (text, desc):
            if not val:
                continue
            ok = (val == needle) if exact else (needle in val)
            if ok:
                hits.append(n)
                break
    return hits


def describe(xml=None):
    xml = xml or dump_xml()
    out = []
    for n in nodes(xml):
        text = (n.get("text") or "").strip()
        desc = (n.get("content-desc") or "").strip()
        if not text and not desc:
            continue
        out.append({
            "text": text, "desc": desc, "bounds": n.get("bounds"),
            "clickable": n.get("clickable"), "checked": n.get("checked"),
            "enabled": n.get("enabled"), "class": n.get("class", "").split(".")[-1],
        })
    return out


def cmd_dump():
    xml = dump_xml()
    for i, n in enumerate(describe(xml)):
        print(i, n)
    print("display", display_id(), "len", len(xml))


def cmd_find(needle):
    xml = dump_xml()
    hits = find(needle, xml)
    for n in hits:
        print(n.get("text"), "|", n.get("content-desc"), "|", n.get("bounds"),
              "| checked=", n.get("checked"))
    print("hits", len(hits))


def cmd_tap(needle, exact=False):
    xml = dump_xml()
    hits = find(needle, xml, exact=exact)
    if not hits:
        print("NOTFOUND", needle)
        return 1
    # 优先可点击节点自身，否则向上找可点击祖先
    for n in hits:
        b = parse_bounds(n.get("bounds"))
        if not b:
            continue
        x, y = center(b)
        tap_xy(x, y)
        print("TAPPED", needle, x, y)
        return 0
    print("NOBOUNDS", needle)
    return 1


def long_press(needle, ms=900):
    xml = dump_xml()
    hits = find(needle, xml)
    if not hits:
        print("NOTFOUND", needle)
        return 1
    b = parse_bounds(hits[0].get("bounds"))
    if not b:
        print("NOBOUNDS", needle)
        return 1
    x, y = center(b)
    adb("shell", "input", "swipe", str(x), str(y), str(x), str(y), str(ms))
    time.sleep(0.8)
    print("LONGPRESSED", needle, x, y)
    return 0


def cmd_shot(name):
    r = subprocess.run([ADB, "-s", SERIAL, "exec-out", "screencap", "-p"],
                       capture_output=True, timeout=60)
    path = name if name.endswith(".png") else name + ".png"
    with open(path, "wb") as f:
        f.write(r.stdout)
    print("SHOT", path, len(r.stdout))
    return 0


def cmd_wait(needle, timeout):
    deadline = time.time() + float(timeout)
    while time.time() < deadline:
        if find(needle):
            print("FOUND", needle)
            return 0
        time.sleep(1)
    print("TIMEOUT", needle)
    return 1


if __name__ == "__main__":
    cmd = sys.argv[1]
    if cmd == "dump":
        cmd_dump()
    elif cmd == "find":
        sys.exit(cmd_find(sys.argv[2]))
    elif cmd == "tap":
        sys.exit(cmd_tap(sys.argv[2]))
    elif cmd == "tapx":
        sys.exit(cmd_tap(sys.argv[2], exact=True))
    elif cmd == "long":
        sys.exit(long_press(sys.argv[2], int(sys.argv[3]) if len(sys.argv) > 3 else 900))
    elif cmd == "shot":
        sys.exit(cmd_shot(sys.argv[2]))
    elif cmd == "wait":
        sys.exit(cmd_wait(sys.argv[2], sys.argv[3] if len(sys.argv) > 3 else 20))
    elif cmd == "dispid":
        print(display_id())
