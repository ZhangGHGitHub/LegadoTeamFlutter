#!/system/bin/sh
# 批9a DB 只读取证脚本（推送到 /data/local/tmp 执行，规避 MSYS 路径转换）
DB=/data/user/0/io.legado.flutter_legado/app_flutter/legado.db
sqlite3 "$DB" "$1"
