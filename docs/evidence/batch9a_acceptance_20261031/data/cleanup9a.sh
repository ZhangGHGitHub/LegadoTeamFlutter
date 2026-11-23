#!/system/bin/sh
DB=/data/user/0/io.legado.flutter_legado/app_flutter/legado.db
# 1) DB 测试数据清空
sqlite3 "$DB" "DELETE FROM cached_chapters;"
sqlite3 "$DB" "DELETE FROM chapters;"
sqlite3 "$DB" "DELETE FROM books;"
sqlite3 "$DB" "DELETE FROM book_sources;"
sqlite3 "$DB" "DELETE FROM search_books;"
echo "books=$(sqlite3 "$DB" 'SELECT count(*) FROM books;') sources=$(sqlite3 "$DB" 'SELECT count(*) FROM book_sources;') cached=$(sqlite3 "$DB" 'SELECT count(*) FROM cached_chapters;')"
# 2) 批9a 偏好恢复默认（删除键 → 回落代码默认）
F=/data/user/0/io.legado.flutter_legado/shared_prefs/FlutterSharedPreferences.xml
sed -i '/name="flutter.preDownloadNum"/d; /name="flutter.sourceEditMaxLine"/d; /name="flutter.bitmapCacheSize"/d; /name="flutter.antiAlias"/d; /name="flutter.showMangaUi"/d; /name="flutter.lastCheckUpdate"/d; /name="flutter.app_locale"/d' "$F"
grep -c 'preDownloadNum\|sourceEditMaxLine\|bitmapCacheSize\|antiAlias\|showMangaUi\|lastCheckUpdate\|app_locale' "$F" || echo "prefs cleaned: 0 batch9a keys"
# 3) 设备文件清理
rm -f /sdcard/Download/qa9a_sources.json /sdcard/Download/qa9a.cbz
rm -f /data/local/tmp/dbq9a.sh /data/local/tmp/prefq9a.sh /data/local/tmp/prefset.sh /data/local/tmp/prefclear_upd.sh /data/local/tmp/dbfix9a.sh /data/local/tmp/dbclear_manga.sh /data/local/tmp/dbdel_manga.sh /data/local/tmp/cleanup9a.sh
echo "files cleaned"
