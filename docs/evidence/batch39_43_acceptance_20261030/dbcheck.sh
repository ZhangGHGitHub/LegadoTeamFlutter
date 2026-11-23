#!/system/bin/sh
DB=/data/user/0/io.legado.flutter_legado/app_flutter/legado.db
sqlite3 "$DB" "SELECT \"bookSourceName\",\"bookSourceGroup\",\"respondTime\" FROM book_sources ORDER BY \"customOrder\";"
sqlite3 "$DB" "SELECT \"bookSourceUrl\",substr(\"checkFailReason\",1,60) FROM book_source_check_states;"
