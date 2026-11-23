#!/system/bin/sh
F=/data/user/0/io.legado.flutter_legado/shared_prefs/FlutterSharedPreferences.xml
sed -i 's|name="flutter.lastCheckUpdate" value="[0-9]*"|name="flutter.lastCheckUpdate" value="0"|' "$F"
grep -o 'name="flutter.lastCheckUpdate" value="[0-9]*"' "$F"
