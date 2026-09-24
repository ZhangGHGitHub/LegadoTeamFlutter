#!/bin/bash
# usage: sbd_shots.sh <tag> [dump]  -> sbd_<tag>.png (+ sbd_<tag>_dump.xml)
# robust: always rm remote file first, retry capture, verify remote file
# before pull so a failed capture NEVER pulls a stale frame.
DEV=192.168.100.63:5555
ADB=D:/Android/platform-tools/adb.exe
DIR=D:/OH-WorkSpace/LegadoTeam/legado/docs/parity_shots/verify_ui_20260922
SF=4619827203584079877
TAG=$1
MSYS_NO_PATHCONV=1 $ADB -s $DEV shell "rm -f /sdcard/sbd_cap.png" >/dev/null 2>&1
ok=""
for i in 1 2 3 4 5; do
  MSYS_NO_PATHCONV=1 $ADB -s $DEV shell "screencap -p -d $SF /sdcard/sbd_cap.png" >/dev/null 2>&1
  sz=$(MSYS_NO_PATHCONV=1 $ADB -s $DEV shell "stat -c %s /sdcard/sbd_cap.png 2>/dev/null || echo 0")
  if [ -n "$sz" ] && [ "$sz" != "0" ]; then ok=1; break; fi
  sleep 0.5
done
if [ -z "$ok" ]; then
  echo "CAPTURE FAILED after 5 tries (tag=$TAG)" >&2
  exit 1
fi
MSYS_NO_PATHCONV=1 $ADB -s $DEV pull /sdcard/sbd_cap.png "$DIR/sbd_${TAG}.png" >/dev/null 2>&1
MSYS_NO_PATHCONV=1 $ADB -s $DEV shell "rm -f /sdcard/sbd_cap.png" >/dev/null 2>&1
if [ -n "$2" ]; then
  MSYS_NO_PATHCONV=1 $ADB -s $DEV shell "rm -f /sdcard/sbd_ud.xml; uiautomator dump /sdcard/sbd_ud.xml >/dev/null 2>&1; cat /sdcard/sbd_ud.xml; rm -f /sdcard/sbd_ud.xml" > "$DIR/sbd_${TAG}_dump.xml" 2>/dev/null
fi
ls -la "$DIR/sbd_${TAG}.png" 2>/dev/null
