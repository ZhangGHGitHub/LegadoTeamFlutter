# -*- coding: utf-8 -*-
"""QA UI 辅助：dump 语义树 / 查找节点 / 点击 / 截图。仅用于设备验收取证。"""
import re, subprocess, sys, os, time, xml.etree.ElementTree as ET

ADB = r"D:\Program Files\MuMuPlayer\nx_main\adb.exe"
SERIAL = "192.168.100.62:5555"
BASE = r"D:\OH-WorkSpace\LegadoTeam\legado\tmp_debug\device_acceptance_20261103_batch2b1b2b"
SHOTS = os.path.join(BASE, "shots")
DATA = os.path.join(BASE, "data")


def adb(*args, timeout=60):
    return subprocess.run([ADB, "-s", SERIAL, *args], capture_output=True,
                          timeout=timeout)


def dump(name="ui"):
    adb("shell", "uiautomator", "dump", "/sdcard/qa_ui.xml")
    out = adb("exec-out", "cat", "/sdcard/qa_ui.xml")
    raw = out.stdout.decode("utf-8", "replace")
    start = raw.find("<?xml")
    if start < 0:
        raise SystemExit("dump 失败: " + raw[:300])
    xml_text = raw[start:]
    path = os.path.join(DATA, name + ".xml")
    with open(path, "w", encoding="utf-8") as f:
        f.write(xml_text)
    return xml_text


def nodes(xml_text):
    root = ET.fromstring(xml_text)
    out = []
    for n in root.iter("node"):
        t = n.get("text", "")
        d = n.get("content-desc", "")
        if not t and not d:
            continue
        b = n.get("bounds", "")
        out.append({
            "text": t, "desc": d, "cls": n.get("class", ""),
            "bounds": b, "checked": n.get("checked"),
            "clickable": n.get("clickable"), "enabled": n.get("enabled"),
            "selected": n.get("selected"),
        })
    return out


def show(xml_text):
    for n in nodes(xml_text):
        label = (n["text"] + " | " + n["desc"]).strip(" |")
        print(f'{n["bounds"]:28s} chk={n["checked"]:5s} clk={n["clickable"]:5s} '
              f'en={n["enabled"]:5s} {label}')



def shell(*args, timeout=60):
    return adb(*args, timeout=timeout)

def center(bounds):
    m = re.match(r"\[(\d+),(\d+)\]\[(\d+),(\d+)\]", bounds)
    if not m:
        return None
    x1, y1, x2, y2 = map(int, m.groups())
    return ((x1 + x2) // 2, (y1 + y2) // 2)


def find(xml_text, needle, nth=0):
    hits = []
    for n in nodes(xml_text):
        if needle in n["text"] or needle in n["desc"]:
            hits.append(n)
    return hits[nth] if len(hits) > nth else None


def tap(x, y):
    adb("shell", "input", "tap", str(x), str(y))


def tap_text(xml_text, needle, nth=0):
    n = find(xml_text, needle, nth)
    if not n:
        raise SystemExit(f"未找到节点: {needle}")
    c = center(n["bounds"])
    tap(*c)
    return c


def shot(name):
    out = adb("exec-out", "screencap", "-p", timeout=120)
    path = os.path.join(SHOTS, name + ".png")
    with open(path, "wb") as f:
        f.write(out.stdout)
    return path


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else "show"
    if cmd == "show":
        show(dump(sys.argv[2] if len(sys.argv) > 2 else "ui"))
    elif cmd == "shot":
        print(shot(sys.argv[2]))
    elif cmd == "tap":
        tap_text(dump(), sys.argv[2])
    elif cmd == "tapxy":
        tap(int(sys.argv[2]), int(sys.argv[3]))
