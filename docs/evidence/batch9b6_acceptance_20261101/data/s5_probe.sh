#!/usr/bin/env bash
# Scenario 5 probe: screen-off LAN reachability at 30s intervals.
ADB="D:\\Program Files\\MuMuPlayer\\nx_main\\adb.exe"
OUT="D:/OH-WorkSpace/LegadoTeam/legado/tmp_debug/device_acceptance_20261101_batch9b6/logcat/s5_lock_screen_series.log"
: > "$OUT"
for i in $(seq 0 12); do
  ts=$(date '+%Y-%m-%d %H:%M:%S')
  wf=$("$ADB" -s 192.168.100.62:5555 shell "dumpsys power | grep -E 'mWakefulness=|Wake Locks:'" | tr '\n' ';' | tr -d '\r')
  wl=$("$ADB" -s 192.168.100.62:5555 shell "dumpsys wifi | grep -c 'WifiLock{legado:WebService'" | tr -d '\r')
  ps=$("$ADB" -s 192.168.100.62:5555 shell "ps -A | grep -c io.legado.flutter_legado" | tr -d '\r')
  curlout=$(curl -s -m 5 -o /dev/null -w "%{http_code}/%{time_total}" http://192.168.100.62:1122/api/health 2>&1)
  echo "$ts | i=$i | $wf | wifi_lock_lines=$wl | proc=$ps | curl=$curlout" >> "$OUT"
  sleep 30
done
