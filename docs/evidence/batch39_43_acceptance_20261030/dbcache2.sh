#!/system/bin/sh
DB=/data/user/0/io.legado.flutter_legado/app_flutter/legado.db
sqlite3 "$DB" "SELECT substr(value,1,600) FROM caches WHERE key=\"config:txt_toc_rules\";"
