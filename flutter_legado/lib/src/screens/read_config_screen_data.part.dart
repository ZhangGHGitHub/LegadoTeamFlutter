// reader_config_screen.dart 的数据 part 文件（批1a 独立阅读设置页）。
// 行定义清单（分组/键/控件形态/值域/默认值）与下拉档位常量。
part of 'read_config_screen.dart';

/// 屏幕方向档位（对标原版 screen_direction_value 0-5）
const _kScreenOrientationOptions = <int, String>{
  0: '跟随系统',
  1: '竖屏',
  2: '横屏',
  3: '自动(传感器)',
  4: '反向竖屏',
  5: '反向横屏',
};

// keep_light（保持亮屏/屏幕超时）有字段无消费（reader_screen.dart:235 诚实
// 标注仅持久化），按「禁新造死开关」不放入本页，留 1b 平台通道接线后补行。

/// 双页模式档位（对标原版 double_page_value 0-3）
const _kDoublePageOptions = <int, String>{
  0: '单页',
  1: '双页',
  2: '横屏双页',
  3: '平板或横屏双页',
};

/// 进度条行为档位（对标原版 progress_bar_behavior_value）
const _kProgressBarBehaviorOptions = <String, String>{
  'page': '调整本章页数',
  'chapter': '调整章节位置',
};

