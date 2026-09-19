# -*- coding: utf-8 -*-
import re, sys

path = sys.argv[1] if len(sys.argv) > 1 else "ui_probe1.xml"
xml = open(path, encoding="utf-8").read()
keywords = sys.argv[2].split("|") if len(sys.argv) > 2 else []
for m in re.finditer(r"<node[^>]*/?>", xml):
    t = m.group(0)
    if not keywords or any(k in t for k in keywords):
        # compact: text / content-desc / bounds / class
        txt = re.search(r'text="([^"]*)"', t)
        cd = re.search(r'content-desc="([^"]*)"', t)
        b = re.search(r'bounds="([^"]*)"', t)
        cls = re.search(r'class="([^"]*)"', t)
        print(
            (txt.group(1) if txt else "")
            + " | desc=" + (cd.group(1) if cd else "")
            + " | " + (cls.group(1).split(".")[-1] if cls else "?")
            + " " + (b.group(1) if b else "")
        )
