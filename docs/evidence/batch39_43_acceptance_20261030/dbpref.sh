#!/system/bin/sh
P=/data/user/0/io.legado.flutter_legado/shared_prefs/FlutterSharedPreferences.xml
grep -o "coverRestrictRatio[^<]*" "$P" || echo "KEY_NOT_FOUND"
