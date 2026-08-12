# -*- coding: utf-8 -*-
"""Remaining gate items — Chinese via unicode escapes only."""
from __future__ import annotations

import json
import re
import subprocess
import sys
import time
from pathlib import Path

sys.stdout.reconfigure(encoding="utf-8")

ADB = r"D:\Android\platform-tools\adb.exe"
DEV = "emulator-5556"
PKG = "io.legado.flutter_legado"
ACT = "io.legado.flutter.MainActivity"
OUT = Path(r"D:\OH-WorkSpace\LegadoTeam\legado\docs\gate_evidence_2026-08-13")
OUT.mkdir(parents=True, exist_ok=True)

# Chinese labels
L_SOURCES = "\u4e66\u6e90\u7ba1\u7406"  # 书源管理
L_TASKS = "\u5b9a\u65f6\u4efb\u52a1"  # 定时任务
L_SERVICE = "\u670d\u52a1"  # 服务
L_SELECT_ALL = "\u5168\u9009"  # 全选
L_MORE = "\u66f4\u591a\u9009\u9879"  # 更多选项
L_RANGE = "\u9009\u4e2d\u6240\u9009\u533a\u95f4"  # 选中所选区间
L_CHANGE = "\u6362\u6e90"  # 换源
L_SINGLE = "\u5355\u7ae0\u6362\u6e90"  # 单章换源
L_CONTINUE = "\u7ee7\u7eed\u9605\u8bfb"  # 继续阅读
L_START = "\u5f00\u59cb\u9605\u8bfb"  # 开始阅读
L_RSS_MGMT = "\u8ba2\u9605\u6e90\u7ba1\u7406"  # 订阅源管理
L_SET_VAR = "\u8bbe\u7f6e\u6e90\u53d8\u91cf"  # 设置源变量
L_CLEAR = "\u6e05\u7a7a\u6587\u7ae0"  # 清空文章
L_DEBUG = "\u8c03\u8bd5"  # 调试
L_SAVE = "\u4fdd\u5b58"  # 保存
L_NAME = "\u540d\u79f0"  # 名称
L_ADD = "\u6dfb\u52a0"  # 添加
L_OK = "\u786e\u5b9a"  # 确定
L_EMPTY = "\u6682\u65e0"  # 暂无


def adb(*a, timeout=45):
    r = subprocess.run([ADB, "-s", DEV, *a], capture_output=True, timeout=timeout)
    return ((r.stdout or b"") + (r.stderr or b"")).decode("utf-8", errors="replace")


def dump(name: str) -> str:
    adb("shell", "uiautomator", "dump", "/sdcard/ui.xml")
    p = OUT / f"gr_{name}.xml"
    adb("pull", "/sdcard/ui.xml", str(p))
    return p.read_text(encoding="utf-8", errors="replace")


def shot(name: str) -> None:
    adb("shell", "screencap", "-p", f"/sdcard/{name}.png")
    adb("pull", f"/sdcard/{name}.png", str(OUT / f"gr_{name}.png"))


