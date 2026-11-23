#!/system/bin/sh
DB=/data/user/0/io.legado.flutter_legado/app_flutter/legado.db
sqlite3 "$DB" "SELECT name,origin,bookUrl,type FROM books WHERE type!=4096;"; sqlite3 "$DB" "SELECT name,origin,bookUrl FROM books WHERE bookUrl LIKE \"%qa43-block%\";"
