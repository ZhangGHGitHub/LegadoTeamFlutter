#!/usr/bin/env python3
# -*- coding: utf-8 -*-

file_path = 'lib/src/providers/reader_provider.dart'

# Read the file with UTF-8 encoding
print(f'Reading {file_path}...')
with open(file_path, 'r', encoding='utf-8') as f:
    content = f.read()

# Write back with UTF-8 BOM encoding
print(f'Writing {file_path} with UTF-8 BOM...')
with open(file_path, 'w', encoding='utf-8-sig') as f:
    f.write(content)

print('Done! File rewritten with UTF-8 BOM encoding')
