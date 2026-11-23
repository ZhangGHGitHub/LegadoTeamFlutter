#!/usr/bin/env python3
# QA helper: dump Flutter semantics via uiautomator, find/tap by text, screenshot.
# Read-only QA tooling; does not modify business code.
import os, re, subprocess, sys, time, hashlib
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

ADB = r"D:\Program Files\MuMuPlayer\nx_main\adb.exe"
SER = "192.168.100.62:5555"
BASE = r"D:\OH-WorkSpace\LegadoTeam\legado\tmp_debug\device_acceptance_20261101_batch2a1"

def adb(*args, timeout=60, binary=False):
    cmd = [ADB, "-s", SER, *args]
    r = subprocess.run(cmd, capture_output=True, timeout=timeout)
    if binary:
        return r.stdout
    return r.stdout.decode("utf-8", "replace"), r.stderr.decode("utf-8", "replace"), r.returncode

def dump_ui(path=None, retries=4):
    for i in range(retries):
        adb("shell", "uiautomator", "dump", "/sdcard/ui.xml", timeout=60)
        time.sleep(0.4)
        out = adb("exec-out", "cat", "/sdcard/ui.xml", binary=True, timeout=60)
        if out and b"<hierarchy" in out:
            text = out.decode("utf-8", "replace")
            p = path or os.path.join(BASE, "data", "ui_last.xml")
            with open(p, "w", encoding="utf-8") as f:
                f.write(text)
            return text, p
        time.sleep(0.6)
    raise RuntimeError("uiautomator dump failed")

def nodes(xml):
    res = []
    for m in re.finditer(r"<node\b[^>]*>", xml):
        tag = m.group(0)
        d = dict(re.findall(r'(\S+)="([^"]*)"', tag))
        if "bounds" not in d:
            continue
        b = re.match(r"\[(\d+),(\d+)\]\[(\d+),(\d+)\]", d["bounds"])
        if not b:
            continue
        x1, y1, x2, y2 = map(int, b.groups())
        d["rect"] = (x1, y1, x2, y2)
        d["center"] = ((x1 + x2) // 2, (y1 + y2) // 2)
        res.append(d)
    return res

def find(xml, needle, exact=False):
    out = []
    for n in nodes(xml):
        t = n.get("text", "") or ""
        c = n.get("content-desc", "") or ""
        if (exact and (t == needle or c == needle)) or (not exact and (needle in t or needle in c)):
            out.append(n)
    return out

def tap(x, y):
    adb("shell", "input", "tap", str(x), str(y))
    time.sleep(0.7)

def tap_text(needle, exact=False, index=0, xml=None):
    xml = xml or dump_ui()[0]
    ns = find(xml, needle, exact)
    if not ns:
        raise RuntimeError("not found: " + needle)
    n = ns[index]
    tap(*n["center"])
    return n

def shot(name):
    p = os.path.join(BASE, "shots", name)
    data = adb("exec-out", "screencap", "-p", binary=True, timeout=60)
    with open(p, "wb") as f:
        f.write(data)
    return p

def texts(xml):
    return [(n.get("text", "") or n.get("content-desc", ""), n["rect"]) for n in nodes(xml) if (n.get("text", "") or n.get("content-desc", ""))]

if __name__ == "__main__":
    cmd = sys.argv[1]
    if cmd == "dump":
        xml, p = dump_ui()
        for t, r in texts(xml):
            print(t.replace("\n", "\\n"), r)
        print("saved", p)
    elif cmd == "shot":
        print(shot(sys.argv[2]))
    elif cmd == "tap":
        tap_text(sys.argv[2], exact=("--exact" in sys.argv))
        print("tapped", sys.argv[2])
    else:
        print("usage: dump|shot NAME|tap TEXT")
