#!/system/bin/sh
F=/data/user/0/io.legado.flutter_legado/shared_prefs/FlutterSharedPreferences.xml
if grep -q 'flutter.readBrightnessMode' "$F"; then
  sed -i 's|name="flutter.readBrightnessMode">[0-9]<|name="flutter.readBrightnessMode">1<|' "$F"
else
  sed -i 's|</map>|    <string name="flutter.readBrightnessMode">1</string>\n</map>|' "$F"
fi
grep -o 'name="flutter.readBrightnessMode">[0-9]<' "$F"
