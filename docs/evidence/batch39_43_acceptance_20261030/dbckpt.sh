#!/system/bin/sh
DB=/data/user/0/io.legado.flutter_legado/app_flutter/legado.db
sqlite3 "$DB" "PRAGMA wal_checkpoint(FULL);" "SELECT count(*) FROM txtTocRules;"
