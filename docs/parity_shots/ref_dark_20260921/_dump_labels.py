import re, sys

path = sys.argv[1] if len(sys.argv) > 1 else "_tmp_u_home_gray.xml"
xml = open(path, encoding="utf-8").read()
print("len", len(xml))
pat = re.compile(r'<node [^>]*?text="([^"]+)"[^>]*?bounds="(\[[^"]+)"', re.S)
seen = set()
for m in pat.finditer(xml):
    t, b = m.group(1), m.group(2)
    if t.strip() and (t, b) not in seen:
        seen.add((t, b))
        print(repr(t), b)
# also clickable views with content-desc
pat2 = re.compile(r'<node [^>]*?content-desc="([^"]+)"[^>]*?bounds="(\[[^"]+)"', re.S)
for m in pat2.finditer(xml):
    t, b = m.group(1), m.group(2)
    if t.strip():
        print("desc:", repr(t), b)
