#!/bin/bash
# usage: shot.sh <name>
ADB="D:/Program Files/MuMuPlayer/nx_main/adb.exe"
D=192.168.100.62:5555
OUT="D:/OH-WorkSpace/LegadoTeam/legado/docs/materials_1101f"
"$ADB" -s $D exec-out screencap -p > "$OUT/$1.png"
echo "$OUT/$1.png"
