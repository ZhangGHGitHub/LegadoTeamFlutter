# -*- coding: utf-8 -*-
"""批37 设备验收 UI 驱动辅助（状态感知 + 截图/UI dump 取证）。

用法示例:
  python drive.py state                     # 打印当前界面关键元素 + 判定状态
  python drive.py shot <name>               # 截图 + dump 到 shots/<name>.png|xml
  python drive.py tap <x> <y>
  python drive.py swipe <x1> <y1> <x2> <y2> [ms]
  python drive.py menu                      # 确保阅读菜单可见
  python drive.py config                    # 打开顶栏按钮配置页（从阅读菜单）
  python drive.py close_all                 # 连续 BACK 直到回到阅读菜单
  python drive.py key <KEY>
"""
import os
import re
import subprocess
import sys
import time
import xml.etree.ElementTree as ET

ADB = r"D:\Android\platform-tools\adb.exe"
SER = "192.168.100.62:5555"
BASE = os.path.dirname(os.path.abspath(__file__))
SHOTS = os.path.join(BASE, "shots")
TMP = os.path.join(SHOTS, "_state.xml")


def adb(*args, timeout=60):
    r = subprocess.run([ADB, "-s", SER, *args], capture_output=True, text=True,
                       timeout=timeout, encoding="utf-8", errors="replace")
    return (r.stdout or "") + (r.stderr or "")


def dump(path=TMP):
    for attempt in range(3):
        adb("shell", "uiautomator dump /sdcard/u.xml")
        adb("pull", "/sdcard/u.xml", path)
        if os.path.exists(path) and os.path.getsize(path) > 100:
            try:
                ET.parse(path)
                break
            except ET.ParseError:
                time.sleep(1)
        time.sleep(1)
    try:
        t = ET.parse(path)
    except ET.ParseError:
        return []
    out = []
    for n in t.iter():
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
        })
    return out


def shot(name):
    png = os.path.join(SHOTS, name + ".png")
    with open(png, "wb") as f:
        subprocess.run([ADB, "-s", SER, "exec-out", "screencap", "-p"],
                       stdout=f, timeout=60)
    dump(os.path.join(SHOTS, name + ".xml"))
    return png


def tap(x, y, wait=1.5):
    adb("shell", "input", "tap", str(x), str(y))
    time.sleep(wait)


def swipe(x1, y1, x2, y2, ms=400, wait=1.0, wait_time=None):
    adb("shell", "input", "swipe", str(x1), str(y1), str(x2), str(y2), str(ms))
    time.sleep(wait_time if wait_time is not None else wait)


def key(k, wait=1.5):
    adb("shell", "input", "keyevent", k)
    time.sleep(wait)


def find(nodes, desc, exact=True):
    for n in nodes:
        d = n["desc"] or n["text"]
        if (d == desc) if exact else (desc in (n["desc"] or "") or desc in (n["text"] or "")):
            return n
    return None


def find_all(nodes, needle):
    return [n for n in nodes if needle in (n["desc"] or "") or needle in (n["text"] or "")]


def classify(nodes):
    """粗判当前界面状态"""
    if find(nodes, "退出阅读"):
        return "reader_menu"
    if find(nodes, "恢复默认"):
        return "config_sheet"
    if find_all(nodes, "共 ") or find(nodes, "已在书架") or find(nodes, "阅读"):
        if find(nodes, "Back") and find(nodes, "阅读"):
            return "book_info"
    if find(nodes, "阅读界面") or find_all(nodes, "简繁转换"):
        return "reader_settings"
    if find(nodes, "书架") and find_all(nodes, "Tab 2 of 5"):
        return "shelf"
    if find(nodes, "设置编码") or find(nodes, "全文搜索"):
        return "reader"
    return "unknown"


def state(verbose=True):
    nodes = dump()
    st = classify(nodes)
    if verbose:
        print("state:", st)
        for n in nodes:
            if n["desc"] or n["text"]:
                d = (n["desc"] or n["text"]).replace("\n", "\\n")
                if len(d) > 60:
                    d = d[:60] + "..."
                print(f"  {n['cls'].split('.')[-1]:<18} ({n['cx']},{n['cy']}) {d!r}")
    return st, nodes


