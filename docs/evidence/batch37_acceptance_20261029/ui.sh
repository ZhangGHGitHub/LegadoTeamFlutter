#!/bin/bash
# 用法: ./ui.sh <命令...>  在设备执行 adb shell 命令
export PATH="/d/Android/platform-tools:$PATH"
export MSYS_NO_PATHCONV=1
adb -s 192.168.100.62:5555 shell "$@"
