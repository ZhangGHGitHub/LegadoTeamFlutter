#!/bin/bash
ADB="D:\Program Files\MuMuPlayer\nx_main\adb.exe"
S=192.168.100.62:5555
OUT=/d/OH-WorkSpace/LegadoTeam/legado/tmp_debug/device_acceptance_20261101_batch9b6c/logcat/s2_lockscreen_series.log
: > "$OUT"
sample() {
  local tag="$1"
  local t=$(date +%H:%M:%S)
  local wake=$("$ADB" -s $S shell dumpsys power | grep -m1 "mWakefulness=" | tr -d '\r' | sed 's/^ *//')
  local locks=$("$ADB" -s $S shell dumpsys power | grep -m1 "Wake Locks: size=" | tr -d '\r')
  local partial=$("$ADB" -s $S shell dumpsys power | grep -c "PARTIAL_WAKE_LOCK .*legado:WebService")
  local wifi=$("$ADB" -s $S shell dumpsys wifi | grep -c "WifiLock{legado:WebService")
  local fg=$("$ADB" -s $S shell "dumpsys activity services io.legado.flutter_legado" | grep -m1 "isForeground=" | grep -o "isForeground=[a-z]*" | head -1)
  local pid=$("$ADB" -s $S shell pidof io.legado.flutter_legado | tr -d '\r')
  local c1=$(curl -s -m 5 -o /dev/null -w "%{http_code}/%{time_total}" http://192.168.100.62:1122/api/health)
  local c2=$(curl -s -m 5 -o /dev/null -w "%{http_code}/%{time_total}" http://192.168.100.62:1122/api/health)
  local c3=$(curl -s -m 5 -o /dev/null -w "%{http_code}/%{time_total}" http://192.168.100.62:1122/api/health)
  local loop=$("$ADB" -s $S shell "printf 'GET /api/health HTTP/1.0\r\n\r\n' | timeout 5 nc 127.0.0.1 1122 | tail -1" | tr -d '\r')
  echo "[$t] $tag | $wake | $locks | partial=$partial wifi=$wifi | $fg | pid=$pid | curl=$c1,$c2,$c3 | loopback=$loop" | tee -a "$OUT"
}
echo "### screen off at $(date +%H:%M:%S)" | tee -a "$OUT"
"$ADB" -s $S shell input keyevent 223
sleep 3
sample "t+3s"
sleep 7
sample "t+10s"
sleep 10; sample "t+20s"
sleep 10; sample "t+30s"
sleep 10; sample "t+40s"
sleep 10; sample "t+50s"
sleep 10; sample "t+60s"
sleep 30; sample "t+90s"
sleep 30; sample "t+120s"
sleep 60; sample "t+180s"
sleep 60; sample "t+240s"
sleep 60; sample "t+300s"
echo "### done $(date +%H:%M:%S)" | tee -a "$OUT"
