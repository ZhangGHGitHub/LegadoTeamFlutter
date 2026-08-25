# -*- coding: utf-8 -*-
import re
import sys

sys.stdout.reconfigure(encoding="utf-8")
path = sys.argv[1]
xml = open(path, encoding="utf-8").read()
pat = re.compile(
    r'(?:content-desc|text)="([^"]*)"[^>]*bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"'
)
seen = set()
print("=== interesting ===")
for m in pat.finditer(xml):
    t = m.group(1)
    if not t or t == "null":
        continue
    key = (t, m.group(2), m.group(3))
    if key in seen:
        continue
    seen.add(key)
    keys = ["书架", "发现", "订阅", "我的", "Tab", "搜索", "菜单", "Show", "全部", "本地", "添加", "更多", "书源", "设置", "阅读", "返回", "Back"]
    if any(k in t for k in keys):
        print(f"{t!r} bounds=[{m.group(2)},{m.group(3)}][{m.group(4)},{m.group(5)}]")

print("=== all labels ===")
labels = []
for m in pat.finditer(xml):
    t = m.group(1)
    if t and t != "null" and t not in labels:
        labels.append(t)
print(" | ".join(labels[:60]))
