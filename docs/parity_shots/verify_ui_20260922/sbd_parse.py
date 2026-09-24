# -*- coding: utf-8 -*-
"""sbd_parse.py — parse uiautomator dump XML, print nodes with bounds.

usage:
  python sbd_parse.py <dump.xml> [top]      # top: only nodes with y1 < 220
  python sbd_parse.py <dump.xml> region y1 y2
  python sbd_parse.py <dump.xml> text       # unique content-desc list
"""
import re
import sys


def parse_nodes(xml: str):
    out = []
    for n in re.findall(r'<node ([^>]*?)/>', xml):
        attrs = dict(
            re.findall(r'([a-z-]+)="((?:[^"\\]|\\.)*)"', n)
        )
        b = attrs.get("bounds")
        if not b:
            continue
        m = re.match(r"\[(\d+),(\d+)\]\[(\d+),(\d+)\]", b)
        if not m:
            continue
        x1, y1, x2, y2 = map(int, m.groups())
        out.append((x1, y1, x2, y2, attrs))
    return out


def main():
    path = sys.argv[1]
    xml = open(path, encoding="utf-8").read()
    nodes = parse_nodes(xml)
    mode = sys.argv[2] if len(sys.argv) > 2 else "all"
    if mode == "top":
        sel = [n for n in nodes if n[1] < 220]
    elif mode == "region":
        y1, y2 = int(sys.argv[3]), int(sys.argv[4])
        sel = [n for n in nodes if n[1] >= y1 and n[3] <= y2]
    elif mode == "text":
        seen = set()
        for n in nodes:
            d = n[4].get("content-desc", "")
            if d and d not in seen:
                seen.add(d)
                print(repr(d)[:120])
        return
    else:
        sel = nodes
    for x1, y1, x2, y2, a in sel:
        cd = a.get("content-desc", "")
        print(
            f"[{x1},{y1}][{x2},{y2}] class={a.get('class','?')[-12:]} "
            f"clk={a.get('clickable','?')[:1]} {cd[:70]!r}"
        )


if __name__ == "__main__":
    main()
