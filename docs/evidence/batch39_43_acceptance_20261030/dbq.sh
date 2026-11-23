#!/system/bin/sh
DB=/data/user/0/io.legado.flutter_legado/databases/legado.db
sqlite3 "$DB" "$1"
