#!/usr/bin/env python
"""Close nav sheet (and appearance/settings pages) back to main screen."""
import sys
import time

sys.path.insert(0, r"D:\OH-WorkSpace\LegadoTeam\legado\tmp_debug\device_acceptance_20261103_batch2b2a\scripts")
import ui  # noqa: E402


def main():
    nodes, _ = ui.dump("close_step1")
    n = ui.find(nodes, "关闭", exact=True)
    if n:
        x, y = ui.center(n)
        ui.adb(["shell", "input", "tap", str(x), str(y)])
        time.sleep(0.7)
    ui.adb(["shell", "input", "keyevent", "4"])
    time.sleep(0.6)
    ui.adb(["shell", "input", "keyevent", "4"])
    time.sleep(0.9)
    nodes, _ = ui.dump("close_step2")
    tabs = [ui.label(x) for x in nodes if "Tab" in ui.label(x)]
    if not tabs:
        names = {"首页", "书架", "发现", "订阅", "我的"}
        tabs = [ui.label(x) for x in nodes if ui.label(x) in names and x["y1"] > 1500]
    print("tabs:", tabs)
    return 0 if tabs else 1


if __name__ == "__main__":
    sys.exit(main())
