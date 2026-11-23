#!/system/bin/sh
DB=/data/user/0/io.legado.flutter_legado/app_flutter/legado.db
sqlite3 "$DB" "DELETE FROM books;"
sqlite3 "$DB" "DELETE FROM book_sources;"
sqlite3 "$DB" "DELETE FROM book_source_check_states;"
sqlite3 "$DB" "DELETE FROM readRecord;"
sqlite3 "$DB" "DELETE FROM chapters;"
sqlite3 "$DB" "SELECT count(*) FROM books; SELECT count(*) FROM book_sources;"
