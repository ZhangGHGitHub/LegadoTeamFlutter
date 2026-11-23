#!/system/bin/sh
F=/data/user/0/io.legado.flutter_legado/shared_prefs/FlutterSharedPreferences.xml
sed -i 's|name="flutter.showReadTitleAddition" value="false"|name="flutter.showReadTitleAddition" value="true"|' "$F"
grep -o 'name="flutter.showReadTitleAddition" value="[a-z]*"' "$F"
