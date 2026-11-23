#!/system/bin/sh
DB=/data/user/0/io.legado.flutter_legado/app_flutter/legado.db
sqlite3 "$DB" "SELECT count(*) AS rules FROM txtTocRules;"
sqlite3 "$DB" "SELECT count(*) FROM books;"
sqlite3 "$DB" "PRAGMA integrity_check;"
