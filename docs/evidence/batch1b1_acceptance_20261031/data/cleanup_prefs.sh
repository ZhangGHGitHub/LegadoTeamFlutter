#!/system/bin/sh
F=/data/user/0/io.legado.flutter_legado/shared_prefs/FlutterSharedPreferences.xml
# 批1b 键：keep_light / readBrightnessMode / readBrightnessVwPos /
# brightness_mode_migrated_v1b1 / showBrightnessView / readMenuBrightnessVertical /
# 夜间态恢复（阅读背景回归默认由主题默认承担，删批1b 引入的阅读级键）
sed -i -e '/flutter.keep_light/d' \
       -e '/flutter.readBrightnessMode/d' \
       -e '/flutter.readBrightnessVwPos/d' \
       -e '/flutter.brightness_mode_migrated_v1b1/d' \
       -e '/flutter.showBrightnessView/d' \
       -e '/flutter.readMenuBrightnessVertical/d' \
       -e '/flutter.readMenuBrightnessPos/d' "$F"
echo '--- residual batch1b keys (expect all 0) ---'
for k in keep_light readBrightnessMode readBrightnessVwPos brightness_mode_migrated_v1b1 showBrightnessView readMenuBrightnessVertical readMenuBrightnessPos; do
  printf '%s=%s\n' "$k" "$(grep -c "flutter.$k" "$F")"
done
