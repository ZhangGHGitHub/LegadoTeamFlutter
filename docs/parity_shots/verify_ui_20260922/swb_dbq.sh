#!/system/bin/sh
echo "=== books: 斗破 ==="
run-as io.legado.flutter_legado sh -c "sqlite3 app_flutter/legado.db 'SELECT name, bookUrl, origin, totalChapterNum, latestChapterTitle, durChapterPos, durChapterUpdate FROM books WHERE name LIKE \"%斗破%\"'"
echo "=== books: R1 ==="
run-as io.legado.flutter_legado sh -c "sqlite3 app_flutter/legado.db 'SELECT name, bookUrl, origin, totalChapterNum FROM books WHERE name LIKE \"R1%\"'"
echo "=== chapters per bookUrl ==="
run-as io.legado.flutter_legado sh -c "sqlite3 app_flutter/legado.db 'SELECT bookUrl, COUNT(*) FROM chapters GROUP BY bookUrl'"
