#!/system/bin/sh
DB=/data/user/0/io.legado.flutter_legado/app_flutter/legado.db
sqlite3 "$DB" "PRAGMA table_info(book_sources);" | head -5
sqlite3 "$DB" "SELECT book_source_url, login_url FROM book_sources WHERE book_source_url LIKE \"%qa43%\";"
