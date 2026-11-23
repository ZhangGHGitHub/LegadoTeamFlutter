#!/system/bin/sh
# 直写 caches config:maxLengthWithNoToc（QA 数据侧；与 UI 滑块写入等价的真源）
DB=/data/user/0/io.legado.flutter_legado/app_flutter/legado.db
V=$1
sqlite3 "$DB" "DELETE FROM caches WHERE \"key\"='config:maxLengthWithNoToc';"
sqlite3 "$DB" "INSERT INTO caches (\"key\", value) VALUES ('config:maxLengthWithNoToc', '$V');"
sqlite3 "$DB" "SELECT \"key\", value FROM caches WHERE \"key\"='config:maxLengthWithNoToc';"