def ensure_reader_menu(max_try=6):
    """把界面收敛到「阅读菜单可见」；失败返回 False"""
    for _ in range(max_try):
        nodes = dump()
        st = classify(nodes)
        if st == "reader_menu":
            return True
        if st == "config_sheet" or st == "reader_settings":
            key("KEYCODE_BACK")
            continue
        if st == "reader":
            tap(540, 960)
            continue
        if st == "book_info":
            n = find(nodes, "阅读")
            if n:
                tap(n["cx"], n["cy"], 4)
                continue
        if st == "shelf":
            return False
        key("KEYCODE_BACK")
    return classify(dump()) == "reader_menu"


def open_config():
    if not ensure_reader_menu():
        print("ERR: 无法回到阅读菜单")
        return False
    nodes = dump()
    s = find(nodes, "设置")
    if not s:
        print("ERR: 未找到设置按钮")
        return False
    tap(s["cx"], s["cy"], 2)
    nodes = dump()
    if classify(nodes) != "reader_settings":
        print("ERR: 设置面板未打开")
        return False
    # 更多 tab
    tab = find(nodes, "更多")
    if tab and tab["cy"] < 1000:
        tap(tab["cx"], tab["cy"], 2)
    for _ in range(6):
        nodes = dump()
        row = [n for n in nodes if (n["desc"] or "").startswith("顶栏按钮")]
        if row:
            r = row[0]
            if r["cy"] > 1700:
                swipe(540, 1500, 540, 1100, 400)
                continue
            tap(r["cx"], r["cy"], 3)
            nodes = dump()
            if classify(nodes) == "config_sheet":
                return True
            print("ERR: 配置页未打开")
            return False
        swipe(540, 1500, 540, 900, 400, wait_time=2.0)
    nodes = dump()
    row = [n for n in nodes if (n["desc"] or "").startswith("顶栏按钮")]
    if row:
        tap(row[0]["cx"], row[0]["cy"], 3)
        if classify(dump()) == "config_sheet":
            return True
    print("ERR: 未找到顶栏按钮入口")
    return False


def close_to_reader_menu():
    for _ in range(5):
        nodes = dump()
        st = classify(nodes)
        if st == "reader_menu":
            return True
        if st in ("config_sheet", "reader_settings"):
            key("KEYCODE_BACK")
            continue
        if st == "reader":
            tap(540, 960)
            continue
        return st == "reader_menu"
    return False


def config_rows(nodes):
    """配置页行：按动作池标签匹配，返回每行的开关/上移/下移状态"""
    labels = ["下载（离线缓存）", "刷新正文", "换源", "目录规则库（仅管理规则）",
              "设置编码", "目录", "全文搜索", "自动翻页", "朗读", "界面设置",
              "添加书签", "替换规则", "日/夜切换", "上一章", "下一章", "更多"]
    switches = [n for n in nodes if n["cls"].endswith("Switch")]
    out = []
    for n in nodes:
        d = n["desc"] or ""
        label = d.split(chr(10))[0]
        if label not in labels:
            continue
        if any(r["label"] == label and abs(r["y"] - n["cy"]) < 60 for r in out):
            continue
        near = [s for s in switches if abs(s["cy"] - n["cy"]) < 200]
        sw = min(near, key=lambda s: abs(s["cy"] - n["cy"])) if near else None
        ups = [b for b in nodes if b["desc"] == "上移" and abs(b["cy"] - n["cy"]) < 120]
        dns = [b for b in nodes if b["desc"] == "下移" and abs(b["cy"] - n["cy"]) < 120]
        out.append({
            "label": label, "y": n["cy"], "cx": n["cx"],
            "checked": sw["checked"] if sw else None,
            "sw_enabled": sw["enabled"] if sw else None,
            "sw_x": sw["cx"] if sw else None,
            "sw_y": sw["cy"] if sw else None,
            "up_ok": bool(ups) and ups[0]["enabled"] == "true",
            "down_ok": bool(dns) and dns[0]["enabled"] == "true",
            "up": (ups[0]["cx"], ups[0]["cy"]) if ups else None,
            "down": (dns[0]["cx"], dns[0]["cy"]) if dns else None,
        })
    return out


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else "state"
    if cmd == "state":
        state()
    elif cmd == "shot":
        print(shot(sys.argv[2]))
    elif cmd == "tap":
        tap(int(sys.argv[2]), int(sys.argv[3]))
    elif cmd == "swipe":
        swipe(*[int(a) for a in sys.argv[2:6]])
    elif cmd == "key":
        key(sys.argv[2])
    elif cmd == "menu":
        print("ok" if ensure_reader_menu() else "fail")
    elif cmd == "config":
        print("ok" if open_config() else "fail")
    elif cmd == "close_all":
        print("ok" if close_to_reader_menu() else "fail")
    else:
        print("unknown cmd")
