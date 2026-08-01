#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""删除 settings_screen.dart 中的 discover 入口"""

file_path = 'lib/src/screens/settings_screen.dart'

with open(file_path, 'r', encoding='utf-8') as f:
    lines = f.readlines()

# 删除第 236-241 行（索引 235-240）
new_lines = lines[:235] + lines[241:]

with open(file_path, 'w', encoding='utf-8') as f:
    f.writelines(new_lines)

print(f"已删除第 236-241 行，文件从 {len(lines)} 行减少到 {len(new_lines)} 行")
