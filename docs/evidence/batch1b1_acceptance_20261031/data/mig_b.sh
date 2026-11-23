#!/system/bin/sh
F=/data/user/0/io.legado.flutter_legado/shared_prefs/FlutterSharedPreferences.xml
sed -i '/flutter.brightness_mode_migrated_v1b1/d' "$F"
sed -i '/name="flutter.readBrightnessMode"/d' "$F"
sed -i '/name="flutter.readMenuBrightnessVertical"/d' "$F"
sed -i 's|</map>|    <boolean name="flutter.readMenuBrightnessVertical" value="true" />\n</map>|' "$F"
echo '--- migB after edit ---'
grep -c 'brightness_mode_migrated_v1b1' "$F"
grep -c 'name="flutter.readBrightnessMode"' "$F"
grep -o 'name="flutter.readMenuBrightnessVertical" value="[^"]*"' "$F"
grep -o 'name="flutter.showBrightnessView" value="[^"]*"' "$F"
