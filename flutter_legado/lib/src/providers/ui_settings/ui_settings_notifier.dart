// [UI_SYNC_REFACTOR B2] UI 布局设置状态：顶栏/底栏/详情/阅读菜单开关族的
// 统一加载与分发（UI_SYNC_REFACTOR_PLAN_20260905.md）。key 名对齐参考仓
// PreferKey，经 SharedPreferences 透存（Rust 不解释），改动即时全局生效。
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;

import '../../constants/pref_keys.dart';
import '../../services/settings_service.dart';

/// 顶栏按钮样式档位（对齐参考仓 TopBarButtonStyle）
enum TopBarButtonStyle {
  /// 平面：40dp 容器 / 图标 24dp，无底色（参考仓 "plain"）
  plain,

  /// tonal：36dp 容器 / 图标 20dp，secondaryContainer 底（参考仓默认 "tonal"）
  tonal,

  /// 描边：36dp 容器，透明底 + 1dp outlineVariant 描边（"outlined"）
  outlined,

  /// 玻璃：36dp 容器，surface 半透明实色（参考仓 blur 档的实色回退，"glass"）
  glass,

  /// 液态玻璃：与 [glass] 同规格实色版（参考仓 "liquid"，blur 家族接通后差异化）
  liquidGlass;

  /// 从持久化字符串解析（未知值回退 [tonal]）
  static TopBarButtonStyle fromName(String? name) {
    for (final s in TopBarButtonStyle.values) {
      if (s.name == name) return s;
    }
    return TopBarButtonStyle.tonal;
  }
}

/// UI 布局设置状态（不可变；字段按批次增量扩展）
class UiSettingsState {
  /// 顶栏按钮样式档位
  final TopBarButtonStyle topBarButtonStyle;

  /// 顶栏 actions 合并进胶囊容器
  final bool mergeTopBarActions;

  /// MediumFlexible 大顶栏形态（true=LargeTitle 系保持展开大标题）
  final bool useFlexibleTopAppBar;

  /// 顶栏不透明度 0-100
  final int topBarOpacity;

  const UiSettingsState({
    this.topBarButtonStyle = TopBarButtonStyle.tonal,
    this.mergeTopBarActions = false,
    this.useFlexibleTopAppBar = true,
    this.topBarOpacity = 100,
  });

  UiSettingsState copyWith({
    TopBarButtonStyle? topBarButtonStyle,
    bool? mergeTopBarActions,
    bool? useFlexibleTopAppBar,
    int? topBarOpacity,
  }) {
    return UiSettingsState(
      topBarButtonStyle: topBarButtonStyle ?? this.topBarButtonStyle,
      mergeTopBarActions: mergeTopBarActions ?? this.mergeTopBarActions,
      useFlexibleTopAppBar: useFlexibleTopAppBar ?? this.useFlexibleTopAppBar,
      topBarOpacity: topBarOpacity ?? this.topBarOpacity,
    );
  }
}

/// 全局 UI 布局设置监听通道
///
/// 通用组件（如 LegadoAppBar）不依赖 Riverpod scope（58+ 使用点与既有测试
/// 保持无 ProviderScope 兼容），经此 ValueListenable 订阅设置变化；
/// [UiSettingsNotifier] 在每次状态变更时同步镜像。
final ValueNotifier<UiSettingsState> uiSettingsListenable =
    ValueNotifier<UiSettingsState>(const UiSettingsState());

/// UI 布局设置 Notifier：启动加载 + 用户设置即时生效并持久化
class UiSettingsNotifier extends Notifier<UiSettingsState> {
  final SettingsService _settings = SettingsService();

  void _sync() => uiSettingsListenable.value = state;

  @override
  UiSettingsState build() {
    // 与 ThemeNotifier 同构：启动异步加载，内存状态即时返回默认值
    Future.microtask(_load);
    return const UiSettingsState();
  }

  Future<void> _load() async {
    state = UiSettingsState(
      topBarButtonStyle: TopBarButtonStyle.fromName(
        await _settings.getStringPref(PrefKeys.topBarButtonStyle),
      ),
      mergeTopBarActions: await _settings.getBoolPref(
        PrefKeys.mergeTopBarActions,
        defaultValue: false,
      ),
      useFlexibleTopAppBar: await _settings.getBoolPref(
        PrefKeys.useFlexibleTopAppBar,
        defaultValue: true,
      ),
      topBarOpacity: await _settings.getIntPref(
        PrefKeys.topBarOpacity,
        defaultValue: 100,
      ).then(_clampOpacity),
    );
    _sync();
  }

  static int _clampOpacity(int v) => v.clamp(0, 100);

  /// 顶栏按钮样式（持久化 + 全局生效）
  Future<void> setTopBarButtonStyle(TopBarButtonStyle style) async {
    if (state.topBarButtonStyle == style) return;
    state = state.copyWith(topBarButtonStyle: style);
    _sync();
    await _settings.setStringPref(PrefKeys.topBarButtonStyle, style.name);
  }

  /// 顶栏 actions 合并胶囊
  Future<void> setMergeTopBarActions(bool value) async {
    if (state.mergeTopBarActions == value) return;
    state = state.copyWith(mergeTopBarActions: value);
    _sync();
    await _settings.setBoolPref(PrefKeys.mergeTopBarActions, value);
  }

  /// MediumFlexible 大顶栏
  Future<void> setUseFlexibleTopAppBar(bool value) async {
    if (state.useFlexibleTopAppBar == value) return;
    state = state.copyWith(useFlexibleTopAppBar: value);
    _sync();
    await _settings.setBoolPref(PrefKeys.useFlexibleTopAppBar, value);
  }

  /// 顶栏不透明度（0-100）
  Future<void> setTopBarOpacity(int value) async {
    final v = _clampOpacity(value);
    if (state.topBarOpacity == v) return;
    state = state.copyWith(topBarOpacity: v);
    _sync();
    await _settings.setIntPref(PrefKeys.topBarOpacity, v);
  }
}

/// 全局 UI 布局设置 Provider
///
/// 使用方式：
/// ```dart
/// final ui = ref.watch(uiSettingsProvider);
/// ref.read(uiSettingsProvider.notifier).setTopBarButtonStyle(...);
/// ```
final uiSettingsProvider = NotifierProvider<UiSettingsNotifier, UiSettingsState>(
  UiSettingsNotifier.new,
);
