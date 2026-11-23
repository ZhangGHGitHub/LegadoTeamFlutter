#!/system/bin/sh
DB=/data/user/0/io.legado.flutter_legado/app_flutter/legado.db
sqlite3 "$DB" "SELECT substr(\"ruleSearch\",1,200), length(\"ruleSearch\") FROM book_sources WHERE \"bookSourceUrl\" LIKE \"%qa43%\";"
sqlite3 "$DB" "SELECT \"searchUrl\" FROM book_sources WHERE \"bookSourceUrl\" LIKE \"%qa43%\";"
