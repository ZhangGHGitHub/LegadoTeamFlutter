import sys

# Read the file
with open('lib/src/providers/reader_provider.dart', 'r', encoding='utf-8') as f:
    lines = f.readlines()

# Find and replace the enum
new_lines = []
i = 0
while i < len(lines):
    if i < len(lines) - 4 and '/// 翻页模式' in lines[i] and 'enum PageTurnMode {' in lines[i+1]:
        # Found the enum, replace it
        new_lines.append('/// 翻页模式\n')
        new_lines.append('enum PageTurnMode {\n')
        new_lines.append('  scroll, // 上下滚动\n')
        new_lines.append('  slide, // 左右滑动\n')
        new_lines.append('  simulate, // 仿真翻页\n')
        new_lines.append('  none, // 无动画（直接切换）\n')
        new_lines.append('\n')
        new_lines.append('  /// 获取显示名称\n')
        new_lines.append('  String get displayName {\n')
        new_lines.append('    switch (this) {\n')
        new_lines.append('      case PageTurnMode.scroll:\n')
        new_lines.append("        return '滚动';\n")
        new_lines.append('      case PageTurnMode.slide:\n')
        new_lines.append("        return '滑动';\n")
        new_lines.append('      case PageTurnMode.simulate:\n')
        new_lines.append("        return '仿真';\n")
        new_lines.append('      case PageTurnMode.none:\n')
        new_lines.append("        return '无动画';\n")
        new_lines.append('    }\n')
        new_lines.append('  }\n')
        new_lines.append('\n')
        new_lines.append('  /// 获取图标\n')
        new_lines.append('  String get icon {\n')
        new_lines.append('    switch (this) {\n')
        new_lines.append('      case PageTurnMode.scroll:\n')
        new_lines.append("        return '📜';\n")
        new_lines.append('      case PageTurnMode.slide:\n')
        new_lines.append("        return '👈';\n")
        new_lines.append('      case PageTurnMode.simulate:\n')
        new_lines.append("        return '📖';\n")
        new_lines.append('      case PageTurnMode.none:\n')
        new_lines.append("        return '⚡';\n")
        new_lines.append('    }\n')
        new_lines.append('  }\n')
        new_lines.append('}\n')
        # Skip the old enum lines (lines i to i+4)
        i += 5
    else:
        new_lines.append(lines[i])
        i += 1

# Write back
with open('lib/src/providers/reader_provider.dart', 'w', encoding='utf-8') as f:
    f.writelines(new_lines)

print('Successfully updated PageTurnMode enum with none value')
