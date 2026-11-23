#!/usr/bin/env python
"""Open Appearance page from main screen and optionally toggle a switch by title."""
import sys
import time

sys.path.insert(0, r"D:\OH-WorkSpace\LegadoTeam\legado\tmp_debug\device_acceptance_20261103_batch2b2a\scripts")
import ui  # noqa: E402


def tap_node(n, wait=0.6):
    x, y = ui.center(n)
    ui.adb(["shell", "input", "tap", str(x), str(y)])
    time.sleep(wait)


def swipe(x1, y1, x2, y2, ms=600, wait=0.5):
    ui.adb(["shell", "input", "swipe", str(x1), str(y1), str(x2), str(y2), str(ms)])
    time.sleep(wait)


def open_appearance():
    nodes, _ = ui.dump("oa_step1")
    mytab = next((n for n in nodes if ui.label(n).startswith("我的") and "Tab" in ui.label(n)), None)
    if mytab:
        tap_node(mytab, 0.9)
    target = None
    for _ in range(4):
        nodes, _ = ui.dump("oa_step2")
        target = ui.find(nodes, "外观 / 高级")
        if target:
            break
        swipe(540, 1400, 540, 400, 700, 0.5)
    if not target:
        print("FAIL: settings tile")
        return False
    tap_node(target, 1.1)
    nodes, _ = ui.dump("oa_step3")
    tile = ui.find(nodes, "主题配色与显示模式")
    if not tile:
        print("FAIL: appearance tile")
        return False
    tap_node(tile, 1.2)
    return True


def find_scroll(needle, direction=1, tries=10, name="oa_find"):
    """Scroll until node label contains needle. direction 1=down page."""
    for i in range(tries):
        nodes, _ = ui.dump(name)
        hit = ui.find(nodes, needle)
        if hit:
            return hit, nodes
        if direction > 0:
            swipe(540, 1400, 540, 600, 300, 0.45)
        else:
            swipe(540, 600, 540, 1400, 300, 0.45)
    return None, []


def main():
    if not open_appearance():
        return 2
    needle = sys.argv[1] if len(sys.argv) > 1 else None
    if needle:
        n, nodes = find_scroll(needle, 1, 10, "oa_target")
        if not n:
            print("NOT FOUND:", needle)
            return 3
        print("FOUND:", repr(ui.label(n)), n["x1"], n["y1"], n["x2"], n["y2"])
        return 0
    nodes, _ = ui.dump("oa_final")
    for n in nodes:
        v = ui.label(n)
        if v:
            print(repr(v), n["y1"], n["y2"])
    return 0


if __name__ == "__main__":
    sys.exit(main())
