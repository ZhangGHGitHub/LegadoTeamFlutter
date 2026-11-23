#!/usr/bin/env python
"""UI dump / tap helper for Legado device acceptance (own script)."""
import re
import subprocess
import sys
import time

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

ADB = r"D:\Program Files\MuMuPlayer\nx_main\adb.exe"
SERIAL = "192.168.100.62:5555"
BASE = r"D:\OH-WorkSpace\LegadoTeam\legado\tmp_debug\device_acceptance_20261103_batch2b2a"


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
        b = re.search(r'bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"', t)
        if not b:
            continue
        nodes.append({
            "text": txt.group(1) if txt else "",
            "desc": desc.group(1) if desc else "",
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


def main():
    cmd = sys.argv[1] if len(sys.argv) > 1 else "dump"
    name = sys.argv[2] if cmd == "dump" and len(sys.argv) > 2 else "ui"
    nodes, path = dump(name)
    if cmd == "dump":
        for n in nodes:
            v = label(n)
            if v:
                print(repr(v), n["x1"], n["y1"], n["x2"], n["y2"])
        print("saved", path)
    elif cmd == "find":
        needle = sys.argv[2]
        for i, n in enumerate(nodes):
            if needle in label(n):
                x, y = center(n)
                print(i, repr(label(n)), n["x1"], n["y1"], n["x2"], n["y2"], "->", x, y)
    elif cmd == "tap":
        needle = sys.argv[2]
        exact = len(sys.argv) > 4 and sys.argv[4] == "exact"
        n = find(nodes, needle, exact=exact)
        if not n:
            print("NOT FOUND:", needle)
            sys.exit(2)
        x, y = center(n)
        adb(["shell", "input", "tap", str(x), str(y)])
        print("tapped", repr(label(n)), x, y)
        time.sleep(0.4)


if __name__ == "__main__":
    main()