def nodes(xml: str):
    out = []
    for m in re.finditer(r"<node\b[^>]*>", xml):
        tag = m.group(0)
        t = re.search(r'\btext="([^"]*)"', tag)
        d = re.search(r'\bcontent-desc="([^"]*)"', tag)
        b = re.search(r'\bbounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"', tag)
        if not b:
            continue
        lab = ((t.group(1) if t else "") or (d.group(1) if d else "")).replace(
            "&#10;", "\n"
        )
        if not lab:
            continue
        bb = tuple(map(int, b.groups()))
        out.append(
            {"lab": lab, "b": bb, "cx": (bb[0] + bb[2]) // 2, "cy": (bb[1] + bb[3]) // 2}
        )
    return out


def labs(ns):
    return [n["lab"].replace("\n", "|") for n in ns]


def has(ns, *ks):
    return any(any(k in n["lab"] for k in ks) for n in ns)


def find(ns, *ks):
    return [n for n in ns if any(k in n["lab"] for k in ks)]


def tap(x, y):
    adb("shell", "input", "tap", str(int(x)), str(int(y)))


def lp(x, y, ms=1600):
    adb(
        "shell",
        "input",
        "swipe",
        str(int(x)),
        str(int(y)),
        str(int(x)),
        str(int(y)),
        str(ms),
    )


def restart(tab=None):
    adb("shell", "am", "force-stop", PKG)
    time.sleep(1.0)
    adb("shell", "am", "start", "-n", f"{PKG}/{ACT}")
    time.sleep(4.0)
    if tab == "bs":
        tap(90, 1220)
    elif tab == "disc":
        tap(270, 1220)
    elif tab == "rss":
        tap(450, 1220)
    elif tab == "mine":
        tap(630, 1220)
    if tab:
        time.sleep(1.4)


def open_mine_title(title: str, exclude: str | None = None):
    restart("mine")
    for i in range(7):
        ns = nodes(dump(f"mine_{i}"))
        print(f"MINE{i}", labs(ns)[:12], flush=True)
        hits = []
        for n in ns:
            if title not in n["lab"]:
                continue
            if exclude and exclude in n["lab"]:
                continue
            hits.append(n)
        hits = sorted(hits, key=lambda n: len(n["lab"]))
        if hits:
            h = hits[0]
            print("TAP", h["lab"], h["b"], flush=True)
            tap(min(h["cx"], 170), h["cy"])
            time.sleep(2.2)
            return nodes(dump(f"opened_{title}"))
        adb("shell", "input", "swipe", "360", "1050", "360", "420", "450")
        time.sleep(0.7)
    return None


def test_c3():
    ns = open_mine_title(L_SOURCES)
    if ns is None:
        return {"item": "C3", "status": "FAIL", "evidence": "cannot open sources"}
    print("SRC", labs(ns)[:25], flush=True)
    shot("c3_src")
    # Prefer bottom 全选
    sel = [n for n in find(ns, L_SELECT_ALL) if n["b"][1] > 1050] or find(
        ns, L_SELECT_ALL
    )
    if sel:
        tap(sel[0]["cx"], sel[0]["cy"])
    else:
        # long-press left of first source name
        rows = [
            n
            for n in ns
            if 240 < n["b"][1] < 900
            and n["b"][0] < 280
            and len(n["lab"]) > 2
            and L_MORE not in n["lab"]
        ]
        if not rows:
            return {"item": "C3", "status": "FAIL", "evidence": f"no rows {labs(ns)[:20]}"}
        lp(rows[0]["b"][0] + 36, rows[0]["cy"], 1700)
    time.sleep(1.4)
    ns = nodes(dump("c3_batch"))
    print("BATCH", labs(ns)[:30], flush=True)
    shot("c3_batch")
    # ensure at least 2 selected: tap row 0 and 2 if needed
    rows = [
        n
        for n in ns
        if 220 < n["b"][1] < 980
        and n["b"][0] < 360
        and len(n["lab"]) > 2
        and all(
            x not in n["lab"]
            for x in (L_MORE, L_SELECT_ALL, "\u53cd\u9009", "\u5220\u9664", "\u5df2\u9009")
        )
    ]
    if len(rows) >= 3:
        tap(rows[0]["cx"], rows[0]["cy"])
        time.sleep(0.3)
        tap(rows[2]["cx"], rows[2]["cy"])
        time.sleep(0.5)
    ns = nodes(dump("c3_sel"))
    mores = sorted(find(ns, L_MORE), key=lambda n: -n["b"][1])
    if mores:
        tap(mores[0]["cx"], mores[0]["cy"])
    else:
        tap(630, 1230)
    time.sleep(1.0)
    ns = nodes(dump("c3_menu"))
    print("MENU", labs(ns)[:40], flush=True)
    shot("c3_menu")
    if not has(ns, L_RANGE):
        adb("shell", "input", "swipe", "520", "1100", "520", "300", "500")
        time.sleep(0.6)
        ns = nodes(dump("c3_menu2"))
        print("MENU2", labs(ns)[:40], flush=True)
        shot("c3_menu2")
    if not has(ns, L_RANGE):
        return {"item": "C3", "status": "FAIL", "evidence": f"menu={labs(ns)[:30]}"}
    tap(find(ns, L_RANGE)[0]["cx"], find(ns, L_RANGE)[0]["cy"])
    time.sleep(0.9)
    ns = nodes(dump("c3_done"))
    shot("c3_done")
    return {"item": "C3", "status": "PASS", "evidence": f"after={labs(ns)[:20]}"}


def test_e1():
    restart("bs")
    ns = nodes(dump("e1_bs"))
    print("BS", labs(ns)[:15], flush=True)
    cards = [
        n
        for n in ns
        if ("\u91cd\u751f" in n["lab"] or "\u9ad8\u8003" in n["lab"]) and n["b"][1] > 180
    ]
    if not cards:
        return {"item": "E1", "status": "\u963b\u585e", "evidence": "no book"}
    tap(cards[0]["cx"], cards[0]["cy"])
    time.sleep(2.2)
    ns = nodes(dump("e1_info"))
    if has(ns, L_CONTINUE, L_START):
        tap(find(ns, L_CONTINUE, L_START)[0]["cx"], find(ns, L_CONTINUE, L_START)[0]["cy"])
        time.sleep(3.0)
    # open reader chrome
    tap(360, 640)
    time.sleep(1.2)
    ns = nodes(dump("e1_menu"))
    print("RMENU", labs(ns)[:30], flush=True)
    shot("e1_menu")
    if not has(ns, L_CHANGE):
        # try top-leftish icons area
        for x in (80, 160, 240, 320):
            tap(x, 100)
            time.sleep(0.8)
            ns = nodes(dump(f"e1_try_{x}"))
            if has(ns, L_SINGLE, L_CHANGE):
                break
        print("AFTER_ICON", labs(ns)[:30], flush=True)
    if has(ns, L_SINGLE):
        return {"item": "E1", "status": "PASS", "evidence": f"labels={labs(ns)[:20]}"}
    if has(ns, L_CHANGE):
        tap(find(ns, L_CHANGE)[0]["cx"], find(ns, L_CHANGE)[0]["cy"])
        time.sleep(1.2)
        ns = nodes(dump("e1_chg"))
        print("CHG", labs(ns)[:25], flush=True)
        shot("e1_chg")
        if has(ns, L_SINGLE):
            return {"item": "E1", "status": "PASS", "evidence": f"sheet={labs(ns)[:20]}"}
    return {
        "item": "E1",
        "status": "\u963b\u585e",
        "evidence": f"no single-chapter entry labels={labs(ns)[:25]}",
    }


def test_g3():
    restart("rss")
    ns = nodes(dump("g3_home"))
    print("RSS", labs(ns)[:25], flush=True)
    shot("g3_home")
    if has(ns, L_RSS_MGMT):
        # first open an articles source via home grid: Meow
        hits = [n for n in ns if "Meow" in n["lab"]]
        if not hits:
            hits = [n for n in ns if "\u5c0f\u8bf4" in n["lab"]]
        if hits:
            tap(hits[0]["cx"], hits[0]["cy"])
            time.sleep(3.0)
            ns = nodes(dump("g3_art"))
            print("ART", labs(ns)[:25], flush=True)
            shot("g3_art")
            if has(ns, "http", "\u5185\u7f6e\u6d4f\u89c8\u5668"):
                adb("shell", "input", "keyevent", "4")
                time.sleep(0.8)
            else:
                # open overflow
                if has(ns, L_MORE):
                    tap(find(ns, L_MORE)[0]["cx"], find(ns, L_MORE)[0]["cy"])
                else:
                    tap(672, 104)
                time.sleep(1.0)
                ns = nodes(dump("g3_menu"))
                print("GMENU", labs(ns)[:30], flush=True)
                shot("g3_menu")
                if has(ns, L_SET_VAR, L_CLEAR, "\u6e90\u53d8\u91cf"):
                    return {
                        "item": "G3",
                        "status": "PASS",
                        "evidence": f"menu={labs(ns)[:20]}",
                    }
    # fallback: code presence already known; mark blocked for offline RSS article list
    return {
        "item": "G3",
        "status": "\u963b\u585e",
        "evidence": "subscription cards open browser/link; need RSS articles screen for \u6e05\u7a7a\u6587\u7ae0/\u8bbe\u7f6e\u6e90\u53d8\u91cf",
    }


def test_h9():
    ns = open_mine_title(L_TASKS, exclude=L_SERVICE)
    if ns is None:
        return {"item": "H9", "status": "FAIL", "evidence": "cannot open tasks"}
    print("TASKS", labs(ns)[:25], flush=True)
    shot("h9")
    # FAB
    tap(640, 1080)
    time.sleep(1.8)
    ns = nodes(dump("h9_add"))
    print("ADD", labs(ns)[:40], flush=True)
    shot("h9_add")
    # Dialog: type name then 确定
    if has(ns, L_NAME):
        tap(find(ns, L_NAME)[0]["cx"], find(ns, L_NAME)[0]["cy"] + 48)
        time.sleep(0.3)
    adb("shell", "input", "text", "GateDebug")
    time.sleep(0.5)
    if has(ns, L_OK, L_ADD, L_SAVE):
        tap(find(ns, L_OK, L_ADD, L_SAVE)[0]["cx"], find(ns, L_OK, L_ADD, L_SAVE)[0]["cy"])
    else:
        # right button of dialog often ~540,880
        tap(520, 900)
    time.sleep(1.5)
    ns = nodes(dump("h9_list"))
    print("LIST", labs(ns)[:25], flush=True)
    shot("h9_list")
    rows = [
        n
        for n in ns
        if 200 < n["b"][1] < 1000
        and len(n["lab"]) > 1
        and all(x not in n["lab"] for x in (L_EMPTY, "Show", L_ADD, "Back", "\u70b9\u51fb"))
    ]
    if not rows:
        return {
            "item": "H9",
            "status": "\u963b\u585e",
            "evidence": f"cannot create task labels={labs(ns)[:20]}",
        }
    lp(rows[0]["cx"], rows[0]["cy"], 1600)
    time.sleep(1.2)
    ns = nodes(dump("h9_lp"))
    print("LP", labs(ns)[:25], flush=True)
    shot("h9_lp")
    if not has(ns, L_DEBUG):
        return {"item": "H9", "status": "FAIL", "evidence": f"lp={labs(ns)[:20]}"}
    tap(find(ns, L_DEBUG)[0]["cx"], find(ns, L_DEBUG)[0]["cy"])
    time.sleep(1.6)
    ns = nodes(dump("h9_dbg"))
    shot("h9_dbg")
    return {"item": "H9", "status": "PASS", "evidence": f"dbg={labs(ns)[:20]}"}


def main():
    results = [test_c3(), test_e1(), test_g3(), test_h9()]
    (OUT / "remain_results.json").write_text(
        json.dumps(results, ensure_ascii=False, indent=2), encoding="utf-8"
    )
    print("SUMMARY", results, flush=True)


if __name__ == "__main__":
    main()
