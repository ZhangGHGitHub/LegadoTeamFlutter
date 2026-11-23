#!/system/bin/sh
grep -o 'name="[^"]*"[^/>]*value="[^"]*"' /data/user/0/io.legado.flutter_legado/shared_prefs/FlutterSharedPreferences.xml | grep -E "$1"
