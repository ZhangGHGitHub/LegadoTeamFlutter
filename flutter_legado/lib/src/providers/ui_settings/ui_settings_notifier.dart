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

/// 底栏 label 显示档位（对齐参考仓 labelVisibilityMode）
enum BottomBarLabelMode {
  /// 仅选中显示 label（参考仓 "auto" 默认）
  auto,

  /// 全部常显（"labeled"）
  labeled,

  /// 纯图标（"unlabeled"）
  unlabeled;

  /// 从持久化字符串解析（未知值回退 [auto]）
  static BottomBarLabelMode fromName(String? name) {
    for (final m in BottomBarLabelMode.values) {
      if (m.name == name) return m;
    }
    return BottomBarLabelMode.auto;
  }
}

/// 平板/大屏导航形态（对齐参考仓 tabletInterface）
enum TabletInterfaceMode {
  /// 自动：sw≥600 启用 Rail（"auto" 默认）
  auto,

  /// 始终启用 Rail（"always"）
  always,

  /// 仅横屏启用（"landscape"）
  landscape,

  /// 不启用（"off"）
  off;

  /// 从持久化字符串解析（未知值回退 [auto]）
  static TabletInterfaceMode fromName(String? name) {
    for (final m in TabletInterfaceMode.values) {
      if (m.name == name) return m;
    }
    return TabletInterfaceMode.auto;
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

  /// 底栏 label 显示档位
  final BottomBarLabelMode labelVisibilityMode;

  /// 底栏不透明度 0-100
  final int bottomBarOpacity;

  /// 悬浮底栏（64dp 胶囊形态，参考仓默认关）
  final bool useFloatingBottomBar;

  /// 显示底栏（参考仓 showBottomView）
  final bool showBottomView;

  /// 平板/大屏导航形态
  final TabletInterfaceMode tabletInterface;

  /// 详情页跟随封面取色换肤
  final bool bookInfoFollowCoverColor;

  /// 详情页网络封面背景三档：off/off_for_default/on
  final String bookInfoNetworkCoverBackground;

  /// 详情页默认封面背景三档
  final String bookInfoDefaultCoverBackground;

  const UiSettingsState({
    this.topBarButtonStyle = TopBarButtonStyle.tonal,
    this.mergeTopBarActions = false,
    this.useFlexibleTopAppBar = true,
    this.topBarOpacity = 100,
    this.labelVisibilityMode = BottomBarLabelMode.auto,
    this.bottomBarOpacity = 100,
    this.useFloatingBottomBar = false,
    this.showBottomView = true,
    this.tabletInterface = TabletInterfaceMode.auto,
    this.bookInfoFollowCoverColor = true,
    this.bookInfoNetworkCoverBackground = 'on',
    this.bookInfoDefaultCoverBackground = 'on',
  });

  UiSettingsState copyWith({
    TopBarButtonStyle? topBarButtonStyle,
    bool? mergeTopBarActions,
    bool? useFlexibleTopAppBar,
    int? topBarOpacity,
    BottomBarLabelMode? labelVisibilityMode,
    int? bottomBarOpacity,
    bool? useFloatingBottomBar,
    bool? showBottomView,
    TabletInterfaceMode? tabletInterface,
    bool? bookInfoFollowCoverColor,
    String? bookInfoNetworkCoverBackground,
    String? bookInfoDefaultCoverBackground,
  }) {
    return UiSettingsState(
      topBarButtonStyle: topBarButtonStyle ?? this.topBarButtonStyle,
      mergeTopBarActions: mergeTopBarActions ?? this.mergeTopBarActions,
      useFlexibleTopAppBar: useFlexibleTopAppBar ?? this.useFlexibleTopAppBar,
      topBarOpacity: topBarOpacity ?? this.topBarOpacity,
      labelVisibilityMode: labelVisibilityMode ?? this.labelVisibilityMode,
      bottomBarOpacity: bottomBarOpacity ?? this.bottomBarOpacity,
      useFloatingBottomBar: useFloatingBottomBar ?? this.useFloatingBottomBar,
      showBottomView: showBottomView ?? this.showBottomView,
      tabletInterface: tabletInterface ?? this.tabletInterface,
      bookInfoFollowCoverColor:
          bookInfoFollowCoverColor ?? this.bookInfoFollowCoverColor,
      bookInfoNetworkCoverBackground:
          bookInfoNetworkCoverBackground ?? this.bookInfoNetworkCoverBackground,
      bookInfoDefaultCoverBackground: bookInfoDefaultCoverBackground ??
          this.bookInfoDefaultCoverBackground,
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
      labelVisibilityMode: BottomBarLabelMode.fromName(
        await _settings.getStringPref(PrefKeys.labelVisibilityMode),
      ),
      bottomBarOpacity: await _settings.getIntPref(
        PrefKeys.bottomBarOpacity,
        defaultValue: 100,
      ).then(_clampOpacity),
      useFloatingBottomBar: await _settings.getBoolPref(
        PrefKeys.useFloatingBottomBar,
        defaultValue: false,
      ),
      showBottomView: await _settings.getBoolPref(
        PrefKeys.showBottomView,
        defaultValue: true,
      ),
      tabletInterface: TabletInterfaceMode.fromName(
        await _settings.getStringPref(PrefKeys.tabletInterface),
      ),
      bookInfoFollowCoverColor: await _settings.getBoolPref(
        PrefKeys.bookInfoFollowCoverColor,
        defaultValue: true,
      ),
      bookInfoNetworkCoverBackground: await _settings.getStringPref(
        PrefKeys.bookInfoNetworkCoverBackground,
        defaultValue: 'on',
      ),
      bookInfoDefaultCoverBackground: await _settings.getStringPref(
        PrefKeys.bookInfoDefaultCoverBackground,
        defaultValue: 'on',
      ),
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

  /// 底栏 label 显示档位
  Future<void> setLabelVisibilityMode(BottomBarLabelMode mode) async {
    if (state.labelVisibilityMode == mode) return;
    state = state.copyWith(labelVisibilityMode: mode);
    _sync();
    await _settings.setStringPref(PrefKeys.labelVisibilityMode, mode.name);
  }

  /// 底栏不透明度（0-100）
  Future<void> setBottomBarOpacity(int value) async {
    final v = _clampOpacity(value);
    if (state.bottomBarOpacity == v) return;
    state = state.copyWith(bottomBarOpacity: v);
    _sync();
    await _settings.setIntPref(PrefKeys.bottomBarOpacity, v);
  }

  /// 悬浮底栏开关
  Future<void> setUseFloatingBottomBar(bool value) async {
    if (state.useFloatingBottomBar == value) return;
    state = state.copyWith(useFloatingBottomBar: value);
    _sync();
    await _settings.setBoolPref(PrefKeys.useFloatingBottomBar, value);
  }

  /// 显示底栏开关
  Future<void> setShowBottomView(bool value) async {
    if (state.showBottomView == value) return;
    state = state.copyWith(showBottomView: value);
    _sync();
    await _settings.setBoolPref(PrefKeys.showBottomView, value);
  }

  /// 平板/大屏导航形态
  Future<void> setTabletInterface(TabletInterfaceMode mode) async {
    if (state.tabletInterface == mode) return;
    state = state.copyWith(tabletInterface: mode);
    _sync();
    await _settings.setStringPref(PrefKeys.tabletInterface, mode.name);
  }

  /// 详情页跟随封面取色
  Future<void> setBookInfoFollowCoverColor(bool value) async {
    if (state.bookInfoFollowCoverColor == value) return;
    state = state.copyWith(bookInfoFollowCoverColor: value);
    _sync();
    await _settings.setBoolPref(PrefKeys.bookInfoFollowCoverColor, value);
  }

  /// 详情页背景三档（网络封面/默认封面共用三值：off/off_for_default/on）
  Future<void> setBookInfoCoverBackground({
    required bool isDefaultCover,
    required String value,
  }) async {
    if (isDefaultCover) {
      if (state.bookInfoDefaultCoverBackground == value) return;
      state = state.copyWith(bookInfoDefaultCoverBackground: value);
      _sync();
      await _settings.setStringPref(
          PrefKeys.bookInfoDefaultCoverBackground, value);
    } else {
      if (state.bookInfoNetworkCoverBackground == value) return;
      state = state.copyWith(bookInfoNetworkCoverBackground: value);
      _sync();
      await _settings.setStringPref(
          PrefKeys.bookInfoNetworkCoverBackground, value);
    }
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
