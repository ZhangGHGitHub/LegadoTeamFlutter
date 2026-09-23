#!/usr/bin/env bash
# p29c_burst.sh <tag> [nframes]
# 连续 uiautomator dump（~1.5-2s/帧），覆盖 4s 结果 SnackBar 窗口。
# 产出: p29c_<tag>_burst_<j>.xml + p29c_<tag>_timeline.txt (j t_start_ms t_end_ms)
TAG="$1"; N="${2:-25}"
DIR="D:/OH-WorkSpace/LegadoTeam/legado/docs/parity_shots/verify_ui_20260922"
TL="$DIR/p29c_${TAG}_timeline.txt"
echo "burst start $(date '+%H:%M:%S.%3N')" > "$TL"
for j in $(seq 1 "$N"); do
  t0=$(date +%s%3N)
  python "$DIR/p29b_adb.py" dump "$DIR/p29c_${TAG}_burst_${j}.xml" >/dev/null 2>&1
  t1=$(date +%s%3N)
  echo "$j $t0 $t1" >> "$TL"
  sleep 0.3
done
echo "burst end $(date '+%H:%M:%S.%3N')" >> "$TL"
echo "BURST_DONE ${TAG} frames=${N}"
