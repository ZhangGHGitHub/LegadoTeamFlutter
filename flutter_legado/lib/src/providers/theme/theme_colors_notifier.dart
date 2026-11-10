// [UI-fix v2.0.5 | 2026-08-08] 自定义主题颜色状态管理：对齐原版
// pref_config_theme.xml 日间/夜间 主色调/强调色/背景色/底部操作栏颜色
// 8 个 ColorPreference（colorPrimary/colorAccent/colorBackground/
// colorBottomBackground 及 Night 变体），接入 MaterialApp ThemeData
// 即时生效 — Qoder
//
// [批13 | 2026-11-10] App 主题 12 色槽：补齐主要/次要字体色（日夜各 2）。
// 参考版语义（ThemeSettings.kt:18-29,71-93）——6 槽 × 日夜；夜间值为 0 时
// **逐字段**继承日间，日间为 0 时回落默认常量；0 = 未设置（不是黑色），
// 色盘「重置」写透明 0。— 全栈工程师 + UI
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:shared_preferences/shared_preferences.dart';

import '../../constants/pref_keys.dart';
import '../../services/settings_service.dart';

/// 自定义主题颜色状态（颜色字段为 ARGB int，null 表示未自定义、使用内置默认）
///
/// [批13] 字体色 4 槽采用「非空 int + 0=未设置」语义（对齐参考
/// `ThemeSettings` 默认 0），与既有 8 槽的 null 语义并存：既有字段保持
/// null 语义以免影响历史行为，字体色槽位因为要与参考版备份/导入 JSON 的
/// 0 值互通，统一按 0 归一化。
class ThemeColorsState {
  /// 主要字体色默认常量（对齐参考 AppTheme.kt:120-121 的兜底值）
  static const int defaultPrimaryTextColor = 0xFF1C1B1F;

  /// 次要字体色默认常量（对齐参考 AppTheme.kt:121）
  static const int defaultSecondaryTextColor = 0xFF49454F;

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

  /// 日间主要字体色（ARGB int，0=未设置；键名 colorMD3OnSurface）
  final int primaryTextColor;

  /// 日间次要字体色（ARGB int，0=未设置；键名 colorMD3OnPrimaryContainer）
  final int secondaryTextColor;

  /// 夜间主要字体色（ARGB int，0=未设置 → 逐字段继承日间）
  final int primaryTextColorNight;

  /// 夜间次要字体色（ARGB int，0=未设置 → 逐字段继承日间）
  final int secondaryTextColorNight;

  /// 日间背景图片本地路径（对齐原版 backgroundImage；空=未设置）
  final String bgImage;

  /// 夜间背景图片本地路径（对齐原版 backgroundImageNight）
  final String bgImageNight;

  const ThemeColorsState({
    this.primary,
    this.accent,
    this.background,
    this.bottomBackground,
    this.primaryNight,
    this.accentNight,
    this.backgroundNight,
    this.bottomBackgroundNight,
    this.primaryTextColor = 0,
    this.secondaryTextColor = 0,
    this.primaryTextColorNight = 0,
    this.secondaryTextColorNight = 0,
    this.bgImage = '',
    this.bgImageNight = '',
  });

  /// 逐字段夜间继承：夜间非 0 用夜间值，否则回落日间值（日间 0 = 未设置）
  ///
  /// 对齐参考 `ThemeSettings.kt:71-93` `customColors(isDark)` 的
  /// `night.takeIf { it != 0 } ?: day` 口径——按字段继承而非整组继承。
  static int _resolveNightInherited(
    int dayValue,
    int nightValue,
    Brightness brightness,
  ) => brightness == Brightness.dark && nightValue != 0 ? nightValue : dayValue;

  /// 当前亮度下已设置的字体色（null = 日夜均未设置，调用方应保留主题内
  /// 内置 role，避免未设置时改变既有视觉）
  int? primaryTextColorFor(Brightness brightness) {
    final value = _resolveNightInherited(
      primaryTextColor,
      primaryTextColorNight,
      brightness,
    );
    return value == 0 ? null : value;
  }

  /// 当前亮度下次要字体色的已设置值（null = 未设置）
  int? secondaryTextColorFor(Brightness brightness) {
    final value = _resolveNightInherited(
      secondaryTextColor,
      secondaryTextColorNight,
      brightness,
    );
    return value == 0 ? null : value;
  }

  /// 当前亮度下主要字体色的有效值：已设置优先，否则回落默认常量
  ///
  /// 供设置页展示与单测使用；接入 ColorScheme 时用
  /// [primaryTextColorFor]（未设置不覆盖），不要让默认常量覆盖内置 role。
  int effectivePrimaryTextColor(Brightness brightness) =>
      primaryTextColorFor(brightness) ?? defaultPrimaryTextColor;

  /// 当前亮度下次要字体色的有效值：已设置优先，否则回落默认常量
  int effectiveSecondaryTextColor(Brightness brightness) =>
      secondaryTextColorFor(brightness) ?? defaultSecondaryTextColor;

