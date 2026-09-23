# -*- coding: utf-8 -*-
"""P29b（Test2=127.0.0.1:16384）adb 操作辅助：
- displays: 列出 logical display + surfaceflinger display 映射
- dump <out.xml>: uiautomator dump（当前焦点窗口）
- shot <out.png> [sfDisplayId]: screencap（不指定则默认 display）
- tap <x> <y> <logicalId>: input -d tap
- swipe <x1> <y1> <x2> <y2> <ms> <logicalId>
- text <x> <y> <logicalId>: 点击后输入
- key <KEY> <logicalId>
- logcat-clear / logcat-dump <out> [filter]
用法: python p29b_adb.py <cmd> [args...]
"""
import subprocess
import sys
import re

ADB = r"D:\Android\platform-tools\adb.exe"
DEV = "127.0.0.1:16384"
OUT_DIR = r"D:\OH-WorkSpace\LegadoTeam\legado\docs\parity_shots\verify_ui_20260922"


def sh(args, binary=False, timeout=120):
    r = subprocess.run([ADB, "-s", DEV] + args,
                       capture_output=True, timeout=timeout)
    if binary:
        return r.stdout
    return (r.stdout.decode("utf-8", "replace") +
            (r.stderr.decode("utf-8", "replace") if r.stderr else "")).strip()


def cmd_displays():
    out = sh(["shell", "dumpsys", "display"])
    logical = re.findall(r"mLogicalDisplayId=(\d+).*?mUniqueId=(\S+)", out, re.S)
    sf = re.findall(r"Display [\w.]+:\s*\n(?:.*\n)*?  mUniqueId=(\S+)", out)
    print("== logical displays ==")
    for line in out.splitlines():
        if "mLogicalDisplayInfo" in line or "Logical" in line:
            print(line.strip()[:200])
    print("== surfaceflinger displays ==")
    sf_out = sh(["shell", "dumpsys", "SurfaceFlinger", "--display-id"])
    print(sf_out)
    print("== app windows (window manager displays) ==")
    wm = sh(["shell", "dumpsys", "window"])
    for line in wm.splitlines():
        if "Display" in line and ("mCurrentFocus" in line or "mFocusedApp" in line):
            print(line.strip()[:200])


def cmd_dump(out_path):
    remote = "/sdcard/p29b_dump.xml"
    sh(["shell", "uiautomator", "dump", remote])
    data = sh(["pull", remote, out_path], binary=True)
    print(data)
    print(f"== dump saved: {out_path}")


def cmd_shot(out_path, sf_display=None):
    args = ["exec-out", "screencap", "-p"]
    if sf_display:
        args += ["-d", sf_display]
    data = sh(args, binary=True)
    if not data.startswith(b"\x89PNG"):
        print("ERROR: screencap 未返回 PNG:", data[:200])
        return
    with open(out_path, "wb") as f:
        f.write(data)
    print(f"== shot saved: {out_path} ({len(data)} bytes, sfDisplay={sf_display or 'default'})")


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return
    cmd = sys.argv[1]
    a = sys.argv[2:]
    if cmd == "displays":
        cmd_displays()
    elif cmd == "dump":
        cmd_dump(a[0])
    elif cmd == "shot":
        cmd_shot(a[0], a[1] if len(a) > 1 else None)
    elif cmd == "tap":
        print(sh(["shell", "input", "-d", a[2], "tap", a[0], a[1]]))
    elif cmd == "swipe":
        print(sh(["shell", "input", "-d", a[5], "swipe",
                  a[0], a[1], a[2], a[3], a[4]]))
    elif cmd == "key":
        print(sh(["shell", "input", "-d", a[1], "keyevent", a[0]]))
    elif cmd == "shell":
        print(sh(["shell"] + a))
    elif cmd == "logcat-clear":
        sh(["logcat", "-c"])
        print("logcat cleared")
    elif cmd == "logcat-dump":
        out = a[0]
        filt = a[1:]
        args = ["logcat", "-d"]
        if filt:
            args = ["logcat", "-d", "-s"] + [
                f for f in filt if not f.startswith("-t")]
        data = sh(args, timeout=180)
        with open(out, "w", encoding="utf-8") as f:
            f.write(data + "\n")
        print(f"== logcat saved: {out} ({len(data)} chars)")
    else:
        print(__doc__)


if __name__ == "__main__":
    main()
