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

  /// 用户设置动作计数（代数）：load 为异步，凡在 load 装配/执行期间发生的
  /// 用户设置动作，都使加载结果作废（否则启动早期切换主题/调色板会被
  /// 旧持久化值覆盖）
  int _mutationGeneration = 0;

  @override
  ThemeState build() {
    // 启动时加载持久化设置（对齐原 main.dart 的 ThemeProvider()..load()）。
    // 代数在 build 同步快照并传入 load：load 微任务被调度后、开始执行前
    // 发生的用户操作同样要使其结果作废。
    final generation = _mutationGeneration;
    Future.microtask(() => load(expectedGeneration: generation));
    return const ThemeState();
  }

  /// 加载已持久化的主题设置（启动时调用一次）
  ///
  /// [expectedGeneration]：装配本次加载时的代数快照；加载完成时代数已
  /// 变化说明期间发生了用户设置动作，本次加载结果作废（内存状态为准）。
  Future<void> load({int? expectedGeneration}) async {
    final generation = expectedGeneration ?? _mutationGeneration;
    final themeMode = await _settings.getThemeMode();
    final fontScaleRaw = await _settings.getFontScale();
    final paletteId = await _settings.getPaletteId();
    if (generation != _mutationGeneration) {
      return;
    }
    state = state.copyWith(
      themeMode: themeMode,
      fontScaleRaw: fontScaleRaw,
      paletteId: paletteId,
    );
  }

  /// 设置主题模式（全局实时生效 + 持久化）
  Future<void> setThemeMode(ThemeMode mode) async {
    if (state.themeMode == mode) return;
    _mutationGeneration++;
    state = state.copyWith(themeMode: mode);
    await _settings.setThemeMode(mode);
  }

  /// 切换日间/夜间（对齐原版 ReadMenu.fabNightTheme）
  ///
  /// 原版：`AppConfig.isNightTheme = !AppConfig.isNightTheme` 后
  /// `ThemeConfig.applyDayNight(context)`，并将 themeMode 显式写为
  /// "1"(日)/"2"(夜)。此处同样写入明确的 [ThemeMode.light]/[ThemeMode.dark]，
  /// 驱动 MaterialApp.themeMode，使书架/我的/底栏等外层即时联动。
  ///
  /// [isNight]：当前是否为夜间（通常取 `Theme.of(context).brightness == dark`）。
  Future<void> toggleDayNight({required bool isNight}) async {
    await setThemeMode(isNight ? ThemeMode.light : ThemeMode.dark);
  }

  /// 设置字体缩放原始值（0 = 跟随系统；8~16 → 0.8x~1.6x）
  Future<void> setFontScale(int raw) async {
    if (state.fontScaleRaw == raw) return;
    _mutationGeneration++;
    state = state.copyWith(fontScaleRaw: raw);
    await _settings.setFontScale(raw);
  }

  /// 设置内置 MD3 调色板（UI_MD3_PLAN.md Batch 0：全局实时生效 + 持久化；
  /// 未知 id 由 Md3Palettes.byId 回退 WH，不写入非法值）
  Future<void> setPaletteId(String id) async {
    if (state.paletteId == id) return;
    _mutationGeneration++;
    state = state.copyWith(paletteId: id);
    await _settings.setPaletteId(id);
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
