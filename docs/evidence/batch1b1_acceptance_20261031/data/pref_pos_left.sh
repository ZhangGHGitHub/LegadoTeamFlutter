#!/system/bin/sh
F=/data/user/0/io.legado.flutter_legado/shared_prefs/FlutterSharedPreferences.xml
if grep -q 'flutter.readBrightnessVwPos' "$F"; then
  sed -i 's|name="flutter.readBrightnessVwPos">[0-9]<|name="flutter.readBrightnessVwPos">0<|' "$F"
else
  sed -i 's|</map>|    <string name="flutter.readBrightnessVwPos">0</string>\n</map>|' "$F"
fi
grep -o 'name="flutter.readBrightnessVwPos">[0-9]<' "$F"
