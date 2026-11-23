#!/system/bin/sh
DB=/data/user/0/io.legado.flutter_legado/app_flutter/legado.db
sqlite3 "$DB" "DELETE FROM books WHERE bookUrl=\"\" OR name=\"\";"
sqlite3 "$DB" "SELECT name,origin,bookUrl,type FROM books;"
