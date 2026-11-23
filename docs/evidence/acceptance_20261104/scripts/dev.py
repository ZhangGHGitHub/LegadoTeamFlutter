#!/usr/bin/env python
"""QA device helper: adb wrapper for MuMu (screenshots, ui dumps, taps)."""
import argparse, os, re, subprocess, sys, time, xml.etree.ElementTree as ET

ADB = r"D:\Program Files\MuMuPlayer\nx_main\adb.exe"
SERIAL = "192.168.100.62:5555"
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SHOTS = os.path.join(ROOT, "shots")
DATA = os.path.join(ROOT, "data")

def run(args, timeout=120, binary=False):
    cmd = [ADB, "-s", SERIAL] + args
    p = subprocess.run(cmd, capture_output=True, timeout=timeout)
    if binary:
        return p.returncode, p.stdout, p.stderr
    return p.returncode, p.stdout.decode("utf-8", "replace"), p.stderr.decode("utf-8", "replace")

def sh(cmd, timeout=120):
    return run(["shell", cmd], timeout=timeout)

def shot(name):
    os.makedirs(SHOTS, exist_ok=True)
    path = os.path.join(SHOTS, name + ".png")
    p = subprocess.run([ADB, "-s", SERIAL, "exec-out", "screencap", "-p"], capture_output=True, timeout=120)
    with open(path, "wb") as f:
        f.write(p.stdout)
    print(f"shot {path} {len(p.stdout)}B")
    return path

def dump(name):
    os.makedirs(DATA, exist_ok=True)
    sh("uiautomator dump /sdcard/qa_ui.xml")
    time.sleep(0.6)
    code, out, err = run(["exec-out", "cat", "/sdcard/qa_ui.xml"], binary=True)
    path = os.path.join(DATA, name + ".xml")
    with open(path, "wb") as f:
        f.write(out)
    print(f"dump {path} {len(out)}B")
    return path

def parse(path):
    tree = ET.parse(path)
    items = []
    for n in tree.iter("node"):
        a = n.attrib
        txt = a.get("text", "") or ""
        desc = a.get("content-desc", "") or ""
        bounds = a.get("bounds", "")
        if txt or desc:
            items.append((txt, desc, bounds, a.get("class", ""), a.get("clickable", "")))
    return items

def find(path, needle, index=0):
    hits = []
    for txt, desc, bounds, cls, clickable in parse(path):
        if needle in txt or needle in desc:
            hits.append((txt, desc, bounds, clickable))
    if not hits:
        print(f"NOT FOUND: {needle}")
        return None
    for h in hits:
        print(h)
    return hits[min(index, len(hits)-1)]

def center(bounds):
    m = re.match(r"\[(\d+),(\d+)\]\[(\d+),(\d+)\]", bounds)
    x1, y1, x2, y2 = map(int, m.groups())
    return (x1 + x2) // 2, (y1 + y2) // 2

def tap_xy(x, y):
    sh(f"input tap {x} {y}")
    print(f"tap {x},{y}")
    time.sleep(1.0)

def tap(needle, index=0, wait=1.0):
    p = dump("_last")
    h = find(p, needle, index)
    if not h:
        return False
    x, y = center(h[2])
    sh(f"input tap {x} {y}")
    print(f"tap '{needle}' -> {x},{y}")
    time.sleep(wait)
    return True

def key(code):
    sh(f"input keyevent {code}")
    time.sleep(0.8)

def swipe(x1,y1,x2,y2,ms=300):
    sh(f"input swipe {x1} {y1} {x2} {y2} {ms}")
    time.sleep(0.8)

if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("cmd", choices=["shot","dump","find","tap","tapxy","key","swipe","sh","parsedump"])
    ap.add_argument("a", nargs="*")
    ns = ap.parse_args()
    if ns.cmd == "shot": shot(ns.a[0])
    elif ns.cmd == "dump": dump(ns.a[0])
    elif ns.cmd == "find": find(ns.a[0] if ns.a[0].endswith('.xml') else os.path.join(DATA, ns.a[0]+'.xml'), ns.a[1])
    elif ns.cmd == "parsedump":
        for it in parse(ns.a[0]): print(it)
    elif ns.cmd == "tap": tap(ns.a[0], int(ns.a[1]) if len(ns.a)>1 else 0)
    elif ns.cmd == "tapxy": tap_xy(int(ns.a[0]), int(ns.a[1]))
    elif ns.cmd == "key": key(ns.a[0])
    elif ns.cmd == "swipe": swipe(*map(int, ns.a[:4]))
    elif ns.cmd == "sh":
        c,o,e = sh(" ".join(ns.a)); print(o); print(e, file=sys.stderr)
