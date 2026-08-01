import sys

# Read the file
with open('lib/src/providers/reader_provider.dart', 'r', encoding='utf-8') as f:
    lines = f.readlines()

# Replace lines 11-15 (0-indexed: 10-14) with the new enum
new_enum_lines = [
    'enum PageTurnMode {\n',
    '  scroll, // 上下滚动\n',
    '  slide, // 左右滑动\n',
    '  simulate, // 仿真翻页\n',
    '  none, // 无动画（直接切换）\n',
    '\n',
    '  /// 获取显示名称\n',
    '  String get displayName {\n',
    '    switch (this) {\n',
    '      case PageTurnMode.scroll:\n',
    "        return '滚动';\n",
    '      case PageTurnMode.slide:\n',
    "        return '滑动';\n",
    '      case PageTurnMode.simulate:\n',
    "        return '仿真';\n",
    '      case PageTurnMode.none:\n',
    "        return '无动画';\n",
    '    }\n',
    '  }\n',
    '\n',
    '  /// 获取图标\n',
    '  String get icon {\n',
    '    switch (this) {\n',
    '      case PageTurnMode.scroll:\n',
    "        return '📜';\n",
    '      case PageTurnMode.slide:\n',
    "        return '👈';\n",
    '      case PageTurnMode.simulate:\n',
    "        return '📖';\n",
    '      case PageTurnMode.none:\n',
    "        return '⚡';\n",
    '    }\n',
    '  }\n',
    '}\n',
]

# Replace lines 10-14 (0-indexed) with new enum
lines[10:15] = new_enum_lines

with open('lib/src/providers/reader_provider.dart', 'w', encoding='utf-8') as f:
    f.writelines(lines)

print('Successfully updated PageTurnMode enum')
