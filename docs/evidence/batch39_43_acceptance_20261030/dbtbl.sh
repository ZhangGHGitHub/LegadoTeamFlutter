#!/system/bin/sh
DB=/data/user/0/io.legado.flutter_legado/app_flutter/legado.db
sqlite3 "$DB" "SELECT name FROM sqlite_master WHERE name LIKE \"%source%\";"
