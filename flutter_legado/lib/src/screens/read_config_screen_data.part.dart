// reader_config_screen.dart 的数据 part 文件（批1a 独立阅读设置页）。
// 行定义清单（分组/键/控件形态/值域/默认值）与下拉档位常量。
part of 'read_config_screen.dart';

/// 屏幕方向档位（对标原版 screen_direction_value 0-5）
Map<int, String> get _kScreenOrientationOptions => {
  0: AppStrings.themeSystem,
  1: AppStrings.portraitLabel,
  2: AppStrings.landscapeLabel,
  3: AppStrings.orientationAutoSensor,
  4: AppStrings.orientationPortraitReverse,
  5: AppStrings.orientationLandscapeReverse,
};

/// [批1b-1] 保持亮屏档位（键 keep_light，秒值；对标参考版
/// screen_time_out arrays：Default/1 min/5 min/10 min/Always →
/// 0/60/300/600/-1）
Map<int, String> get _kKeepLightOptions => {
  0: AppStrings.defaultLabel,
  60: AppStrings.minutes1,
  300: AppStrings.minutes5,
  600: AppStrings.minutes10,
  -1: AppStrings.keepAlways,
};

// [批1b-1] keep_light 平台通道已接通（PlatformBridgeService.setKeepScreenOn
// → Kotlin BrightnessBridge FLAG_KEEP_SCREEN_ON），本行自 1a 留位转正。

/// [批1b-1] 亮度条模式档位（键 readBrightnessMode，对标参考版
/// brightness_bar_mode_title/value：关闭/横排/竖排 → 0/1/2；
/// 消费 reader_bottom_bar（横条）与 reader_menu_panel（竖条））
Map<String, String> get _kBrightnessModeOptions => {
  '0': AppStrings.notShown,
  '1': AppStrings.horizontal,
  '2': AppStrings.vertical,
};

/// [批1b-1] 亮度条位置档位（键 readBrightnessVwPos，仅模式=竖排时显示；
/// 对标参考版 brightness_bar_position_title/value：左侧/右侧 → 0/1）
Map<String, String> get _kBrightnessPosOptions => {
  '0': AppStrings.leftSide,
  '1': AppStrings.rightSide,
};

/// 双页模式档位（对标原版 double_page_value 0-3）
Map<int, String> get _kDoublePageOptions => {
  0: AppStrings.dualPageSingle,
  1: AppStrings.dualPageDouble,
  2: AppStrings.dualPageLandscapeDouble,
  3: AppStrings.dualPageHorizontalLabel,
};

/// 进度条行为档位（对标原版 progress_bar_behavior_value）
Map<String, String> get _kProgressBarBehaviorOptions => {
  'page': AppStrings.progressBarPageAdjust,
  'chapter': AppStrings.progressBarChapterAdjust,
};
