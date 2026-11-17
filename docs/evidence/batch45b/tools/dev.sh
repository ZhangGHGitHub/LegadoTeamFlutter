#!/usr/bin/env bash
# QA 批45b 设备操作辅助（不改动产品代码，仅验收取证）
export PATH="/d/Android/platform-tools:$PATH"
export MSYS2_ARG_CONV_EXCL="*"
D=192.168.100.63:5555
OUT="D:/OH-WorkSpace/LegadoTeam/legado/docs/evidence/batch45b"

logical_display() {
  adb -s $D shell dumpsys window windows 2>/dev/null \
    | grep -A1 "Window{.*io.legado.flutter_legado/io.legado.flutter.MainActivity}" \
    | grep -o "mDisplayId=[0-9]*" | head -1 | cut -d= -f2
}

# 逻辑 display id -> SurfaceFlinger 物理 uniqueId（解析 mViewports 的
# displayId=X, uniqueId='local:Y' 对应关系；本 ROM screencap -d <logicalId>
# 返回 Status -2，必须用物理 id）
sf_id() {
  adb -s $D shell dumpsys display 2>/dev/null \
    | tr ',' '\n' \
    | grep -E "displayId=$1$|uniqueId='local:[0-9]+'" \
    | sed "s/.*displayId=\([0-9]*\)$/DISP=\1/;s/.*uniqueId='local:\([0-9]*\)'.*/SF=\1/" \
    | awk -v want="$1" '/^DISP=/{d=substr($0,6)} /^SF=/{if(d==want) print substr($0,4)}' \
    | head -1
}

shot() {
  local name="$1"
  local sf
  sf=$(sf_id "$(logical_display)")
  adb -s $D shell screencap -p -d "$sf" /data/local/tmp/_qa.png >/dev/null 2>&1
  adb -s $D pull /data/local/tmp/_qa.png "$OUT/$name.png" >/dev/null 2>&1
  echo "shot $name -> $(stat -c%s "/d/OH-WorkSpace/LegadoTeam/legado/docs/evidence/batch45b/$name.png") bytes (sf=$sf)"
}

tap() {
  local ld
  ld=$(logical_display)
  adb -s $D shell input -d "${ld:-0}" tap "$1" "$2"
}

swipe() {
  local ld
  ld=$(logical_display)
  adb -s $D shell input -d "${ld:-0}" swipe "$1" "$2" "$3" "$4" "${5:-300}"
}

key() {
  local ld
  ld=$(logical_display)
  adb -s $D shell input -d "${ld:-0}" keyevent "$1"
}

txt() {
  local ld
  ld=$(logical_display)
  adb -s $D shell input -d "${ld:-0}" text "$1"
}

dump_ui() {
  local name="$1"
  adb -s $D shell uiautomator dump /data/local/tmp/_ui.xml >/dev/null 2>&1
  adb -s $D pull /data/local/tmp/_ui.xml "$OUT/$name.xml" >/dev/null 2>&1
  echo "dump $name -> $(stat -c%s "/d/OH-WorkSpace/LegadoTeam/legado/docs/evidence/batch45b/$name.xml") bytes"
}
