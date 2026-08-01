import sys

# Read the file
with open('lib/src/l10n/app_strings.dart', 'r', encoding='utf-8') as f:
    lines = f.readlines()

# Find the line with "settings" and add "my" after it
new_lines = []
for i, line in enumerate(lines):
    new_lines.append(line)
    if 'static String get settings =>' in line:
        # Add the "my" string after "settings"
        new_lines.append("  static String get my => _get('我的', 'My');\n")

# Write back
with open('lib/src/l10n/app_strings.dart', 'w', encoding='utf-8') as f:
    f.writelines(new_lines)

print('Added my string to app_strings.dart')