  /// 按当前亮度返回应渲染的背景图路径（空串表示无图）
  String bgImageFor(Brightness brightness) =>
      brightness == Brightness.dark ? bgImageNight : bgImage;

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
      case PrefKeys.cPrimaryText:
        return primaryTextColor;
      case PrefKeys.cSecondaryText:
        return secondaryTextColor;
      case PrefKeys.cNPrimaryText:
        return primaryTextColorNight;
      case PrefKeys.cNSecondaryText:
        return secondaryTextColorNight;
      default:
        return null;
    }
  }

  /// 按偏好键生成替换单个颜色后的新状态（value 传 null 表示恢复默认）
  ///
  /// 字体色槽位把 null 归一化为 0（0 = 未设置，对齐参考版重置写透明 0）。
  ThemeColorsState withValue(String key, int? value) {
    return ThemeColorsState(
      primary: key == PrefKeys.cPrimary ? value : primary,
      accent: key == PrefKeys.cAccent ? value : accent,
      background: key == PrefKeys.cBackground ? value : background,
      bottomBackground: key == PrefKeys.cBBackground ? value : bottomBackground,
      primaryNight: key == PrefKeys.cNPrimary ? value : primaryNight,
      accentNight: key == PrefKeys.cNAccent ? value : accentNight,
      backgroundNight: key == PrefKeys.cNBackground ? value : backgroundNight,
      bottomBackgroundNight: key == PrefKeys.cNBBackground
          ? value
          : bottomBackgroundNight,
      primaryTextColor: key == PrefKeys.cPrimaryText
          ? (value ?? 0)
          : primaryTextColor,
      secondaryTextColor: key == PrefKeys.cSecondaryText
          ? (value ?? 0)
          : secondaryTextColor,
      primaryTextColorNight: key == PrefKeys.cNPrimaryText
          ? (value ?? 0)
          : primaryTextColorNight,
      secondaryTextColorNight: key == PrefKeys.cNSecondaryText
          ? (value ?? 0)
          : secondaryTextColorNight,
      bgImage: bgImage,
      bgImageNight: bgImageNight,
    );
  }

  /// 替换背景图路径后的新状态
  ThemeColorsState withBgImage({String? day, String? night}) {
    return ThemeColorsState(
      primary: primary,
      accent: accent,
      background: background,
      bottomBackground: bottomBackground,
      primaryNight: primaryNight,
      accentNight: accentNight,
      backgroundNight: backgroundNight,
      bottomBackgroundNight: bottomBackgroundNight,
      primaryTextColor: primaryTextColor,
      secondaryTextColor: secondaryTextColor,
      primaryTextColorNight: primaryTextColorNight,
      secondaryTextColorNight: secondaryTextColorNight,
      bgImage: day ?? bgImage,
      bgImageNight: night ?? bgImageNight,
    );
  }
}

/// 自定义主题颜色 Notifier（读写 SharedPreferences 并驱动 MaterialApp 重建）
class ThemeColorsNotifier extends Notifier<ThemeColorsState> {
  final SettingsService _settings = SettingsService();

  /// 读取整数字体色槽位：缺键或异常按 0（未设置）处理，兼容旧数据
  Future<int> _loadTextColor(String key) async =>
      await _settings.getIntPrefOrNull(key) ?? 0;

  @override
  ThemeColorsState build() {
    _load();
    return const ThemeColorsState();
  }

  /// 启动时异步加载持久化的自定义颜色与背景图
  Future<void> _load() async {
    state = ThemeColorsState(
      primary: await _settings.getIntPrefOrNull(PrefKeys.cPrimary),
      accent: await _settings.getIntPrefOrNull(PrefKeys.cAccent),
      background: await _settings.getIntPrefOrNull(PrefKeys.cBackground),
      bottomBackground: await _settings.getIntPrefOrNull(PrefKeys.cBBackground),
      primaryNight: await _settings.getIntPrefOrNull(PrefKeys.cNPrimary),
      accentNight: await _settings.getIntPrefOrNull(PrefKeys.cNAccent),
      backgroundNight: await _settings.getIntPrefOrNull(PrefKeys.cNBackground),
      bottomBackgroundNight: await _settings.getIntPrefOrNull(
        PrefKeys.cNBBackground,
      ),
      primaryTextColor: await _loadTextColor(PrefKeys.cPrimaryText),
      secondaryTextColor: await _loadTextColor(PrefKeys.cSecondaryText),
      primaryTextColorNight: await _loadTextColor(PrefKeys.cNPrimaryText),
      secondaryTextColorNight: await _loadTextColor(PrefKeys.cNSecondaryText),
      bgImage: await _settings.getStringPref(PrefKeys.bgImage),
      bgImageNight: await _settings.getStringPref(PrefKeys.bgImageN),
    );
  }

  /// 设置日间/夜间背景图片路径（空串或 null = 清除；对齐原版 decorView 背景图）
  Future<void> setBgImage({String? day, String? night}) async {
    final nextDay = day ?? state.bgImage;
    final nextNight = night ?? state.bgImageNight;
    state = state.withBgImage(day: nextDay, night: nextNight);
    if (day != null) {
      if (day.isEmpty) {
        await _settings.removePref(PrefKeys.bgImage);
      } else {
        await _settings.setStringPref(PrefKeys.bgImage, day);
      }
    }
    if (night != null) {
      if (night.isEmpty) {
        await _settings.removePref(PrefKeys.bgImageN);
      } else {
        await _settings.setStringPref(PrefKeys.bgImageN, night);
      }
    }
  }

  /// 设置单个自定义颜色并持久化（value 传 null/0 表示恢复内置默认色）
  ///
  /// 0 在参考版语义里代表「未设置」（色盘重置写透明 #00000000），因此
  /// 0 与 null 一样按清除处理，避免把「未设置」当成透明黑色落盘。
  Future<void> setColor(String key, int? value) async {
    state = state.withValue(key, value);
    if (value == null || value == 0) {
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
        if (value == null || value == 0) {
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
