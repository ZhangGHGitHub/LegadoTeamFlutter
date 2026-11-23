#!/system/bin/sh
DB=/data/user/0/io.legado.flutter_legado/app_flutter/legado.db
sqlite3 "$DB" "DELETE FROM cached_chapters WHERE book_url LIKE '%漫A%';"
sqlite3 "$DB" "DELETE FROM chapters WHERE bookUrl LIKE '%漫A%';"
sqlite3 "$DB" "DELETE FROM books WHERE name LIKE '%漫A%' OR bookUrl LIKE '%漫A%';"
sqlite3 "$DB" "SELECT count(*) FROM books WHERE bookUrl LIKE '%漫A%';"
