#!/system/bin/sh
F=/data/user/0/io.legado.flutter_legado/shared_prefs/FlutterSharedPreferences.xml
sed -i 's|name="flutter.sliderVibrator" value="true"|name="flutter.sliderVibrator" value="false"|' "$F"
grep -o 'name="flutter.sliderVibrator" value="[a-z]*"' "$F"
