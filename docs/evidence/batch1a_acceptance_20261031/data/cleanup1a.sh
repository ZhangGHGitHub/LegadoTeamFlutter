#!/system/bin/sh
DB=/data/user/0/io.legado.flutter_legado/app_flutter/legado.db
sqlite3 "$DB" "DELETE FROM cached_chapters; DELETE FROM chapters; DELETE FROM books; DELETE FROM book_sources;"
echo "books=$(sqlite3 "$DB" 'SELECT count(*) FROM books;') sources=$(sqlite3 "$DB" 'SELECT count(*) FROM book_sources;')"
F=/data/user/0/io.legado.flutter_legado/shared_prefs/FlutterSharedPreferences.xml
sed -i '/name="flutter.screenOrientation"/d; /name="flutter.hideStatusBar"/d; /name="flutter.hideNavigationBar"/d; /name="flutter.showReadTitleAddition"/d; /name="flutter.disableReturnKey"/d; /name="flutter.sliderVibrator"/d; /name="flutter.pageTouchSlop"/d; /name="flutter.doubleHorizontalPage"/d; /name="flutter.progressBarBehavior"/d' "$F"
echo "prefs batch1a keys remaining: $(grep -c 'screenOrientation\|hideStatusBar\|hideNavigationBar\|showReadTitleAddition\|disableReturnKey\|sliderVibrator\|pageTouchSlop\|doubleHorizontalPage\|progressBarBehavior' "$F")"
rm -f /sdcard/Download/qa9a_sources.json /sdcard/Download/qa9a.cbz
rm -f /data/local/tmp/dbq1a.sh /data/local/tmp/prefq1a.sh /data/local/tmp/pref_te_off.sh /data/local/tmp/pref_te_on.sh /data/local/tmp/pref_bk_on.sh /data/local/tmp/pref_vib_on.sh /data/local/tmp/pref_vib_off.sh /data/local/tmp/dbreset_toc.sh /data/local/tmp/dbfix_toc2.sh /data/local/tmp/cleanup1a.sh
echo "device files cleaned"
