#!/usr/bin/env python3
# -*- coding: utf-8 -*-

import os

file_path = 'lib/src/l10n/app_strings.dart'

# Read the file
print(f'Reading {file_path}...')
with open(file_path, 'r', encoding='utf-8') as f:
    content = f.read()

# Find the settings line and add my after it
old_text = "  static String get settings => _get('设置', 'Settings');\n  static String get rss => _get('订阅', 'RSS');"
new_text = "  static String get settings => _get('设置', 'Settings');\n  static String get my => _get('我的', 'My');\n  static String get rss => _get('订阅', 'RSS');"

print('Replacing text...')
content = content.replace(old_text, new_text)

# Write back
print(f'Writing {file_path}...')
with open(file_path, 'w', encoding='utf-8') as f:
    f.write(content)

print('Done!')
