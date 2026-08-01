# Read all lines
with open('lib/src/l10n/app_strings.dart', 'r', encoding='utf-8') as f:
    lines = f.readlines()

# Insert the new line after line 18 (settings line)
# Line 18 is index 17 (0-based)
insert_index = 18  # After line 18
new_line = "  static String get my => _get('我的', 'My');\n"

# Insert the new line
lines.insert(insert_index, new_line)

# Write back
with open('lib/src/l10n/app_strings.dart', 'w', encoding='utf-8') as f:
    f.writelines(lines)

print(f'Successfully added "my" string at line {insert_index + 1}')
