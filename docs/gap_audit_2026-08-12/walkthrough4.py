# -*- coding: utf-8 -*-
import re, subprocess, time, sys
from pathlib import Path
sys.stdout.reconfigure(encoding="utf-8")
ADB=r"D:\Android\platform-tools\adb.exe"; DEV="emulator-5556"
OUT=Path(r"D:\OH-WorkSpace\LegadoTeam\legado\docs\gap_audit_2026-08-12")
PKG="io.legado.flutter_legado"; ACT="io.legado.flutter.MainActivity"

def adb(*a): subprocess.run([ADB,"-s",DEV,*a],capture_output=True)
def dump(n):
    adb("shell","uiautomator","dump","/sdcard/ui_dump.xml")
    p=OUT/f"{n}.xml"; adb("pull","/sdcard/ui_dump.xml",str(p)); return p.read_text(encoding="utf-8")
def shot(n):
    adb("shell","screencap","-p",f"/sdcard/{n}.png"); adb("pull",f"/sdcard/{n}.png",str(OUT/f"{n}.png"))
def parse(xml):
    ns=[]
    for m in re.finditer(r'content-desc="([^"]*)"[^>]*bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"',xml):
        d=m.group(1).replace("&#10;","\n")
        if not d: continue
        x1,y1,x2,y2=map(int,m.groups()[1:]); ns.append({"desc":d,"cx":(x1+x2)//2,"cy":(y1+y2)//2})
    return ns
def lab(ns):
    o=[]
    for n in ns:
        d=n["desc"].split("\n")[0][:40]
        if d not in o: o.append(d)
    return " | ".join(o[:40])
def find(ns,s):
    for n in ns:
        if s in n["desc"]: return n
def tap(n):
    if not n: return False
    adb("shell","input","tap",str(n["cx"]),str(n["cy"])); time.sleep(1); return True
def back():
    adb("shell","input","keyevent","4"); time.sleep(0.7)

# JS source stub
adb("shell","am","force-stop",PKG); time.sleep(0.5)
adb("shell","am","start","-n",f"{PKG}/{ACT}"); time.sleep(2.5)
adb("shell","input","tap","630","1220"); time.sleep(1)
for _ in range(2):
    adb("shell","input","swipe","360","400","360","1100","280"); time.sleep(0.3)
ns=parse(dump("tmp"))
tap(find(ns,"书源管理")); time.sleep(1)
ns=parse(dump("tmp"))
m=find(ns,"更多选项") or find(ns,"Show menu") or find(ns,"更多")
tap(m); time.sleep(0.6)
ns=parse(dump("tmp"))
print("overflow",lab(ns))
if tap(find(ns,"JS")):
    time.sleep(0.8); dump("42_js_source_stub"); shot("42_js_source_stub")
    print("js",lab(parse((OUT/"42_js_source_stub.xml").read_text(encoding="utf-8"))))
back(); back()

# domain group stub
adb("shell","am","start","-n",f"{PKG}/{ACT}"); time.sleep(1.5)
adb("shell","input","tap","630","1220"); time.sleep(0.8)
for _ in range(2):
    adb("shell","input","swipe","360","400","360","1100","280"); time.sleep(0.3)
tap(find(parse(dump("tmp")),"书源管理")); time.sleep(1)
ns=parse(dump("tmp"))
tap(find(ns,"更多选项") or find(ns,"Show menu") or find(ns,"更多")); time.sleep(0.5)
ns=parse(dump("tmp"))
if tap(find(ns,"域名")):
    time.sleep(0.8); dump("45_domain_group_stub"); shot("45_domain_group_stub")
    print("domain",lab(parse((OUT/"45_domain_group_stub.xml").read_text(encoding="utf-8"))))
back(); back()

# group manage stub via 分组 button
adb("shell","am","start","-n",f"{PKG}/{ACT}"); time.sleep(1.5)
adb("shell","input","tap","630","1220"); time.sleep(0.8)
for _ in range(2):
    adb("shell","input","swipe","360","400","360","1100","280"); time.sleep(0.3)
tap(find(parse(dump("tmp")),"书源管理")); time.sleep(1)
ns=parse(dump("tmp"))
if tap(find(ns,"分组")):
    time.sleep(0.6); dump("43_source_group"); shot("43_source_group")
    ns=parse((OUT/"43_source_group.xml").read_text(encoding="utf-8")); print("group",lab(ns))
    if tap(find(ns,"分组管理") or find(ns,"管理")):
        time.sleep(0.8); dump("44_source_group_manage_stub"); shot("44_source_group_manage_stub")
        print("gm",lab(parse((OUT/"44_source_group_manage_stub.xml").read_text(encoding="utf-8"))))
back(); back()

# MCP + backup + autotask from mine
adb("shell","am","start","-n",f"{PKG}/{ACT}"); time.sleep(1.5)
adb("shell","input","tap","630","1220"); time.sleep(1)
for _ in range(2):
    adb("shell","input","swipe","360","400","360","1100","280"); time.sleep(0.3)
for key,fname in [("定时任务","14_flutter_autotask"),("备份","13_flutter_backup"),("MCP","17_flutter_mcp"),("词典","15_flutter_dict"),("TXT","16_flutter_txttoc"),("阅读记录","10_flutter_read_record")]:
    ns=parse(dump("tmp"))
    n=find(ns,key)
    if not n:
        adb("shell","input","swipe","360","950","360","500","300"); time.sleep(0.5)
        ns=parse(dump("tmp")); n=find(ns,key)
    if tap(n):
        time.sleep(1); dump(fname); shot(fname)
        print(fname, lab(parse((OUT/f"{fname}.xml").read_text(encoding="utf-8"))))
        back(); time.sleep(0.5)
    else:
        print("miss", key)

print("DONE")
