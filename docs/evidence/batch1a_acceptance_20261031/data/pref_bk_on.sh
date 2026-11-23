#!/system/bin/sh
F=/data/user/0/io.legado.flutter_legado/shared_prefs/FlutterSharedPreferences.xml
if grep -q 'flutter.disableReturnKey' "$F"; then
  sed -i 's|name="flutter.disableReturnKey" value="false"|name="flutter.disableReturnKey" value="true"|' "$F"
else
  sed -i 's|</map>|    <boolean name="flutter.disableReturnKey" value="true" />\n</map>|' "$F"
fi
grep -o 'name="flutter.disableReturnKey" value="[a-z]*"' "$F"
