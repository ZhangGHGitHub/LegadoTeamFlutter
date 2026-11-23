# 备用：直接经 caches 更小值再触发懒解析（重开书）。设置值已证可写（6099 落库），
# 本脚本仅用于把 config 改 3000 供"恢复"半边验证。
DB=/data/user/0/io.legado.flutter_legado/app_flutter/legado.db
sqlite3 "$DB" "UPDATE caches SET value='3000' WHERE key='config:maxLengthWithNoToc';"
sqlite3 "$DB" "SELECT key, value FROM caches WHERE key='config:maxLengthWithNoToc';"
