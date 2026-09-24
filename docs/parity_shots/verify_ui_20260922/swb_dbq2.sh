#!/system/bin/sh
echo "=== books schema ==="
run-as io.legado.flutter_legado sh -c "sqlite3 app_flutter/legado.db '.schema books'"
echo "=== 斗破 full row (SELECT *) ==="
run-as io.legado.flutter_legado sh -c "sqlite3 -header app_flutter/legado.db 'SELECT * FROM books WHERE name LIKE \"%斗破%\"'"
