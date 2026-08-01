import re

with open('lib/src/providers/reader_provider.dart', 'r', encoding='utf-8') as f:
    content = f.read()

old_enum = '''/// 翻页模式
enum PageTurnMode {
  scroll, // 上下滚动
  slide, // 左右滑动
  simulate, // 仿真翻页
}'''

new_enum = '''/// 翻页模式
enum PageTurnMode {
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

content = content.replace(old_enum, new_enum)

with open('lib/src/providers/reader_provider.dart', 'w', encoding='utf-8') as f:
    f.write(content)

print('Successfully updated PageTurnMode enum')
