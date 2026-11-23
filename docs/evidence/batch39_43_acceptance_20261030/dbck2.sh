#!/system/bin/sh
DB=/data/user/0/io.legado.flutter_legado/app_flutter/legado.db
sqlite3 "$DB" "PRAGMA table_info(book_source_check_states);"
sqlite3 "$DB" "SELECT \"bookSourceUrl\",\"state\",\"failReason\",\"checkTime\" FROM book_source_check_states;" 2>/dev/null
