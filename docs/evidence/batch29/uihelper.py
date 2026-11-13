# -*- coding: utf-8 -*-
"""批29 UI 自动化小工具（uiautomator dump + input -d <logical display>）。

用法：
  python uihelper.py dump [--grep 关键词]
  python uihelper.py tap "文本或content-desc" [--index 0]
  python uihelper.py tapxy X Y
  python uihelper.py input "ASCII文本"
  python uihelper.py key back|home|enter
  python uihelper.py shot 输出文件.png

环境：DEVICE（默认 192.168.100.63:5555）、DISPLAY_ID（逻辑 display，默认 43）
"""
import os
import re
import subprocess
import sys

ADB = r"D:\Android\platform-tools\adb.exe"
DEVICE = os.environ.get("DEVICE", "192.168.100.63:5555")
DISPLAY_ID = os.environ.get("DISPLAY_ID", "43")
TMP_XML = "/sdcard/qa29_ui.xml"


def adb(*args, check=False):
    cmd = [ADB, "-s", DEVICE] + list(args)
    res = subprocess.run(cmd, capture_output=True, text=True, encoding="utf-8", errors="replace")
    if check and res.returncode != 0:
        raise SystemExit("adb failed: %s\n%s" % (" ".join(cmd), res.stderr))
    return res.stdout or ""


def dump_xml():
    adb("shell", "uiautomator dump --display %s %s" % (DISPLAY_ID, TMP_XML))
    # 用 base64 传输避免 Windows 换行/路径问题
    import base64

    b64 = adb("exec-out", "cat %s | base64" % TMP_XML).strip()
    raw = base64.b64decode("".join(b64.split()))
    return raw.decode("utf-8", "replace")


def nodes(xml):
    out = []
    for m in re.finditer(r"<node\b[^>]*>", xml):
        tag = m.group(0)
        attrs = dict(re.findall(r'([\w-]+)="([^"]*)"', tag))
        bounds = attrs.get("bounds", "")
        mm = re.match(r"\[(\d+),(\d+)\]\[(\d+),(\d+)\]", bounds)
        if not mm:
            continue
        x1, y1, x2, y2 = map(int, mm.groups())
        out.append(
            {
                "text": attrs.get("text", ""),
                "desc": attrs.get("content-desc", ""),
                "cls": attrs.get("class", ""),
                "clickable": attrs.get("clickable", "false") == "true",
                "cx": (x1 + x2) // 2,
                "cy": (y1 + y2) // 2,
                "bounds": bounds,
            }
        )
    return out


def cmd_dump(argv):
    xml = dump_xml()
    ns = nodes(xml)
    grep = None
    if "--grep" in argv:
        grep = argv[argv.index("--grep") + 1]
    for n in ns:
        label = (n["text"] or n["desc"]).strip()
        if not label:
            continue
        if grep and grep not in label:
            continue
        print("%s | text=%r desc=%r clickable=%s bounds=%s"
              % (n["cls"].split(".")[-1], n["text"], n["desc"], n["clickable"], n["bounds"]))


def cmd_tap(argv):
    target = argv[0]
    idx = int(argv[argv.index("--index") + 1]) if "--index" in argv else 0
    ns = nodes(dump_xml())
    hits = [n for n in ns if (n["text"] or n["desc"]).strip() == target]
    if not hits:
        hits = [n for n in ns if target in (n["text"] + "|" + n["desc"])]
    if not hits:
        raise SystemExit("NOT FOUND: %s" % target)
    n = hits[idx]
    adb("shell", "input -d %s tap %d %d" % (DISPLAY_ID, n["cx"], n["cy"]))
    print("TAPPED %s at (%d,%d) text=%r desc=%r" % (target, n["cx"], n["cy"], n["text"], n["desc"]))


def cmd_tapxy(argv):
    x, y = int(argv[0]), int(argv[1])
    adb("shell", "input -d %s tap %d %d" % (DISPLAY_ID, x, y))
    print("TAPPED (%d,%d)" % (x, y))


def cmd_input(argv):
    text = argv[0]
    # adb input text 不支持空格与特殊字符；空格用 %s
    safe = text.replace(" ", "%s")
    adb("shell", "input -d %s text '%s'" % (DISPLAY_ID, safe))
    print("INPUT %r" % text)


def cmd_key(argv):
    key = argv[0]
    adb("shell", "input -d %s keyevent KEYCODE_%s" % (DISPLAY_ID, key.upper()))
    print("KEY %s" % key)


def cmd_shot(argv):
    out = argv[0]
    token = adb("shell", "dumpsys SurfaceFlinger --display-id").strip()
    # 通过 dumpsys display 找 DISPLAY_ID 对应的 physical uniqueId
    dump = adb("shell", "dumpsys display")
    m = re.search(r'uniqueId="local:(\d+)"[^\n]*displayId %s,' % DISPLAY_ID, dump)
    if not m:
        m = re.search(r'displayId %s,[^\n]*uniqueId "local:(\d+)"' % DISPLAY_ID, dump)
    if not m:
        raise SystemExit("无法定位 display %s 的 physical id" % DISPLAY_ID)
    phys = m.group(1)
    adb("shell", "screencap -p -d %s /sdcard/qa29_shot.png" % phys)
    data = subprocess.run(
        [ADB, "-s", DEVICE, "exec-out", "cat /sdcard/qa29_shot.png"],
        capture_output=True,
    ).stdout
    with open(out, "wb") as f:
        f.write(data)
    print("SHOT %s (%d bytes, phys=%s)" % (out, len(data), phys))


def main():
    if len(sys.argv) < 2:
        raise SystemExit(__doc__)
    cmd, argv = sys.argv[1], sys.argv[2:]
    {
        "dump": cmd_dump,
        "tap": cmd_tap,
        "tapxy": cmd_tapxy,
        "input": cmd_input,
        "key": cmd_key,
        "shot": cmd_shot,
    }[cmd](argv)


if __name__ == "__main__":
    main()
