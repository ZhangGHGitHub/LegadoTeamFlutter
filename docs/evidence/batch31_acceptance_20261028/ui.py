# -*- coding: utf-8 -*-
"""批31 设备验收 UI 自动化辅助（仅验收使用，不入库）"""
import re
import subprocess
import sys
import time
import os
import xml.etree.ElementTree as ET

ADB = r"D:\Android\platform-tools\adb.exe"
SERIAL = "192.168.100.62:5555"
BASE = os.path.dirname(os.path.abspath(__file__))
XML_LOCAL = os.path.join(BASE, "ui_dump.xml")


def adb(*args, **kw):
    cmd = [ADB, "-s", SERIAL] + list(args)
    env = dict(os.environ, MSYS_NO_PATHCONV="1")
    return subprocess.run(cmd, capture_output=True, text=True, encoding="utf-8",
                          errors="replace", env=env, **kw)


def dump(retries=3):
    for _ in range(retries):
        r = adb("shell", "uiautomator", "dump", "/sdcard/qa_ui.xml")
        time.sleep(0.4)
        rr = adb("pull", "/sdcard/qa_ui.xml", XML_LOCAL)
        if rr.returncode == 0 and os.path.exists(XML_LOCAL):
            try:
                return ET.parse(XML_LOCAL).getroot()
            except ET.ParseError:
                time.sleep(0.5)
    raise RuntimeError("uiautomator dump failed: " + r.stdout + r.stderr)


def nodes(root):
    out = []
    for n in root.iter("node"):
        a = n.attrib
        out.append({
            "text": a.get("text", ""),
            "desc": a.get("content-desc", ""),
            "cls": a.get("class", ""),
            "clickable": a.get("clickable", ""),
            "checked": a.get("checked", ""),
            "selected": a.get("selected", ""),
            "bounds": a.get("bounds", ""),
            "rid": a.get("resource-id", ""),
        })
    return out


def center(bounds):
    m = re.match(r"\[(\d+),(\d+)\]\[(\d+),(\d+)\]", bounds)
    if not m:
        return None
    x1, y1, x2, y2 = map(int, m.groups())
    return ((x1 + x2) // 2, (y1 + y2) // 2)


def find(root, needle, exact=False):
    hits = []
    for n in nodes(root):
        text = n["text"] or ""
        desc = n["desc"] or ""
        for val in (text, desc):
            if not val:
                continue
            ok = (val == needle) if exact else (needle in val)
            if ok:
                hits.append(n)
                break
    return hits


def show(root, limit=400):
    for i, n in enumerate(nodes(root)):
        if not (n["text"] or n["desc"]):
            continue
        c = center(n["bounds"])
        print(f'{i:3d} {n["cls"].split(".")[-1]:22s} click={n["clickable"]} '
              f'checked={n["checked"]} c={c} text={n["text"]!r} desc={n["desc"]!r}')
        limit -= 1
        if limit <= 0:
            break


def tap(x, y):
    adb("shell", "input", "tap", str(x), str(y))
    time.sleep(0.6)


def tap_text(root, needle, exact=False, idx=0):
    hits = find(root, needle, exact=exact)
    if not hits:
        raise RuntimeError(f"not found: {needle}")
    h = hits[idx]
    c = center(h["bounds"])
    if not c:
        raise RuntimeError(f"no center: {h}")
    tap(*c)
    return h


def swipe(x1, y1, x2, y2, dur=300):
    adb("shell", "input", "swipe", str(x1), str(y1), str(x2), str(y2), str(dur))
    time.sleep(0.7)


def screenshot(name):
    path = os.path.join(BASE, "shots", name)
    with open(path, "wb") as f:
        env = dict(os.environ, MSYS_NO_PATHCONV="1")
        p = subprocess.run([ADB, "-s", SERIAL, "exec-out", "screencap", "-p"],
                           stdout=f, env=env)
    print("screenshot ->", path)
    return path


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else "show"
    root = dump()
    if cmd == "show":
        show(root)
    elif cmd == "find":
        for n in find(root, sys.argv[2]):
            print(n)
    elif cmd == "tap":
        print(tap_text(root, sys.argv[2], exact=("--exact" in sys.argv)))
    elif cmd == "shot":
        screenshot(sys.argv[2])
    elif cmd == "back":
        adb("shell", "input", "keyevent", "4")
        time.sleep(0.6)
