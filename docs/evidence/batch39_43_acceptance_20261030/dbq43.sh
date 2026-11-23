#!/system/bin/sh
DB=/data/user/0/io.legado.flutter_legado/app_flutter/legado.db
sqlite3 "$DB" "SELECT count(*) FROM chapters WHERE bookUrl LIKE \"%qa43%\""
sqlite3 "$DB" "SELECT \"index\",title FROM chapters WHERE bookUrl LIKE \"%qa43%\" ORDER BY \"index\""
sqlite3 "$DB" "SELECT totalChapterNum,latestChapterTitle,durChapterIndex FROM books WHERE bookUrl LIKE \"%qa43%\""
