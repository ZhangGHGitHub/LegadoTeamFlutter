#!/system/bin/sh
F=/data/user/0/io.legado.flutter_legado/shared_prefs/FlutterSharedPreferences.xml
sed -i 's|name="flutter.keep_light" value="-1"|name="flutter.keep_light" value="60"|' "$F"
grep -o 'name="flutter.keep_light" value="[0-9-]*"' "$F"
