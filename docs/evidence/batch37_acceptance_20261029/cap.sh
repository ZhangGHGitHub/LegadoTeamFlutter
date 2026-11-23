#!/bin/bash
# 用法: ./cap.sh <name>  —— 截图 + UI dump
export PATH="/d/Android/platform-tools:$PATH"
export MSYS_NO_PATHCONV=1
D=192.168.100.62:5555
E="D:/OH-WorkSpace/LegadoTeam/legado/tmp_debug/device_acceptance_20261029_batch37"
NAME=$1
adb -s $D exec-out screencap -p > "$E/shots/$NAME.png" 2>/dev/null
adb -s $D shell "uiautomator dump /sdcard/ui_dump.xml" >/dev/null 2>&1
adb -s $D pull /sdcard/ui_dump.xml "$E/shots/$NAME.xml" >/dev/null 2>&1
echo "saved $NAME.png $(stat -c%s "$E/shots/$NAME.png" 2>/dev/null) bytes"
