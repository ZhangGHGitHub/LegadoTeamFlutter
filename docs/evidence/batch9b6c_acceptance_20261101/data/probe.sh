#!/bin/bash
# QA probe: service + notification + power + curl
ADB="D:\Program Files\MuMuPlayer\nx_main\adb.exe"
S=192.168.100.62:5555
echo "=== $(date +%H:%M:%S) ==="
"$ADB" -s $S shell "dumpsys activity services io.legado.flutter_legado" | grep -E "ServiceRecord|foreground|isForeground|startRequested|stopWithTask|createTime" | head -12
echo "--- notifications ---"
"$ADB" -s $S shell "dumpsys notification --noredact" | grep -E "io.legado.flutter_legado|Web 服务运行中|tickerText" | head -12
echo "--- curl host ---"
curl -s -m 5 -o /dev/null -w "HTTP=%{http_code} time=%{time_total}\n" "http://192.168.100.62:1122/api/health"
echo "--- curl device loopback ---"
"$ADB" -s $S shell "printf 'GET /api/health HTTP/1.0\r\n\r\n' | timeout 5 nc 127.0.0.1 1122 | tail -1"
