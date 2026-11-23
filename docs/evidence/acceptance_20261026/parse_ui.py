import re
import sys

path = sys.argv[1]
s = open(path, encoding='utf-8').read()
for m in re.finditer(r'<node[^>]*>', s):
    t = m.group(0)
    text = re.search(r'text="([^"]*)"', t)
    desc = re.search(r'content-desc="([^"]*)"', t)
    b = re.search(r'bounds="([^"]*)"', t)
    click = re.search(r'clickable="([^"]*)"', t)
    longc = re.search(r'long-clickable="([^"]*)"', t)
    tv = text.group(1) if text else ''
    dv = desc.group(1) if desc else ''
    if tv or dv:
        print("text=%r desc=%r click=%s long=%s bounds=%s" % (
            tv, dv,
            click.group(1) if click else '',
            longc.group(1) if longc else '',
            b.group(1) if b else ''))
