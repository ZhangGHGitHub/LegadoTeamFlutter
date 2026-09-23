# -*- coding: utf-8 -*-
"""P29 dump 查看器：解析 uiautomator dump XML，列出含 text/content-desc 的节点。
用法:
  python p29_dumpview.py <dump.xml> [关键词] [关键词2 ...]
  无关键词：列出全部有 text 或 content-desc 的节点（前 80 个）
  有关键词：只打印命中的节点（text/desc 含任一关键词，大小写敏感）
"""
import re
import sys


def main() -> None:
    if len(sys.argv) < 2:
        print("用法: python p29_dumpview.py <dump.xml> [关键词...]")
        return
    xml = open(sys.argv[1], encoding="utf-8", errors="replace").read()
    kws = sys.argv[2:]
    nodes = re.findall(r"<node[^>]+/?>", xml)
    print(f"== {sys.argv[1]} | total nodes: {len(nodes)}")
    shown = 0
    for n in nodes:
        t = re.search(r'text="([^"]*)"', n)
        d = re.search(r'content-desc="([^"]*)"', n)
        b = re.search(r'bounds="([^"]*)"', n)
        cls = re.search(r'class="([^"]*)"', n)
        tv, dv = t.group(1) if t else "", d.group(1) if d else ""
        if not (tv or dv):
            continue
        if kws and not any(k in tv or k in dv for k in kws):
            continue
        label = tv if tv else f"[desc]{dv}"
        print(f"  {label!r:70} {b.group(1) if b else '?'} | {cls.group(1) if cls else '?'}")
        shown += 1
        if not kws and shown >= 80:
            print("  ...(截断，前80)")
            break
    if kws and shown == 0:
        print("  (无命中)")


if __name__ == "__main__":
    main()
