#!/system/bin/sh
DB=/data/user/0/io.legado.flutter_legado/app_flutter/legado.db
sqlite3 "$DB" "SELECT name,author,\"customCoverUrl\",origin FROM books;"
sqlite3 "$DB" "SELECT \"bookName\",\"coverUrl\" FROM readRecord;"
