import re, sys
data = open('data/ui_checking2b.xml',encoding='utf-8').read()
texts = re.findall(u'text="([^"]+)"', data)
seen = []
for t in texts:
    if t and t not in seen:
        seen.append(t)
sys.stdout.write(str(len(seen)) + '\n')
for t in seen:
    sys.stdout.write(repr(t[:110]) + '\n')
