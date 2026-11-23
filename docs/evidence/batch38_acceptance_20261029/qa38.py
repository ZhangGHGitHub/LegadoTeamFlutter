# -*- coding: utf-8 -*-
"""批38 设备验收 UI 驱动辅助（阅读主题列表）。

用法（在证据目录下执行）:
  python qa38.py state                 # 打印当前界面元素
  python qa38.py shot <name>           # 截图 + dump 到 shots/<name>.png|xml
  python qa38.py tap <x> <y> [wait]
  python qa38.py tapf <label> [wait] [exact]
  python qa38.py swipe <x1> <y1> <x2> <y2> [ms]
  python qa38.py key <KEYCODE>
  python qa38.py back
  python qa38.py launch
  python qa38.py prefs <name>          # 拉取 prefs 到 prefs/<name>.xml
  python qa38.py db <sql>              # 设备端 sqlite3 执行
  python qa38.py wait <seconds>
"""
import os
import re
import subprocess
import sys
import time
import xml.etree.ElementTree as ET

ADB = r"D:\Android\platform-tools\adb.exe"
SER = "192.168.100.62:5555"
PKG = "io.legado.flutter_legado"
ACT = "io.legado.flutter.MainActivity"
BASE = os.path.dirname(os.path.abspath(__file__))
SHOTS = os.path.join(BASE, "shots")
PREFS = os.path.join(BASE, "prefs")
DB = "/data/data/io.legado.flutter_legado/app_flutter/legado.db"
PREFS_XML = "/data/data/io.legado.flutter_legado/shared_prefs/FlutterSharedPreferences.xml"


def adb(*args, timeout=90, check=False):
    env = dict(os.environ)
    env["MSYS_NO_PATHCONV"] = "1"
    r = subprocess.run([ADB, "-s", SER, *args], capture_output=True, text=True,
                       timeout=timeout, encoding="utf-8", errors="replace", env=env)
    if check and r.returncode != 0:
        raise RuntimeError((r.stdout or "") + (r.stderr or ""))
    return (r.stdout or "") + (r.stderr or "")


def dump(path=None):
    path = path or os.path.join(SHOTS, "_state.xml")
    for _ in range(3):
        adb("shell", "uiautomator dump /sdcard/qa38_ui.xml")
        adb("pull", "/sdcard/qa38_ui.xml", path)
        if os.path.exists(path) and os.path.getsize(path) > 100:
            try:
                ET.parse(path)
                break
            except ET.ParseError:
                time.sleep(1)
        time.sleep(1)
    try:
        tree = ET.parse(path)
    except ET.ParseError:
        return []
    out = []
    for n in tree.iter():
        d = (n.get("content-desc") or "").strip()
        tx = (n.get("text") or "").strip()
        b = n.get("bounds") or ""
        m = re.match(r"\[(\d+),(\d+)\]\[(\d+),(\d+)\]", b)
        if not m:
            continue
        x1, y1, x2, y2 = map(int, m.groups())
        out.append({
            "desc": d, "text": tx, "cls": n.get("class", ""),
            "cx": (x1 + x2) // 2, "cy": (y1 + y2) // 2,
            "x1": x1, "y1": y1, "x2": x2, "y2": y2,
            "checked": n.get("checked"), "enabled": n.get("enabled"),
            "selected": n.get("selected"),
        })
    return out


def shot(name):
    os.makedirs(SHOTS, exist_ok=True)
    png = os.path.join(SHOTS, name + ".png")
    with open(png, "wb") as f:
        env = dict(os.environ)
        env["MSYS_NO_PATHCONV"] = "1"
        subprocess.run([ADB, "-s", SER, "exec-out", "screencap", "-p"],
                       stdout=f, timeout=90, env=env)
    dump(os.path.join(SHOTS, name + ".xml"))
    print("shot:", png, os.path.getsize(png))
    return png


def tap(x, y, wait=1.5):
    adb("shell", "input", "tap", str(x), str(y))
    time.sleep(wait)


def find(nodes, label, exact=False):
    for n in nodes:
        if exact:
            if n["desc"] == label or n["text"] == label:
                return n
        else:
            if label in n["desc"] or label in n["text"]:
                return n
    return None


def find_all(nodes, label):
    return [n for n in nodes if label in n["desc"] or label in n["text"]]


def tapf(label, wait=1.5, exact=False):
    n = find(dump(), label, exact)
    if not n:
        print("MISS:", label)
        return False
    tap(n["cx"], n["cy"], wait)
    print("TAP:", label, n["cx"], n["cy"])
    return True


def swipe(x1, y1, x2, y2, ms=500, wait=1.0):
    adb("shell", "input", "swipe", str(x1), str(y1), str(x2), str(y2), str(ms))
    time.sleep(wait)


