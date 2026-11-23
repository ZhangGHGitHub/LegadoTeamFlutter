#!/system/bin/sh
# 批9a prefs 取证脚本：grep FlutterSharedPreferences.xml
grep -o 'name="[^"]*"[^/>]*value="[^"]*"' /data/user/0/io.legado.flutter_legado/shared_prefs/FlutterSharedPreferences.xml | grep -E "$1"
