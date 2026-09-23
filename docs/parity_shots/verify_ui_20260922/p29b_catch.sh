#!/usr/bin/env bash
# p29b_catch.sh <baseline_cached_at>
# 轮询 DB cached_chapters.cached_at；变化（=换源 reload 完成）时立即
# 连抓 10 帧 uiautomator dump（p29b_sbg_1..10，~25s，覆盖 4s SnackBar 窗口）。
BASE="$1"
ADB="D:/Android/platform-tools/adb.exe"
DEV="127.0.0.1:16384"
DIR="D:/OH-WorkSpace/LegadoTeam/legado/docs/parity_shots/verify_ui_20260922"
SQL="$DIR/p29b_q_cc.sql"
i=0
while true; do
  i=$((i+1))
  CUR=$("$ADB" -s "$DEV" shell 'run-as io.legado.flutter_legado sqlite3 app_flutter/legado.db' < "$SQL" 2>/dev/null | tr -d '\r' | tr -d ' ')
  if [ -n "$CUR" ] && [ "$CUR" != "$BASE" ]; then
    echo "DETECTED: cached_at $BASE -> $CUR at $(date +%H:%M:%S) (poll #$i)"
    for j in 1 2 3 4 5 6 7 8 9 10; do
      python "$DIR/p29b_adb.py" dump "$DIR/p29b_sbg_${j}.xml" >/dev/null 2>&1
      sleep 0.5
    done
    echo "RAPID_BURST_DONE"
    break
  fi
  sleep 1
done
