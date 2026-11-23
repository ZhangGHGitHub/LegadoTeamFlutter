#!/system/bin/sh
DB=/data/user/0/io.legado.flutter_legado/app_flutter/legado.db
sqlite3 "$DB" "SELECT \"bookSourceUrl\",\"bookSourceName\" FROM book_sources;"
