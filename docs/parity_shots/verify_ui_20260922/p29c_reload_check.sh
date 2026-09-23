#!/usr/bin/env bash
# p29c_reload_check.sh <tag>
# 重载链复核：DB books 行 + chapters 前3章 + 阅读器顶栏/正文 dump
DIR="D:/OH-WorkSpace/LegadoTeam/legado/docs/parity_shots/verify_ui_20260922"
TAG="$1"
ADB="D:/Android/platform-tools/adb.exe"; DEV="127.0.0.1:16384"; PKG="io.legado.flutter_legado"
OUT="$DIR/p29c_${TAG}_reload_check.txt"
{
  echo "=== 重载链复核 $TAG $(date '+%F %H:%M:%S') ==="
  echo "--- books 行 ---"
  $ADB -s $DEV shell "run-as $PKG sqlite3 app_flutter/legado.db \"SELECT bookUrl, type, origin, originName, originBookUrl, tocUrl, totalChapterNum, durChapterIndex, durChapterPos FROM books WHERE name='斗破苍穹';\"" 2>&1 | tr -d '\r'
  echo "--- chapters (两个候选键: bookUrl 主键 / originBookUrl) ---"
  BURL=$($ADB -s $DEV shell "run-as $PKG sqlite3 app_flutter/legado.db \"SELECT bookUrl FROM books WHERE name='斗破苍穹';\"" 2>/dev/null | tr -d '\r')
  OBU=$($ADB -s $DEV shell "run-as $PKG sqlite3 app_flutter/legado.db \"SELECT originBookUrl FROM books WHERE name='斗破苍穹';\"" 2>/dev/null | tr -d '\r')
  echo "bookUrl(主键)=$BURL"
  echo "originBookUrl=$OBU"
  echo "[key=bookUrl] 前3章:"
  $ADB -s $DEV shell "run-as $PKG sqlite3 app_flutter/legado.db \"SELECT \\\"index\\\", title FROM chapters WHERE bookUrl='$BURL' ORDER BY \\\"index\\\" LIMIT 3;\"" 2>&1 | tr -d '\r'
  echo "[key=bookUrl] 总数: $($ADB -s $DEV shell "run-as $PKG sqlite3 app_flutter/legado.db \"SELECT COUNT(*) FROM chapters WHERE bookUrl='$BURL';\"" 2>/dev/null | tr -d '\r')"
  echo "[key=originBookUrl] 前3章:"
  $ADB -s $DEV shell "run-as $PKG sqlite3 app_flutter/legado.db \"SELECT \\\"index\\\", title FROM chapters WHERE bookUrl='$OBU' ORDER BY \\\"index\\\" LIMIT 3;\"" 2>&1 | tr -d '\r'
  echo "[key=originBookUrl] 总数: $($ADB -s $DEV shell "run-as $PKG sqlite3 app_flutter/legado.db \"SELECT COUNT(*) FROM chapters WHERE bookUrl='$OBU';\"" 2>/dev/null | tr -d '\r')"
  echo "--- 阅读器 dump ---"
  python "$DIR/p29b_adb.py" dump "$DIR/p29c_${TAG}_reader_after.xml" >/dev/null 2>&1
  python "$DIR/p29_dumpview.py" "$DIR/p29c_${TAG}_reader_after.xml" 2>&1 | head -6
} > "$OUT" 2>&1
cat "$OUT"
