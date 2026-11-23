#!/system/bin/sh
DB=/data/user/0/io.legado.flutter_legado/app_flutter/legado.db
sqlite3 "$DB" "SELECT key, length(value) FROM caches WHERE key LIKE \"%toc%\" OR key LIKE \"%txt%\";"
sqlite3 "$DB" "SELECT substr(value,1,200) FROM caches WHERE key=\"txt_toc_rules\";"
