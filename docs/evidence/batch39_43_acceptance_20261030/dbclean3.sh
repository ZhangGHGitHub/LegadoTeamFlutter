#!/system/bin/sh
DB=/data/user/0/io.legado.flutter_legado/app_flutter/legado.db
sqlite3 "$DB" "DELETE FROM books WHERE bookUrl=\"\"; SELECT count(*) FROM books;"
