#!/usr/bin/env bash
# p29b_catch_visual.sh <baseline_cached_at>
# 轮询 DB cached_chapters.cached_at；变化（=换源 reload 完成）瞬间
# 连拍 6 张截图（~4-6s，覆盖 4s 结果 SnackBar 窗口）+ 4 帧 uiautomator dump。
BASE="$1"
ADB="D:/Android/platform-tools/adb.exe"
DEV="127.0.0.1:16384"
DIR="D:/OH-WorkSpace/LegadoTeam/legado/docs/parity_shots/verify_ui_20260922"
SQL="$DIR/p29b_q_cc.sql"
SF="4619827820427265280"
i=0
while true; do
  i=$((i+1))
  CUR=$("$ADB" -s "$DEV" shell 'run-as io.legado.flutter_legado sqlite3 app_flutter/legado.db' < "$SQL" 2>/dev/null | tr -d '\r' | tr -d ' ')
  if [ -n "$CUR" ] && [ "$CUR" != "$BASE" ]; then
    echo "DETECTED: cached_at $BASE -> $CUR at $(date +%H:%M:%S) (poll #$i)"
    for k in 1 2 3 4 5 6; do
      python "$DIR/p29b_adb.py" shot "$DIR/p29b_scv_${k}.png" "$SF" >/dev/null 2>&1
    done
    for k in 1 2 3 4; do
      python "$DIR/p29b_adb.py" dump "$DIR/p29b_scvd_${k}.xml" >/dev/null 2>&1
    done
    echo "VISUAL_CAPTURE_DONE"
    break
  fi
  sleep 1
done
