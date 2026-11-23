#!/usr/bin/env python
"""UI dump / tap / screenshot helper — 批2b-2a 旋转回修复验."""
import re
import subprocess
import sys
import time

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

ADB = r"D:\Program Files\MuMuPlayer\nx_main\adb.exe"
SERIAL = "192.168.100.62:5555"
BASE = r"D:\OH-WorkSpace\LegadoTeam\legado\tmp_debug\device_acceptance_20261103_reverify"
SHOT = r"D:\OH-WorkSpace\LegadoTeam\legado\docs\materials_1103\reverify"


def adb(args, timeout=60):
    return subprocess.run([ADB, "-s", SERIAL] + args, capture_output=True,
                          timeout=timeout)


def dump(name="ui"):
    adb(["shell", "uiautomator", "dump", "/sdcard/ui.xml"])
    path = BASE + "\\data\\" + name + ".xml"
    adb(["pull", "/sdcard/ui.xml", path])
    s = open(path, encoding="utf-8").read()
    nodes = []
    for m in re.finditer(r"<node[^>]*>", s):
        t = m.group(0)
        txt = re.search(r'text="([^"]*)"', t)
        desc = re.search(r'content-desc="([^"]*)"', t)
        cls = re.search(r'class="([^"]*)"', t)
        sel = re.search(r'selected="([^"]*)"', t)
        chk = re.search(r'checked="([^"]*)"', t)
        en = re.search(r'enabled="([^"]*)"', t)
        b = re.search(r'bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"', t)
        if not b:
            continue
        nodes.append({
            "text": txt.group(1) if txt else "",
            "desc": desc.group(1) if desc else "",
            "cls": cls.group(1) if cls else "",
            "selected": sel.group(1) if sel else "",
            "checked": chk.group(1) if chk else "",
            "enabled": en.group(1) if en else "",
            "x1": int(b.group(1)), "y1": int(b.group(2)),
            "x2": int(b.group(3)), "y2": int(b.group(4)),
        })
    return nodes, path


def center(n):
    return (n["x1"] + n["x2"]) // 2, (n["y1"] + n["y2"]) // 2


def label(n):
    return n["text"] if n["text"] else n["desc"]


def find(nodes, needle, exact=False, idx=0):
    hits = []
    for n in nodes:
        v = label(n)
        ok = (v == needle) if exact else (needle in v)
        if ok:
            hits.append(n)
    return hits[idx] if len(hits) > idx else None


def shot(name):
    p = SHOT + "\\" + name + ".png"
    r = adb(["exec-out", "screencap", "-p"])
    with open(p, "wb") as f:
        f.write(r.stdout)
    print("shot", p, len(r.stdout), "bytes")


def main():
    cmd = sys.argv[1] if len(sys.argv) > 1 else "dump"
    name = sys.argv[2] if len(sys.argv) > 2 else "ui"
    if cmd == "shot" or cmd == "rawshot":
        shot(name)
        return
    if cmd == "tap":
        # 固定 dump 名，避免标签含斜杠/特殊字符导致路径非法
        name = "_tap_tmp"
    nodes, path = dump(name)
    if cmd == "dump":
        for n in nodes:
            v = label(n)
            if v:
                flags = ""
                if n["selected"] == "true":
                    flags += " [selected]"
                if n["checked"] == "true":
                    flags += " [checked]"
                if n["enabled"] == "false":
                    flags += " [disabled]"
                print(repr(v), n["cls"].split(".")[-1], n["x1"], n["y1"],
                      n["x2"], n["y2"], flags)
        print("saved", path)
    elif cmd == "find":
        needle = sys.argv[2]
        for i, n in enumerate(nodes):
            if needle in label(n):
                x, y = center(n)
                print(i, repr(label(n)), n["cls"].split(".")[-1], n["x1"],
                      n["y1"], n["x2"], n["y2"], "->", x, y,
                      "[sel]" if n["selected"] == "true" else "")
    elif cmd == "tap":
        needle = sys.argv[2]
        exact = len(sys.argv) > 4 and sys.argv[4] == "exact"
        # 固定 dump 名，避免标签含斜杠/特殊字符导致路径非法
        nodes, _ = dump("_tap_tmp")
        n = find(nodes, needle, exact=exact)
        if not n:
            print("NOT FOUND:", needle)
            sys.exit(2)
        x, y = center(n)
        adb(["shell", "input", "tap", str(x), str(y)])
        print("tapped", repr(label(n)), x, y)
        time.sleep(0.5)
    elif cmd == "swipe":
        # swipe x1 y1 x2 y2 [dur]
        a = [int(v) for v in sys.argv[2:6]]
        dur = int(sys.argv[6]) if len(sys.argv) > 6 else 400
        adb(["shell", "input", "swipe", str(a[0]), str(a[1]), str(a[2]),
             str(a[3]), str(dur)])
        time.sleep(0.6)


if __name__ == "__main__":
    main()
