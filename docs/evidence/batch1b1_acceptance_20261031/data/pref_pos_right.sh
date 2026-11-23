#!/system/bin/sh
F=/data/user/0/io.legado.flutter_legado/shared_prefs/FlutterSharedPreferences.xml
sed -i 's|name="flutter.readBrightnessVwPos">[0-9]<|name="flutter.readBrightnessVwPos">1<|' "$F"
grep -o 'name="flutter.readBrightnessVwPos">[0-9]<' "$F"
