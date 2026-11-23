#!/bin/bash
export MSYS_NO_PATHCONV=1
ADB="D:/Program Files/MuMuPlayer/nx_main/adb.exe"
D=192.168.100.62:5555
OUT="D:/OH-WorkSpace/LegadoTeam/legado/tmp_debug/device_acceptance_20261101_batch2b1b1/data"
"$ADB" -s $D shell uiautomator dump /sdcard/ui.xml >/dev/null 2>&1
"$ADB" -s $D pull /sdcard/ui.xml "$OUT/ui.xml" >/dev/null 2>&1
python - "$OUT/ui.xml" <<'PY'
import re,sys
p=sys.argv[1]
s=open(p,encoding='utf-8',errors='replace').read()
for m in re.finditer(r'<node [^>]*>', s):
    t=m.group(0)
    def g(k):
        mm=re.search(k+r'="([^"]*)"', t)
        return mm.group(1) if mm else ''
    txt=g('text'); desc=g('content-desc'); cls=g('class')
    b=g('bounds'); click=g('clickable'); chk=g('checked'); scroll=g('scrollable')
    if txt or desc:
        print(f'{b} {cls.split(".")[-1]} click={click} chk={chk} scroll={scroll} text={txt!r} desc={desc!r}')
PY
