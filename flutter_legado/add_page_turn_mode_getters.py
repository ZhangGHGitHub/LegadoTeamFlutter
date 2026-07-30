#!/usr/bin/env python3
# -*- coding: utf-8 -*-

file_path = 'lib/src/providers/reader_provider.dart'

# Read the file
print(f'Reading {file_path}...')
with open(file_path, 'r', encoding='utf-8') as f:
    content = f.read()

# Replace the PageTurnMode enum to add displayName and icon getters
old_enum = """/// 翻页模式
enum PageTurnMode {
  scroll, // 上下滚动
  slide, // 左右滑动
  simulate, // 仿真翻页
  none, // 无动画（直接切换）
}"""

new_enum = """/// 翻页模式
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
}"""

content = content.replace(old_enum, new_enum)

# Write back
print(f'Writing {file_path}...')
with open(file_path, 'w', encoding='utf-8') as f:
    f.write(content)

print('Done! Added displayName and icon getters to PageTurnMode enum')
