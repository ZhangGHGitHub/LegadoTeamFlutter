#!/system/bin/sh
DB=/data/user/0/io.legado.flutter_legado/app_flutter/legado.db
sqlite3 "$DB" "UPDATE book_sources SET \"bookSourceName\"=\"QA42发现源\", \"enabledExplore\"=1, \"exploreUrl\"=\"分类::http://192.168.100.52:18080/explore?page={{page}}\", \"ruleExplore\"=\"{\\\"bookList\\\":\\\"\$[*]\\\",\\\"name\\\":\\\"\$.name\\\",\\\"author\\\":\\\"\$.author\\\",\\\"bookUrl\\\":\\\"\$.bookUrl\\\"}\" WHERE \"bookSourceUrl\"=\"http://192.168.100.52:18080\"; SELECT \"bookSourceUrl\",\"bookSourceName\",\"enabledExplore\" FROM book_sources WHERE \"bookSourceUrl\"=\"http://192.168.100.52:18080\";"
