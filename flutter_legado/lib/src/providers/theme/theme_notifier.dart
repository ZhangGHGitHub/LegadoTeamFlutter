import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;

import '../../services/settings_service.dart';
import 'theme_state.dart';

export 'theme_state.dart';

/// 全局主题 Riverpod Notifier
///
/// 集中管理应用主题模式（亮/暗/跟随系统）与全局字体缩放，对齐 Android 原版
/// ThemeConfigFragment：
/// - 主题模式：经 [SettingsService.getThemeMode]/[SettingsService.setThemeMode] 持久化，
///   通过更新 immutable State 驱动 MaterialApp.themeMode 实现全局实时切换。
/// - 字体缩放：对齐原版 PreferKey.fontScale 语义——原始值 0 表示跟随系统，
///   8~16 对应 0.8x~1.6x（见 AppContextWrapper.getFontScale）。
class ThemeNotifier extends Notifier<ThemeState> {
  final SettingsService _settings = SettingsService();

  @override
  ThemeState build() {
    // 启动时加载持久化设置（对齐原 main.dart 的 ThemeProvider()..load()）
    Future.microtask(load);
    return const ThemeState();
  }

  /// 加载已持久化的主题设置（启动时调用一次）
  Future<void> load() async {
    final themeMode = await _settings.getThemeMode();
    final fontScaleRaw = await _settings.getFontScale();
    state = state.copyWith(themeMode: themeMode, fontScaleRaw: fontScaleRaw);
  }

  /// 设置主题模式（全局实时生效 + 持久化）
  Future<void> setThemeMode(ThemeMode mode) async {
    if (state.themeMode == mode) return;
    state = state.copyWith(themeMode: mode);
    await _settings.setThemeMode(mode);
  }

  /// 设置字体缩放原始值（0 = 跟随系统；8~16 → 0.8x~1.6x）
  Future<void> setFontScale(int raw) async {
    if (state.fontScaleRaw == raw) return;
    state = state.copyWith(fontScaleRaw: raw);
    await _settings.setFontScale(raw);
  }
}

/// 全局主题 Notifier Provider
///
/// 使用方式：
/// ```dart
/// final state = ref.watch(themeNotifierProvider);
/// ref.read(themeNotifierProvider.notifier).setThemeMode(ThemeMode.dark);
/// ```
final themeNotifierProvider = NotifierProvider<ThemeNotifier, ThemeState>(
  ThemeNotifier.new,
);
