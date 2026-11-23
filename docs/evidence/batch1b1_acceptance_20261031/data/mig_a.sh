#!/system/bin/sh
F=/data/user/0/io.legado.flutter_legado/shared_prefs/FlutterSharedPreferences.xml
sed -i '/flutter.brightness_mode_migrated_v1b1/d' "$F"
sed -i '/name="flutter.readBrightnessMode"/d' "$F"
sed -i 's|\("flutter.showBrightnessView" value="\)[^"]*"|\1true"|' "$F"
echo '--- migA after edit ---'
grep -c 'brightness_mode_migrated_v1b1' "$F"
grep -c 'name="flutter.readBrightnessMode"' "$F"
grep -o 'name="flutter.showBrightnessView" value="[^"]*"' "$F"
grep -c 'name="flutter.readMenuBrightnessVertical"' "$F"
