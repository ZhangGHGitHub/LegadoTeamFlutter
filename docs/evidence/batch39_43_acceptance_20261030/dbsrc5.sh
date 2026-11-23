#!/system/bin/sh
DB=/data/user/0/io.legado.flutter_legado/app_flutter/legado.db
sqlite3 "$DB" "SELECT \"loginUrl\" FROM book_sources WHERE \"bookSourceUrl\"=\"https://example.com/source-p25\";"; sqlite3 "$DB" "SELECT count(*) FROM book_sources;"
