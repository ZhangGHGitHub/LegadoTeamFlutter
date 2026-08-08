// [UI-fix v2.0.5 | 2026-08-08] 自定义主题颜色状态管理：对齐原版
// pref_config_theme.xml 日间/夜间 主色调/强调色/背景色/底部操作栏颜色
// 8 个 ColorPreference（colorPrimary/colorAccent/colorBackground/
// colorBottomBackground 及 Night 变体），接入 MaterialApp ThemeData
// 即时生效 — Qoder
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:shared_preferences/shared_preferences.dart';

import '../../constants/pref_keys.dart';
import '../../services/settings_service.dart';

/// 自定义主题颜色状态（字段为 ARGB int，null 表示未自定义、使用内置默认）
class ThemeColorsState {
  /// 日间主色调（对齐原版 colorPrimary，映射 AppBar 背景）
  final int? primary;

  /// 日间强调色（对齐原版 colorAccent，映射全局 Tint）
  final int? accent;

  /// 日间背景色（对齐原版 colorBackground，映射 Scaffold 背景）
  final int? background;

  /// 日间底部操作栏颜色（对齐原版 colorBottomBackground，映射底部 TabBar 背景）
  final int? bottomBackground;

  /// 夜间主色调（colorPrimaryNight）
  final int? primaryNight;

  /// 夜间强调色（colorAccentNight）
  final int? accentNight;

  /// 夜间背景色（colorBackgroundNight）
  final int? backgroundNight;

  /// 夜间底部操作栏颜色（colorBottomBackgroundNight）
  final int? bottomBackgroundNight;

  const ThemeColorsState({
    this.primary,
    this.accent,
    this.background,
    this.bottomBackground,
    this.primaryNight,
    this.accentNight,
    this.backgroundNight,
    this.bottomBackgroundNight,
  });

  /// 按偏好键返回对应颜色值（供设置页展示当前值）
  int? valueOf(String key) {
    switch (key) {
      case PrefKeys.cPrimary:
        return primary;
      case PrefKeys.cAccent:
        return accent;
      case PrefKeys.cBackground:
        return background;
      case PrefKeys.cBBackground:
        return bottomBackground;
      case PrefKeys.cNPrimary:
        return primaryNight;
      case PrefKeys.cNAccent:
        return accentNight;
      case PrefKeys.cNBackground:
        return backgroundNight;
      case PrefKeys.cNBBackground:
        return bottomBackgroundNight;
      default:
        return null;
    }
  }

  /// 按偏好键生成替换单个颜色后的新状态（value 传 null 表示恢复默认）
  ThemeColorsState withValue(String key, int? value) {
    return ThemeColorsState(
      primary: key == PrefKeys.cPrimary ? value : primary,
      accent: key == PrefKeys.cAccent ? value : accent,
      background: key == PrefKeys.cBackground ? value : background,
      bottomBackground: key == PrefKeys.cBBackground ? value : bottomBackground,
      primaryNight: key == PrefKeys.cNPrimary ? value : primaryNight,
      accentNight: key == PrefKeys.cNAccent ? value : accentNight,
      backgroundNight: key == PrefKeys.cNBackground ? value : backgroundNight,
      bottomBackgroundNight:
          key == PrefKeys.cNBBackground ? value : bottomBackgroundNight,
    );
  }
}

/// 自定义主题颜色 Notifier（读写 SharedPreferences 并驱动 MaterialApp 重建）
class ThemeColorsNotifier extends Notifier<ThemeColorsState> {
  final SettingsService _settings = SettingsService();

  @override
  ThemeColorsState build() {
    _load();
    return const ThemeColorsState();
  }

  /// 启动时异步加载持久化的自定义颜色
  Future<void> _load() async {
    state = ThemeColorsState(
      primary: await _settings.getIntPrefOrNull(PrefKeys.cPrimary),
      accent: await _settings.getIntPrefOrNull(PrefKeys.cAccent),
      background: await _settings.getIntPrefOrNull(PrefKeys.cBackground),
      bottomBackground: await _settings.getIntPrefOrNull(PrefKeys.cBBackground),
      primaryNight: await _settings.getIntPrefOrNull(PrefKeys.cNPrimary),
      accentNight: await _settings.getIntPrefOrNull(PrefKeys.cNAccent),
      backgroundNight: await _settings.getIntPrefOrNull(PrefKeys.cNBackground),
      bottomBackgroundNight:
          await _settings.getIntPrefOrNull(PrefKeys.cNBBackground),
    );
  }

  /// 设置单个自定义颜色并持久化（value 传 null 表示恢复内置默认色）
  Future<void> setColor(String key, int? value) async {
    state = state.withValue(key, value);
    if (value == null) {
      await _settings.removePref(key);
    } else {
      await _settings.setIntPref(key, value);
    }
  }

  /// 批量应用一组主题颜色（用于主题列表切换预设配置）
  ///
  /// [UI-fix v2.0.5 | 2026-08-08] SettingsService 无批量写入 API，此处
  /// 直接复用单次 SharedPreferences 实例批量写入，避免每键重复
  /// getInstance；state 赋值移到全部持久化完成之后，持久化异常时
  /// 不更新内存状态，保证状态与存储不撕裂 — Qoder
  Future<void> applyColors(Map<String, int?> colors) async {
    var next = state;
    for (final entry in colors.entries) {
      next = next.withValue(entry.key, entry.value);
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      for (final entry in colors.entries) {
        final value = entry.value;
        if (value == null) {
          await prefs.remove(entry.key);
        } else {
          await prefs.setInt(entry.key, value);
        }
      }
    } catch (e) {
      debugPrint('ThemeColorsNotifier.applyColors 持久化异常: $e');
      return;
    }
    state = next;
  }
}

/// 自定义主题颜色全局 Provider
final themeColorsProvider =
    NotifierProvider<ThemeColorsNotifier, ThemeColorsState>(
  ThemeColorsNotifier.new,
);
