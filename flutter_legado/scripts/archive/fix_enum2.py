# Read the file
with open('lib/src/providers/reader_provider.dart', 'r', encoding='utf-8') as f:
    content = f.read()

# Replace the enum definition
old_enum = '''enum PageTurnMode {
  scroll, // 上下滚动
  slide, // 左右滑动
  simulate, // 仿真翻页
}'''

new_enum = '''enum PageTurnMode {
  scroll, // 上下滚动
  slide, // 左右滑动
  simulate, // 仿真翻页
  none, // 无动画（直接切换）

  /// 获取显示名称
  String get displayName {
    switch (this) {
      case PageTurnMode.scroll:
        return '滚动';
      case PageTurnMode.slide:
        return '滑动';
      case PageTurnMode.simulate:
        return '仿真';
      case PageTurnMode.none:
        return '无动画';
    }
  }

  /// 获取图标
  String get icon {
    switch (this) {
      case PageTurnMode.scroll:
        return '📜';
      case PageTurnMode.slide:
        return '👈';
      case PageTurnMode.simulate:
        return '📖';
      case PageTurnMode.none:
        return '⚡';
    }
  }
}'''

if old_enum in content:
    content = content.replace(old_enum, new_enum)
    print('Found and replaced enum')
else:
    print('ERROR: Could not find old_enum pattern')
    print('Looking for:')
    print(repr(old_enum))

# Write back
with open('lib/src/providers/reader_provider.dart', 'w', encoding='utf-8') as f:
    f.write(content)

print('Done')
