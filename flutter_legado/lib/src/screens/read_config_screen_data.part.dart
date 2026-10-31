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

/// [批1b-1] 保持亮屏档位（键 keep_light，秒值；对标参考版
/// screen_time_out arrays：Default/1 min/5 min/10 min/Always →
/// 0/60/300/600/-1）
const _kKeepLightOptions = <int, String>{
  0: '默认',
  60: '1 分钟',
  300: '5 分钟',
  600: '10 分钟',
  -1: '常亮',
};

// [批1b-1] keep_light 平台通道已接通（PlatformBridgeService.setKeepScreenOn
// → Kotlin BrightnessBridge FLAG_KEEP_SCREEN_ON），本行自 1a 留位转正。

/// [批1b-1] 亮度条模式档位（键 readBrightnessMode，对标参考版
/// brightness_bar_mode_title/value：关闭/横排/竖排 → 0/1/2；
/// 消费 reader_bottom_bar（横条）与 reader_menu_panel（竖条））
const _kBrightnessModeOptions = <String, String>{
  '0': '不显示',
  '1': '横排',
  '2': '竖排',
};

/// [批1b-1] 亮度条位置档位（键 readBrightnessVwPos，仅模式=竖排时显示；
/// 对标参考版 brightness_bar_position_title/value：左侧/右侧 → 0/1）
const _kBrightnessPosOptions = <String, String>{
  '0': '左侧',
  '1': '右侧',
};

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

