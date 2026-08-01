import 'package:flutter/material.dart';

import '../services/settings_service.dart';

/// 全局主题状态管理
///
/// 集中管理应用主题模式（亮/暗/跟随系统）与全局字体缩放，对齐 Android 原版
/// ThemeConfigFragment：
/// - 主题模式：经 [SettingsService.getThemeMode]/[SettingsService.setThemeMode] 持久化，
///   通过 notifyListeners 驱动 MaterialApp.themeMode 实现全局实时切换。
/// - 字体缩放：对齐原版 PreferKey.fontScale 语义——原始值 0 表示跟随系统，
///   8~16 对应 0.8x~1.6x（见 AppContextWrapper.getFontScale）。
class ThemeProvider extends ChangeNotifier {
  final SettingsService _settings;

  ThemeProvider([SettingsService? settings])
      : _settings = settings ?? SettingsService();

  ThemeMode _themeMode = ThemeMode.system;

  /// 字体缩放原始值（0 = 跟随系统；8~16 → 0.8x~1.6x）
  int _fontScaleRaw = 0;

  // ===== Getters =====

  ThemeMode get themeMode => _themeMode;
  int get fontScaleRaw => _fontScaleRaw;

  /// 是否跟随系统字体缩放（原始值为 0 或超出有效范围）
  bool get isSystemFontScale {
    final scale = _fontScaleRaw / 10.0;
    return scale < 0.8 || scale > 1.6;
  }

  /// 实际字体缩放倍数：跟随系统时返回 null（表示不覆盖系统缩放）
  double? get fontScale {
    if (isSystemFontScale) return null;
    return _fontScaleRaw / 10.0;
  }

  /// 字体缩放展示文本（对齐原版 font_scale_summary「当前字体大小：%.1f」）
  String get fontScaleLabel {
    final scale = fontScale;
    if (scale == null) return '跟随系统';
    return '当前字体大小：${scale.toStringAsFixed(1)}';
  }

  // ===== 加载与设置 =====

  /// 加载已持久化的主题设置（启动时调用一次）
  Future<void> load() async {
    _themeMode = await _settings.getThemeMode();
    _fontScaleRaw = await _settings.getFontScale();
    notifyListeners();
  }

  /// 设置主题模式（全局实时生效 + 持久化）
  Future<void> setThemeMode(ThemeMode mode) async {
    if (_themeMode == mode) return;
    _themeMode = mode;
    notifyListeners();
    await _settings.setThemeMode(mode);
  }

  /// 设置字体缩放原始值（0 = 跟随系统；8~16 → 0.8x~1.6x）
  Future<void> setFontScale(int raw) async {
    if (_fontScaleRaw == raw) return;
    _fontScaleRaw = raw;
    notifyListeners();
    await _settings.setFontScale(raw);
  }
}
