#!/system/bin/sh
DB=/data/user/0/io.legado.flutter_legado/app_flutter/legado.db
sqlite3 "$DB" "SELECT \"bookSourceUrl\",status,checkedAt,substr(detail,1,80) FROM book_source_check_states;"
