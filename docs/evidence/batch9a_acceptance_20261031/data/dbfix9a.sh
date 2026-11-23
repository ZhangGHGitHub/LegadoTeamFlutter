#!/system/bin/sh
DB=/data/user/0/io.legado.flutter_legado/app_flutter/legado.db
sqlite3 "$DB" "UPDATE books SET name='QA9A文A', origin='http://192.168.100.52:18090', originName='QA9A文书源', tocUrl='http://192.168.100.52:18090/book/QA9A%E6%96%87A/toc8', originBookUrl='http://192.168.100.52:18090/book/QA9A文A' WHERE bookUrl LIKE '%QA9A%';"
sqlite3 "$DB" "SELECT name, origin, tocUrl FROM books;"
