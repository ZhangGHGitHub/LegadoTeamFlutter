#!/usr/bin/env python
"""Open the 首页与导航 sheet from the main screen (own QA automation)."""
import sys

sys.path.insert(0, r"D:\OH-WorkSpace\LegadoTeam\legado\tmp_debug\device_acceptance_20261103_batch2b2a\scripts")
import ui  # noqa: E402


def tap_node(n, wait=0.6):
    x, y = ui.center(n)
    ui.adb(["shell", "input", "tap", str(x), str(y)])
    import time
    time.sleep(wait)


def swipe(x1, y1, x2, y2, ms=600, wait=0.5):
    ui.adb(["shell", "input", "swipe", str(x1), str(y1), str(x2), str(y2), str(ms)])
    import time
    time.sleep(wait)


def main():
    # 1) go to My tab (label starts with 我的 and contains Tab)
    nodes, _ = ui.dump("ns_step1")
    mytab = None
    for n in nodes:
        v = ui.label(n)
        if v.startswith("我的") and "Tab" in v:
            mytab = n
            break
    if not mytab:
        for n in nodes:
            v = ui.label(n)
            if v == "我的" and n["y1"] > 1500:
                mytab = n
                break
    if mytab:
        tap_node(mytab, 0.9)
    # 2) scroll My page to bottom / find settings tile
    target = None
    for _ in range(4):
        nodes, _ = ui.dump("ns_step2")
        target = ui.find(nodes, "外观 / 高级")
        if target:
            break
        swipe(540, 1400, 540, 400, 700, 0.5)
    if not target:
        print("FAIL: settings tile not found")
        return 2
    tap_node(target, 1.1)
    # 3) appearance tile
    nodes, _ = ui.dump("ns_step3")
    tile = ui.find(nodes, "主题配色与显示模式")
    if not tile:
        print("FAIL: appearance tile not found")
        return 3
    tap_node(tile, 1.1)
    # 4) scroll appearance to 主界面
    for _ in range(4):
        swipe(540, 1400, 540, 600, 250, 0.35)
    for _ in range(2):
        swipe(540, 500, 540, 1400, 350, 0.45)
    swipe(540, 600, 540, 1000, 300, 0.5)
    entry = None
    for i in range(14):
        nodes, _ = ui.dump("ns_step4")
        cand = [n for n in nodes if "设置首页、发现、订阅" in ui.label(n)]
        if cand:
            entry = cand[0]
            break
        labels = [ui.label(n) for n in nodes]
        main_hdr = next((n for n in nodes if ui.label(n) == "主界面"), None)
        below = any(
            k in " ".join(labels)
            for k in ("容器设置", "护眼模式", "模糊效果", "自定义主题", "书籍详情页")
        )
        above = any(
            k in " ".join(labels)
            for k in ("主题模式", "主题引擎", "配色风格")
        )
        if main_hdr and main_hdr["y1"] < 400:
            swipe(800, 400, 800, 900, 400, 0.6)  # content down, reveal below
            swipe(540, 700, 540, 500, 400, 0.5)
        elif main_hdr and main_hdr["y1"] > 1500:
            swipe(540, 1300, 540, 500, 500, 0.6)
        elif below:
            swipe(540, 500, 540, 1300, 500, 0.6)
        elif above:
            swipe(540, 1300, 540, 500, 500, 0.6)
        else:
            swipe(540, 900, 540, 600, 400, 0.5)
    if not entry:
        print("FAIL: nav entry not found")
        return 4
    tap_node(entry, 1.0)
    nodes, _ = ui.dump("ns_step5")
    header = [n for n in nodes if ui.label(n) == "首页与导航"]
    if not header:
        print("FAIL: sheet did not open")
        return 5
    print("OK: nav sheet open")
    return 0


if __name__ == "__main__":
    sys.exit(main())
