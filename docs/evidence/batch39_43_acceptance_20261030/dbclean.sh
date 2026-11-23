#!/system/bin/sh
DB=/data/user/0/io.legado.flutter_legado/app_flutter/legado.db
sqlite3 "$DB" "DELETE FROM books WHERE origin=\"loc_book\" AND name=\"\" AND bookUrl=\"\";"
sqlite3 "$DB" "SELECT count(*) FROM books;"
