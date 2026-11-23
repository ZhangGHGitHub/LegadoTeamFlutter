#!/bin/bash
# 打开顶栏按钮配置页（假定当前在阅读页且可点击）
export PATH="/d/Android/platform-tools:$PATH"; export MSYS_NO_PATHCONV=1
D=192.168.100.62:5555
cd /d/OH-WorkSpace/LegadoTeam/legado/tmp_debug/device_acceptance_20261029_batch37
dump() { adb -s $D shell "uiautomator dump /sdcard/u.xml" >/dev/null 2>&1; adb -s $D pull /sdcard/u.xml ./shots/_tmp.xml >/dev/null 2>&1; }
has() { grep -q "$1" ./shots/_tmp.xml; }
# 1) 确保设置面板打开
dump
if ! has 'content-desc="阅读界面"'; then
  if ! has 'content-desc="退出阅读"'; then adb -s $D shell input tap 540 960; sleep 2; dump; fi
  if ! has 'content-desc="退出阅读"'; then echo "ERR: 菜单未出现"; exit 1; fi
  adb -s $D shell input tap 972 1806; sleep 2; dump
  if ! has 'content-desc="阅读界面"'; then echo "ERR: 设置面板未打开"; exit 1; fi
fi
# 2) 更多 tab
adb -s $D shell input tap 909 805; sleep 2; dump
# 4) 滚到顶栏按钮
for i in 1 2 3 4 5; do
  if has '顶栏按钮'; then break; fi
  adb -s $D shell input swipe 540 1500 540 900 400; sleep 1; dump
done
if ! has '顶栏按钮'; then echo "ERR: 未找到顶栏按钮入口"; exit 1; fi
Y=$(python - <<'PY'
import re, xml.etree.ElementTree as ET
t = ET.parse('shots/_tmp.xml')
for n in t.iter():
    if (n.get('content-desc') or '').startswith('顶栏按钮'):
        m = re.match(r'\[(\d+),(\d+)\]\[(\d+),(\d+)\]', n.get('bounds'))
        if m:
            x1,y1,x2,y2 = map(int,m.groups()); print((y1+y2)//2)
PY
)
if [ "$Y" -gt 1700 ]; then adb -s $D shell input swipe 540 1500 540 1100 400; sleep 1; dump; Y=$(python - <<'PY2'
import re, xml.etree.ElementTree as ET
t = ET.parse('shots/_tmp.xml')
for n in t.iter():
    if (n.get('content-desc') or '').startswith('顶栏按钮'):
        m = re.match(r'\[(\d+),(\d+)\]\[(\d+),(\d+)\]', n.get('bounds'))
        if m:
            x1,y1,x2,y2 = map(int,m.groups()); print((y1+y2)//2)
PY2
); fi
echo "顶栏按钮 y=$Y"
adb -s $D shell input tap 540 $Y; sleep 2; dump
if ! has 'content-desc="恢复默认"'; then echo "ERR: 配置页未打开"; exit 1; fi
echo "OK: 配置页已打开"
