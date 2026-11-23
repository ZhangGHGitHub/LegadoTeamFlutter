#!/usr/bin/env bash
# UI 取证助手：dump 当前界面层级并输出紧凑节点表
# 用法: ./ui.sh <标签>
# 说明：MuMu 上 uiautomator dump 写入成功后进程常自杀（非零退出），以产物为准。
set -uo pipefail
cd "$(dirname "$0")"
TAG="${1:-ui}"
export PATH="/d/Program Files/MuMuPlayer/nx_main:$PATH"
export MSYS_NO_PATHCONV=1
SERIAL=192.168.100.62:5555
XML_WIN="D:\\OH-WorkSpace\\LegadoTeam\\legado\\tmp_debug\\device_acceptance_20261027_backup_pwd\\screens\\${TAG}.xml"

adb -s "$SERIAL" shell "uiautomator dump --compressed /sdcard/window.xml" >/dev/null 2>&1
adb -s "$SERIAL" pull /sdcard/window.xml "$XML_WIN" >/dev/null 2>&1
python parse_ui.py "screens/${TAG}.xml"
