# Add flipMode to ReaderAdvancedConfig

file_path = 'lib/src/screens/reader_config_panel.dart'

# Read the file
with open(file_path, 'r', encoding='utf-8') as f:
    lines = f.readlines()

# Find the line with "import 'dart:async';" and add flip_mode import after it
new_lines = []
for i, line in enumerate(lines):
    new_lines.append(line)
    if line.strip() == "import 'dart:async';":
        new_lines.append("\n")
        new_lines.append("import '../models/flip_mode.dart';\n")

# Write back
with open(file_path, 'w', encoding='utf-8') as f:
    f.writelines(new_lines)

print(f'Added flip_mode import to {file_path}')
