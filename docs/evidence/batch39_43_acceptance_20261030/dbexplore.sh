#!/system/bin/sh
DB=/data/user/0/io.legado.flutter_legado/app_flutter/legado.db
sqlite3 "$DB" "SELECT \"exploreUrl\" FROM book_sources WHERE \"bookSourceUrl\"=\"http://192.168.100.52:18080\";"
