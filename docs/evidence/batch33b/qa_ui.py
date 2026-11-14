# -*- coding: utf-8 -*-
"""批33 设备验收 UI 辅助（adb 封装：dump / 查找 / 点击 / 文本 / 截图）。

用法（在仓库根目录）：
  python docs/evidence/batch33b/qa_ui.py dump --tag name
  python docs/evidence/batch33b/qa_ui.py find --tag name --contains 书源
  python docs/evidence/batch33b/qa_ui.py tap --tag name --contains 书源 [--index 0]
  python docs/evidence/batch33b/qa_ui.py tap-xy --x 100 --y 200
  python docs/evidence/batch33b/qa_ui.py text --value "abc"
  python docs/evidence/batch33b/qa_ui.py key --code KEYCODE_BACK
  python docs/evidence/batch33b/qa_ui.py shot --name home
  python docs/evidence/batch33b/qa_ui.py displays

说明：
- dump 落 docs/evidence/batch33/ui/<tag>.xml，并打印可读节点（content-desc / text / bounds）。
- Flutter 语义文本在 content-desc；text 属性多为空。
- 截图走 `exec-out screencap -p -d <display>`；display 由 `displays` 子命令探测
  （MuMu 可能把窗口挂在独立逻辑 display）。
"""
from __future__ import annotations

import argparse
import os
import re
import subprocess
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

ADB = r"D:\Android\platform-tools\adb.exe"
DEVICE = "192.168.100.63:5555"
ROOT = Path(__file__).resolve().parents[3]
OUT = ROOT / "docs" / "evidence" / "batch33b" / "ui"
OUT.mkdir(parents=True, exist_ok=True)
REMOTE = "/sdcard/b33_ui.xml"
DISPLAY = None  # None = 自动探测应用窗口所在逻辑 display
TOKEN = None  # 截图用 SF display token（auto 时由 dumpsys display 映射）


def sh(*args, timeout=40) -> subprocess.CompletedProcess:
    return subprocess.run(
        [ADB, "-s", DEVICE, *args], capture_output=True, timeout=timeout
    )


def shell(cmd: str, timeout=40) -> str:
    p = sh("shell", cmd, timeout=timeout)
    return p.stdout.decode("utf-8", "replace")


def detect_target():
    """探测应用窗口所在逻辑 display 与其 SF display token。"""
    out = shell("dumpsys window")
    cur = None
    disp = None
    for line in out.splitlines():
        m = re.search(r"Display: mDisplayId=(\d+)", line)
        if m:
            cur = m.group(1)
        if "mCurrentFocus=" in line and "io.legado.flutter_legado" in line:
            disp = cur
            break
    token = None
    dinfo = shell("dumpsys display")
    for line in dinfo.splitlines():
        if "mBaseDisplayInfo=DisplayInfo" not in line:
            continue
        m = re.search(r'displayId (\d+),.*?uniqueId "local:(\d+)"', line)
        if m and m.group(1) == disp:
            token = m.group(2)
            break
    return (disp or "0"), token


def resolve():
    global DISPLAY, TOKEN
    disp, token = detect_target()
    if DISPLAY is None:
        DISPLAY = int(disp)
    if TOKEN is None:
        TOKEN = token
    return DISPLAY, TOKEN


def dump(tag: str) -> Path:
    for _ in range(3):
        shell(f"rm -f {REMOTE}")
        shell(f"uiautomator dump {REMOTE}")
        local = OUT / f"{tag}.xml"
        p = sh("pull", REMOTE, str(local))
        if local.exists() and local.stat().st_size > 0:
            return local
    raise SystemExit("uiautomator dump 失败")


def nodes(path: Path):
    tree = ET.parse(path)
    out = []
    for n in tree.iter("node"):
        desc = (n.get("content-desc") or "").strip()
        text = (n.get("text") or "").strip()
        bounds = n.get("bounds") or ""
        if not desc and not text:
            continue
        m = re.match(r"\[(\d+),(\d+)\]\[(\d+),(\d+)\]", bounds)
        if not m:
            continue
        x1, y1, x2, y2 = map(int, m.groups())
        out.append(
            {
                "desc": desc,
                "text": text,
                "bounds": (x1, y1, x2, y2),
                "cx": (x1 + x2) // 2,
                "cy": (y1 + y2) // 2,
            }
        )
    return out


