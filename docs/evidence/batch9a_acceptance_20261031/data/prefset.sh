#!/system/bin/sh
# prefs 写入辅助：$1=xml 转义后的 name-value 对（name 改 lastCheckUpdate value）
# 直接 sed 替换 FlutterSharedPreferences.xml 中 lastCheckUpdate 的 value
F=/data/user/0/io.legado.flutter_legado/shared_prefs/FlutterSharedPreferences.xml
grep -o 'name="flutter.lastCheckUpdate" value="[0-9]*"' "$F" || echo "no lastCheckUpdate entry"
