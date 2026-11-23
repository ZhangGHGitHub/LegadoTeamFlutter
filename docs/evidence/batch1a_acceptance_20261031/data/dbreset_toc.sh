#!/system/bin/sh
DB=/data/user/0/io.legado.flutter_legado/app_flutter/legado.db
sqlite3 "$DB" "DELETE FROM cached_chapters; DELETE FROM chapters WHERE bookUrl LIKE '%文A%';"
sqlite3 "$DB" "UPDATE books SET tocUrl='http://192.168.100.52:18090/book/QA9A%E6%96%87A/toc8', durChapterIndex=0 WHERE bookUrl LIKE '%文A%';"
echo "reset ok"
