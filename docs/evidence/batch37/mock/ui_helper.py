# -*- coding: utf-8 -*-
"""批36 设备验收 UI 辅助（仅取证/驱动，不改产品代码）。

用法（在仓库任意目录）：
  python ui_helper.py dump [--grep 关键字]
  python ui_helper.py tap "语义文本|text"
  python ui_helper.py tapxy X Y
  python ui_helper.py input "ASCII 文本"
  python ui_helper.py key BACK
  python ui_helper.py shot 输出.png

约定：MuMu 可能把应用窗口挂在独立逻辑 display 上，dump 后按窗口实际
display 发送 input（-d）。设备默认 192.168.100.63:5555，可用 --dev 覆盖。
"""

import argparse
import os
import re
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET

ADB = r"D:\Android\platform-tools\adb.exe"
DEV = "192.168.100.63:5555"
PKG = "io.legado.flutter_legado"


CFG = {"dev": DEV}


def adb(*args, **kw):
    cmd = [ADB, "-s", kw.pop("dev", CFG["dev"])] + list(args)
    return subprocess.run(cmd, capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=kw.pop("timeout", 120))


def display_id() -> int:
    r = adb("shell", "dumpsys window windows")
    cur = None
    for line in r.stdout.splitlines():
        m = re.search(r"Window #\d+ Window\{\S+ u0 ([^}]+)\}", line)
        if m:
            cur = m.group(1)
        m2 = re.search(r"mDisplayId=(\d+)", line)
        if m2 and cur and PKG in cur:
            return int(m2.group(1))
    return 0


def sf_display_id(logical: int) -> int:
    """逻辑 displayId -> SurfaceFlinger display id（uniqueId local:XXX）。"""
    r = adb("shell", "dumpsys display")
    cur = None
    for line in r.stdout.splitlines():
        m = re.search(r"displayId (\d+)", line)
        if m and "DisplayInfo{" in line:
            cur = int(m.group(1))
        m2 = re.search(r"uniqueId \"local:(\d+)\"", line)
        if m2 and cur == logical:
            return int(m2.group(1))
    return 0


def dump(path=None) -> str:
    remote = "/data/local/tmp/qa36_ui.xml"
    adb("shell", "rm -f " + remote)
    adb("shell", "uiautomator dump " + remote)
    local = path or os.path.join(tempfile.gettempdir(), "qa36_ui.xml")
    adb("pull", remote, local)
    with open(local, "r", encoding="utf-8", errors="replace") as f:
        return f.read()


def nodes(xml: str):
    root = ET.fromstring(xml)
    out = []
    for n in root.iter("node"):
        t = n.get("text") or ""
        d = n.get("content-desc") or ""
        if not t and not d:
            continue
        out.append({
            "text": t,
            "desc": d,
            "bounds": n.get("bounds"),
            "clickable": n.get("clickable"),
            "cls": n.get("class"),
        })
    return out


def center(bounds: str):
    m = re.match(r"\[(\d+),(\d+)\]\[(\d+),(\d+)\]", bounds or "")
    if not m:
        return None
    x1, y1, x2, y2 = map(int, m.groups())
    return (x1 + x2) // 2, (y1 + y2) // 2


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("cmd")
    ap.add_argument("arg", nargs="?")
    ap.add_argument("arg2", nargs="?")
    ap.add_argument("--grep")
    ap.add_argument("--dev", default=DEV)
    a = ap.parse_args()

    CFG["dev"] = a.dev

    if a.cmd == "dump":
        xml = dump()
        for n in nodes(xml):
            line = "text=%r desc=%r bounds=%s click=%s" % (n["text"], n["desc"], n["bounds"], n["clickable"])
            if a.grep and a.grep not in line:
                continue
            print(line)
        return 0
    if a.cmd == "tap":
        target = a.arg
        xml = dump()
        for n in nodes(xml):
            if target == n["text"] or target == n["desc"] or target in n["text"] or (n["desc"] and target in n["desc"]):
                c = center(n["bounds"])
                if not c:
                    continue
                d = display_id()
                print("tap display=%d at %s for %r" % (d, c, target))
                adb("shell", "input -d %d tap %d %d" % (d, c[0], c[1]))
                return 0
        print("not found:", target)
        return 2
    if a.cmd == "tapxy":
        d = display_id()
        adb("shell", "input -d %d tap %s %s" % (d, a.arg, a.arg2))
        print("tap display=%d %s %s" % (d, a.arg, a.arg2))
        return 0
    if a.cmd == "input":
        d = display_id()
        adb("shell", "input -d %d text %s" % (d, a.arg.replace(" ", "%s")))
        return 0
    if a.cmd == "key":
        adb("shell", "input keyevent " + (a.arg or "KEYCODE_BACK"))
        return 0
    if a.cmd == "shot":
        out = a.arg or "shot.png"
        d = display_id()
        sf = sf_display_id(d)
        remote = "/data/local/tmp/%s" % os.path.basename(out)
        adb("shell", "screencap -p -d %d > %s" % (sf, remote), timeout=120)
        adb("pull", remote, out, timeout=120)
        print("wrote", out, "logical=%d sf=%d" % (d, sf), os.path.getsize(out))
        return 0
    print("unknown cmd")
    return 1


if __name__ == "__main__":
    sys.exit(main())
