#!/system/bin/sh
PKG=io.legado.flutter_legado
run-as $PKG sh -c "sqlite3 -separator '|' app_flutter/legado.db \"SELECT bookUrl, tocUrl, origin, originName, name, author, totalChapterNum, latestChapterTitle, durChapterTitle, durChapterIndex, durChapterPos, wordCount FROM books WHERE name LIKE '%斗破%'\""
