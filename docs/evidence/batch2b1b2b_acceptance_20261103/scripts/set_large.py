# -*- coding: utf-8 -*-
"""设置大容器日间背景图（root 直接落盘 + 重启），用于 .9/大图设备验收。"""
import hashlib
import os
import re
import subprocess
import sys
import time

ADB = r"D:\Program Files\MuMuPlayer\nx_main\adb.exe"
SERIAL = "192.168.100.62:5555"
PKG = "io.legado.flutter_legado"
PREFS = f"/data/data/{PKG}/shared_prefs/FlutterSharedPreferences.xml"
BASE = r"D:\OH-WorkSpace\LegadoTeam\legado\tmp_debug\device_acceptance_20261103_batch2b1b2b"
FIX = os.path.join(BASE, "fixtures")


def adb(*args, timeout=120, check=False):
    r = subprocess.run([ADB, "-s", SERIAL, *args], capture_output=True, timeout=timeout)
    if check and r.returncode != 0:
        raise SystemExit(r.stderr.decode("utf-8", "replace"))
    return r


def sh(cmd, **kw):
    return adb("shell", cmd, **kw)


def set_large(name, restart=True):
    src = os.path.join(FIX, name)
    data = open(src, "rb").read()
    md5 = hashlib.md5(data).hexdigest()
    if name.lower().endswith(".9.png"):
        ext = ".9.png"
    else:
        ext = os.path.splitext(name)[1].lower()
    store = f"{md5}{ext}"
    dest = f"/data/data/{PKG}/files/theme_backgrounds/large_light/{store}"
    sh(f"mkdir -p /data/data/{PKG}/files/theme_backgrounds/large_light")
    # 先清理槽位旧图（仅本批自有命名）
    sh(f"rm -f /data/data/{PKG}/files/theme_backgrounds/large_light/*")
    with open(src, "rb") as f:
        p = subprocess.run([ADB, "-s", SERIAL, "push", src, f"/data/local/tmp/qa_large{ext}"],
                           capture_output=True, timeout=120)
    sh(f"cp /data/local/tmp/qa_large{ext} {dest}; chown 10066:10066 {dest}; "
       f"chmod 600 {dest}; rm -f /data/local/tmp/qa_large{ext}")
    rel = f"theme_backgrounds/large_light/{store}"
    sh(f"sed -i 's#<string name=\"flutter.largeContainerBackgroundImageLight\">.*</string>#"
       f"<string name=\"flutter.largeContainerBackgroundImageLight\">{rel}</string>#' {PREFS}")
    got = sh(f"grep largeContainerBackgroundImageLight {PREFS}").stdout.decode("utf-8", "replace")
    if rel not in got:
        raise SystemExit("偏好写入失败: " + got)
    if restart:
        sh(f"am force-stop {PKG}")
        time.sleep(0.8)
        sh(f"am start -W -n {PKG}/io.legado.flutter.MainActivity")
        time.sleep(3.0)
        # 进入「我的」页（容器图在 IosGroup 上渲染）
        sh("input tap 972 1800")
        time.sleep(1.2)
    print("set", name, "->", rel, "md5", md5, "bytes", len(data))


def set_item(name, restart=True, clear_large=True):
    src = os.path.join(FIX, name)
    data = open(src, "rb").read()
    md5 = hashlib.md5(data).hexdigest()
    ext = ".9.png" if name.lower().endswith(".9.png") else os.path.splitext(name)[1].lower()
    store = f"{md5}{ext}"
    dest = f"/data/data/{PKG}/files/theme_backgrounds/item_light/{store}"
    sh(f"mkdir -p /data/data/{PKG}/files/theme_backgrounds/item_light; "
       f"rm -f /data/data/{PKG}/files/theme_backgrounds/item_light/*")
    with open(src, "rb") as f:
        subprocess.run([ADB, "-s", SERIAL, "push", src, f"/data/local/tmp/qa_item{ext}"],
                       capture_output=True, timeout=120)
    sh(f"cp /data/local/tmp/qa_item{ext} {dest}; chown 10066:10066 {dest}; "
       f"chmod 600 {dest}; rm -f /data/local/tmp/qa_item{ext}")
    rel = f"theme_backgrounds/item_light/{store}"
    sh(f"sed -i 's#<string name=\"flutter.itemBackgroundImageLight\">.*</string>#"
       f"<string name=\"flutter.itemBackgroundImageLight\">{rel}</string>#' {PREFS}")
    if b"itemBackgroundImageLight" not in sh(f"grep itemBackgroundImageLight {PREFS}").stdout:
        sh(f"sed -i 's#</map>#    <string name=\"flutter.itemBackgroundImageLight\">{rel}</string>\n</map>#' {PREFS}")
    if clear_large:
        sh(f"sed -i 's#<string name=\"flutter.largeContainerBackgroundImageLight\">.*</string>#"
           f"<string name=\"flutter.largeContainerBackgroundImageLight\"></string>#' {PREFS}")
    if restart:
        sh(f"am force-stop {PKG}")
        time.sleep(0.8)
        sh(f"am start -W -n {PKG}/io.legado.flutter.MainActivity")
        time.sleep(3.0)
        sh("input tap 972 1800")
        time.sleep(1.2)
    print("set item", name, "->", rel, "md5", md5)


if __name__ == "__main__":
    if sys.argv[1] == "item":
        set_item(sys.argv[2])
    else:
        set_large(sys.argv[1])
