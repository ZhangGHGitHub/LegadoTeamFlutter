# 从 uiautomator dump 提取 text/content-desc 及中心坐标
import sys, re
from xml.etree import ElementTree as ET
p = sys.argv[1]
t = ET.parse(p)
for n in t.iter():
    txt = (n.get('text') or '').strip()
    desc = (n.get('content-desc') or '').strip()
    if not txt and not desc: continue
    b = n.get('bounds','')
    m = re.match(r'\[(\d+),(\d+)\]\[(\d+),(\d+)\]', b)
    cx = cy = ''
    if m:
        x1,y1,x2,y2 = map(int, m.groups()); cx=(x1+x2)//2; cy=(y1+y2)//2
    print(f"{n.get('class','').split('.')[-1]:<18} ({cx},{cy}) text={txt!r} desc={desc!r}")
