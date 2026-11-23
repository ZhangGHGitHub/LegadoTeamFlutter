#!/usr/bin/env python
"""QA UI helper for the MuMu device (adb). Not part of the app."""
import os
import re
import subprocess
import sys
import time
import xml.etree.ElementTree as ET

ADB = r"D:\Program Files\MuMuPlayer\nx_main\adb.exe"
SERIAL = "192.168.100.62:5555"
BASE = os.path.dirname(os.path.abspath(__file__))
XML = os.path.join(BASE, "ui_current.xml")


def adb(*args, capture=True, timeout=60):
    cmd = [ADB, "-s", SERIAL, *args]
    r = subprocess.run(
        cmd,
        capture_output=capture,
        timeout=timeout,
        text=False,
    )
    return r


def shell(cmd, timeout=60):
    return adb("shell", cmd, timeout=timeout)


def dump(retries=2):
    for _ in range(retries):
        r = shell("uiautomator dump /sdcard/ui.xml")
        if b"dumped" in (r.stdout or b""):
            break
        time.sleep(0.5)
    r = adb("pull", "/sdcard/ui.xml", XML)
    if r.returncode != 0:
        raise RuntimeError("pull failed: %r" % (r.stderr[:200],))
    return parse()


def parse():
    with open(XML, "rb") as f:
        raw = f.read()
    root = ET.fromstring(raw)
    out = []
    for n in root.iter("node"):
        cd = n.get("content-desc") or ""
        txt = n.get("text") or ""
        if not cd and not txt:
            continue
        b = n.get("bounds") or ""
        m = re.findall(r"-?\d+", b)
        if len(m) != 4:
            continue
        out.append(
            {
                "text": txt,
                "desc": cd,
                "cls": n.get("class"),
                "clickable": n.get("clickable"),
                "enabled": n.get("enabled"),
                "checked": n.get("checked"),
                "bounds": [int(v) for v in m],
            }
        )
    return out


def show(nodes=None):
    nodes = nodes if nodes is not None else dump()
    for n in nodes:
        label = (n["text"] or n["desc"]).replace("\n", "/")
        print(
            "%-30s | %s | click=%s en=%s chk=%s | %s"
            % (
                label[:30],
                n["cls"].split(".")[-1],
                n["clickable"],
                n["enabled"],
                n["checked"],
                n["bounds"],
            )
        )


def find(keyword, nodes=None):
    nodes = nodes if nodes is not None else dump()
    hits = [n for n in nodes if keyword in (n["text"] + "|" + n["desc"])]
    return hits


def tap_node(n):
    x = (n["bounds"][0] + n["bounds"][2]) // 2
    y = (n["bounds"][1] + n["bounds"][3]) // 2
    shell("input tap %d %d" % (x, y))
    time.sleep(1.0)
    return x, y


def tap(keyword, index=0):
    hits = find(keyword)
    if not hits:
        print("NOT FOUND:", keyword)
        show()
        return None
    if index >= len(hits):
        print("index out of range; hits:", len(hits))
        return None
    n = hits[index]
    print("TAP", (n["text"] or n["desc"]).replace("\n", "/"), n["bounds"])
    return tap_node(n)


def shot(name):
    path = os.path.join(BASE, "..", "shots", name)
    path = os.path.abspath(path)
    with open(path, "wb") as f:
        r = subprocess.run(
            [ADB, "-s", SERIAL, "exec-out", "screencap", "-p"],
            stdout=f,
            timeout=60,
        )
    print("SHOT", path, os.path.getsize(path))


def key(code):
    shell("input keyevent %s" % code)
    time.sleep(1.0)


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else "show"
    if cmd == "show":
        show()
    elif cmd == "tap":
        tap(sys.argv[2], int(sys.argv[3]) if len(sys.argv) > 3 else 0)
    elif cmd == "find":
        show(find(sys.argv[2]))
    elif cmd == "shot":
        shot(sys.argv[2])
    elif cmd == "back":
        key(4)
    else:
        print("usage: uia.py [show|tap <kw> [idx]|find <kw>|shot <name>|back]")
