#!/system/bin/sh
F=/data/user/0/io.legado.flutter_legado/shared_prefs/FlutterSharedPreferences.xml
if grep -q 'flutter.sliderVibrator' "$F"; then
  sed -i 's|name="flutter.sliderVibrator" value="false"|name="flutter.sliderVibrator" value="true"|' "$F"
else
  sed -i 's|</map>|    <boolean name="flutter.sliderVibrator" value="true" />\n</map>|' "$F"
fi
grep -o 'name="flutter.sliderVibrator" value="[a-z]*"' "$F"