def key(k, wait=1.5):
    adb("shell", "input", "keyevent", k)
    time.sleep(wait)


def state():
    nodes = dump()
    print("state dump, nodes=", len(nodes))
    for n in nodes:
        if n["desc"] or n["text"]:
            d = (n["desc"] or n["text"]).replace("\n", "\\n")
            if len(d) > 80:
                d = d[:80] + "..."
            print(f"  {n['cls'].split('.')[-1]:<18} ({n['cx']},{n['cy']}) [{n['x1']},{n['y1']},{n['x2']},{n['y2']}] {d!r}")
    return nodes


def pull_prefs(name):
    os.makedirs(PREFS, exist_ok=True)
    dst = os.path.join(PREFS, name + ".xml")
    adb("pull", PREFS_XML, dst)
    print("prefs:", dst, os.path.getsize(dst))
    return dst


def device_db(sql):
    out = adb("shell", f"sqlite3 {DB} \"{sql}\"")
    print(out)




def fill_name(new_name):
    """当前命名对话框：清空 EditText 并输入 new_name（ASCII 与中文均可）"""
    nodes = dump()
    edit = None
    for n in nodes:
        if n["cls"].endswith("EditText"):
            edit = n
            break
    if not edit:
        print("MISS: EditText")
        return False
    tap(edit["cx"], edit["cy"], 0.5)
    cur = edit["text"] or ""
    for _ in range(len(cur) + 2):
        adb("shell", "input", "keyevent", "67")
    adb("shell", "input", "text", new_name.replace(" ", "%s"))
    time.sleep(0.8)
    for n in dump():
        if n["cls"].endswith("EditText"):
            print("field now:", n["text"])
            return n["text"] == new_name
    return False



PUNCT = {
    "{": ["keycombination", "59", "71"],
    "}": ["keycombination", "59", "72"],
    '"': ["keycombination", "59", "75"],
    ":": ["keycombination", "59", "74"],
    ",": ["keyevent", "55"],
    "_": ["keycombination", "59", "69"],
    "-": ["keyevent", "69"],
    ".": ["keyevent", "56"],
}


def type_exact(text):
    """逐字符输入（支持 JSON 常用标点），先清空当前 EditText。"""
    nodes = dump()
    edit = next((n for n in nodes if n["cls"].endswith("EditText")), None)
    if not edit:
        print("MISS: EditText")
        return False
    tap(edit["cx"], edit["cy"], 0.4)
    for _ in range(len(edit["text"] or "") + 2):
        adb("shell", "input", "keyevent", "67")
    buf = ""
    for ch in text:
        if ch in PUNCT:
            if buf:
                adb("shell", "input", "text", buf)

                buf = ""
            adb("shell", "input", *PUNCT[ch])
        else:
            buf += ch
    if buf:
        adb("shell", "input", "text", buf)
    time.sleep(0.8)
    nodes = dump()
    edit = next((n for n in nodes if n["cls"].endswith("EditText")), None)
    print("field now:", edit["text"] if edit else None)
    return bool(edit and edit["text"] == text)

def main():
    cmd = sys.argv[1] if len(sys.argv) > 1 else "state"
    if cmd == "state":
        state()
    elif cmd == "shot":
        shot(sys.argv[2])
    elif cmd == "tap":
        tap(int(sys.argv[2]), int(sys.argv[3]),
            float(sys.argv[4]) if len(sys.argv) > 4 else 1.5)
    elif cmd == "tapf":
        exact = len(sys.argv) > 4 and sys.argv[4] == "exact"
        tapf(sys.argv[2], float(sys.argv[3]) if len(sys.argv) > 3 else 1.5, exact)
    elif cmd == "swipe":
        vals = [int(v) for v in sys.argv[2:6]]
        ms = int(sys.argv[6]) if len(sys.argv) > 6 else 500
        swipe(*vals, ms=ms)
    elif cmd == "key":
        key(sys.argv[2])
    elif cmd == "back":
        key("KEYCODE_BACK")
    elif cmd == "launch":
        adb("shell", "am", "start", "-n", f"{PKG}/{ACT}")
        time.sleep(5)
    elif cmd == "prefs":
        pull_prefs(sys.argv[2])
    elif cmd == "db":
        device_db(sys.argv[2])
    elif cmd == "name":
        fill_name(sys.argv[2])
    elif cmd == "typejson":
        type_exact(sys.argv[2])
    elif cmd == "wait":
        time.sleep(float(sys.argv[2]))
    else:
        print("unknown cmd", cmd)


if __name__ == "__main__":
    main()
