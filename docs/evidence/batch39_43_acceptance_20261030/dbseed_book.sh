#!/system/bin/sh
DB=/data/user/0/io.legado.flutter_legado/app_flutter/legado.db
sqlite3 "$DB" "DELETE FROM books WHERE bookUrl=\"\";"
sqlite3 "$DB" "INSERT INTO books (bookUrl,tocUrl,origin,originName,name,author,type,\"group\",totalChapterNum,durChapterIndex,durChapterPos,latestChapterTitle) VALUES (\"https://qa43-block.example.com/book/1\",\"\",\"https://qa43-block.example.com/source\",\"QA43拦截源\",\"QA43登录书\",\"QA43\",0,0,1,0,0,\"第一章\");"
sqlite3 "$DB" "SELECT name,origin,bookUrl,type FROM books;"