def cmd_dump(a):
    p = dump(a.tag)
    ns = nodes(p)
    print(f"# {p}  nodes={len(ns)}")
    for i, n in enumerate(ns):
        label = n["desc"] or n["text"]
        print(f"[{i}] {n['bounds']} {label[:160]}")


def cmd_find(a):
    p = dump(a.tag)
    ns = [n for n in nodes(p) if a.contains in (n["desc"] or n["text"])]
    print(f"matches={len(ns)}")
    for i, n in enumerate(ns):
        print(f"[{i}] {n['bounds']} {n['desc'] or n['text']}")


def cmd_tap(a):
    p = dump(a.tag)
    ns = [n for n in nodes(p) if a.contains in (n["desc"] or n["text"])]
    if not ns:
        raise SystemExit(f"未找到包含 {a.contains!r} 的节点")
    n = ns[min(a.index, len(ns) - 1)]
    print(f"tap {n['bounds']} {n['desc'] or n['text'][:60]}")
    shell(f"input -d {DISPLAY} tap {n['cx']} {n['cy']}")
    return n


def cmd_tap_xy(a):
    shell(f"input -d {DISPLAY} tap {a.x} {a.y}")
    print(f"tap ({a.x},{a.y})")


def cmd_text(a):
    # input text 不支持中文（实测可注入 UTF-8，但仍避免空格与非 ASCII）
    val = a.value.replace(" ", "%s")
    shell(f"input -d {DISPLAY} text '{val}'")
    print(f"text {a.value!r}")


def cmd_key(a):
    shell(f"input -d {DISPLAY} keyevent {a.code}")
    print(f"key {a.code}")


def cmd_shot(a):
    disp, token = resolve()
    png = OUT / (a.name + ".png")
    cmd = f"screencap -p -d {token}" if token else "screencap -p"
    with open(png, "wb") as fp:
        subprocess.run(
            [ADB, "-s", DEVICE, "exec-out", cmd],
            stdout=fp,
            stderr=subprocess.DEVNULL,
            timeout=60,
        )
    print(f"shot {png} ({png.stat().st_size} bytes) display={disp} token={token}")


def cmd_displays(a):
    print("== SurfaceFlinger --display-id ==")
    print(shell("dumpsys SurfaceFlinger --display-id 2>/dev/null | head -30"))
    print("== window displays ==")
    print(shell("dumpsys window displays 2>/dev/null | grep -E 'Display:|mDisplayId|init=' | head -20"))


def main() -> int:
    global DISPLAY, TOKEN
    ap = argparse.ArgumentParser()
    ap.add_argument("--display", type=int, default=None)
    ap.add_argument("--token", default=None)
    sub = ap.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("dump"); p.add_argument("--tag", required=True); p.set_defaults(fn=cmd_dump)
    p = sub.add_parser("find"); p.add_argument("--tag", required=True); p.add_argument("--contains", required=True); p.set_defaults(fn=cmd_find)
    p = sub.add_parser("tap"); p.add_argument("--tag", required=True); p.add_argument("--contains", required=True); p.add_argument("--index", type=int, default=0); p.set_defaults(fn=cmd_tap)
    p = sub.add_parser("tap-xy"); p.add_argument("--x", type=int, required=True); p.add_argument("--y", type=int, required=True); p.set_defaults(fn=cmd_tap_xy)
    p = sub.add_parser("text"); p.add_argument("--value", required=True); p.set_defaults(fn=cmd_text)
    p = sub.add_parser("key"); p.add_argument("--code", required=True); p.set_defaults(fn=cmd_key)
    p = sub.add_parser("shot"); p.add_argument("--name", required=True); p.set_defaults(fn=cmd_shot)
    p = sub.add_parser("displays"); p.set_defaults(fn=cmd_displays)

    a = ap.parse_args()
    DISPLAY = a.display
    TOKEN = a.token
    if a.fn is not cmd_displays:
        d, t = resolve()
        print(f"[target] display={d} token={t}")
    a.fn(a)
    return 0


if __name__ == "__main__":
    sys.exit(main())
