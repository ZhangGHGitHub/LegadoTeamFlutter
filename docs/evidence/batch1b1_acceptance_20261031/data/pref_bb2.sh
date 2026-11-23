#!/system/bin/sh
F=/data/user/0/io.legado.flutter_legado/shared_prefs/FlutterSharedPreferences.xml
sed -i 's|name="flutter.readBrightnessMode">1<|name="flutter.readBrightnessMode">2<|' "$F"
grep -o 'name="flutter.readBrightnessMode">[0-9]<' "$F"
