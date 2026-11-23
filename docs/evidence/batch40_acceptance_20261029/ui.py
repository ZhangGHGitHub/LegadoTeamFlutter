#!/usr/bin/env python3
"""批40 设备验收 UI 辅助：dump / 查找 / 点击 / 截图（不含业务逻辑）。"""
import re
import subprocess
import sys
import xml.etree.ElementTree as ET

ADB = r"D:\Android\platform-tools\adb.exe"
SERIAL = "192.168.100.62:5555"
BASE = r"D:\OH-WorkSpace\LegadoTeam\legado\tmp_debug\device_acceptance_20261029_batch40"


def adb(*args, timeout=60):
    cmd = [ADB, "-s", SERIAL, *args]
    r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout,
                       encoding="utf-8", errors="replace")
    return r


def dump(path=f"{BASE}\\ui.xml"):
    adb("exec-out", "uiautomator", "dump", "/dev/tty")
    r = adb("exec-out", "uiautomator", "dump", "/sdcard/ui_dump.xml")
    r2 = adb("exec-out", "cat", "/sdcard/ui_dump.xml")
    with open(path, "w", encoding="utf-8") as f:
        f.write(r2.stdout)
    return path


def nodes(path):
    tree = ET.parse(path)
    out = []
    for n in tree.iter("node"):
        out.append({
            "text": n.get("text", ""),
            "desc": n.get("content-desc", ""),
            "cls": n.get("class", ""),
            "bounds": n.get("bounds", ""),
            "clickable": n.get("clickable", ""),
            "checked": n.get("checked", ""),
            "focused": n.get("focused", ""),
            "rid": n.get("resource-id", ""),
        })
    return out


def center(bounds):
    m = re.match(r"\[(\d+),(\d+)\]\[(\d+),(\d+)\]", bounds)
    if not m:
        return None
    x1, y1, x2, y2 = map(int, m.groups())
    return (x1 + x2) // 2, (y1 + y2) // 2


def find(path, needle, field="any"):
    res = []
    for n in nodes(path):
        hay = n["text"] + "\n" + n["desc"] if field == "any" else n[field]
        if needle in hay:
            res.append(n)
    return res


def tap_xy(x, y):
    adb("shell", "input", "tap", str(x), str(y))


def tap_text(needle, field="any", index=0, wait=1.0):
    path = dump()
    hits = find(path, needle, field)
    if not hits:
        print(f"NOT FOUND: {needle}")
        return False
    c = center(hits[min(index, len(hits) - 1)]["bounds"])
    if not c:
        print(f"NO CENTER: {hits[index]}")
        return False
    print(f"TAP {needle!r} @ {c}  (text={hits[min(index,len(hits)-1)]['text']!r} desc={hits[min(index,len(hits)-1)]['desc']!r})")
    tap_xy(*c)
    import time
    time.sleep(wait)
    return True


def screenshot(name):
    r = subprocess.run([ADB, "-s", SERIAL, "exec-out", "screencap", "-p"],
                       capture_output=True, timeout=60)
    with open(f"{BASE}\\{name}", "wb") as f:
        f.write(r.stdout)
    print("saved", name, len(r.stdout))


def text_input(value):
    adb("shell", "input", "text", value.replace(" ", "%s"))


if __name__ == "__main__":
    cmd = sys.argv[1]
    if cmd == "dump":
        p = dump()
        for n in nodes(p):
            if n["text"] or n["desc"]:
                print(f"{n['bounds']} click={n['clickable']} checked={n['checked']} text={n['text']!r} desc={n['desc']!r}")
    elif cmd == "tap":
        tap_text(sys.argv[2])
    elif cmd == "shot":
        screenshot(sys.argv[2])
    elif cmd == "find":
        path = dump()
        for n in find(path, sys.argv[2]):
            print(n)
    elif cmd == "input":
        text_input(sys.argv[2])
