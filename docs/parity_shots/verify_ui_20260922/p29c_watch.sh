#!/usr/bin/env bash
# p29c_watch.sh <tag> [maxpolls]
# 轮询 uiautomator dump（~3s/轮，p29c_<tag>_w_<i>.xml）：
# - 出现 已更换书源 / 更换书源后重载失败 / 崩溃时间 => 立即连抓 10 帧（0.5s 间隔）
#   覆盖结果 SnackBar 4s 窗口（p29c_<tag>_w_<i>_r1..10.xml），WATCH_DONE(trigger)
# - 进行中条消失（可能是 10min 自动过期，重载或仍在进行）=> 记录后继续轮询，
#   直到结果文本出现（再快抓）；若连续 40 轮无任何相关文本 => 窗口已错过，
#   快抓一次留证后 WATCH_DONE(window_missed)
# - maxpolls 内未出现 => WATCH_TIMEOUT
# timeline 追加式（重跑保留历史）
TAG="$1"; MAX="${2:-320}"
DIR="D:/OH-WorkSpace/LegadoTeam/legado/docs/parity_shots/verify_ui_20260922"
TL="$DIR/p29c_${TAG}_watch_timeline.txt"
echo "" >> "$TL"
echo "=== watch session start $(date '+%H:%M:%S.%3N') ===" >> "$TL"
gone_since=0
for i in $(seq 1 "$MAX"); do
  python "$DIR/p29b_adb.py" dump "$DIR/p29c_${TAG}_w_${i}.xml" >/dev/null 2>&1
  f="$DIR/p29c_${TAG}_w_${i}.xml"
  in=0; ok=0; fail=0; crash=0
  grep -q "正在更换书源" "$f" 2>/dev/null && in=1
  grep -q "已更换书源" "$f" 2>/dev/null && ok=1
  grep -q "更换书源后重载失败" "$f" 2>/dev/null && fail=1
  grep -q "崩溃时间" "$f" 2>/dev/null && crash=1
  echo "$i $(date +%s%3N) in=$in ok=$ok fail=$fail crash=$crash" >> "$TL"
  if [ $ok -eq 1 ] || [ $fail -eq 1 ] || [ $crash -eq 1 ]; then
    echo "TRIGGERED at poll $i: ok=$ok fail=$fail crash=$crash"
    for j in 1 2 3 4 5 6 7 8 9 10; do
      python "$DIR/p29b_adb.py" dump "$DIR/p29c_${TAG}_w_${i}_r${j}.xml" >/dev/null 2>&1
      sleep 0.5
    done
    echo "WATCH_DONE ${TAG} triggered_at_poll=$i"
    exit 0
  fi
  if [ $in -eq 1 ]; then
    gone_since=0
  else
    if [ $gone_since -eq 0 ]; then
      echo "INPROG_GONE first observed at poll $i (可能 10min 自动过期, 继续等结果)" >> "$TL"
    fi
    gone_since=$((gone_since+1))
    if [ $gone_since -ge 40 ]; then
      echo "NO_RESULT after 40 polls with in-progress absent => 快抓留证"
      for j in 1 2 3 4 5 6 7 8 9 10; do
        python "$DIR/p29b_adb.py" dump "$DIR/p29c_${TAG}_w_${i}_r${j}.xml" >/dev/null 2>&1
        sleep 0.5
      done
      echo "WATCH_DONE ${TAG} window_missed_at_poll=$i"
      exit 0
    fi
  fi
  sleep 1
done
echo "WATCH_TIMEOUT ${TAG} polls=$MAX (结果文本始终未出现, 需人工定性)"
