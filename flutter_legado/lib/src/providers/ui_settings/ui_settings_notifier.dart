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

  /// 覆写基础卡片圆角
  final bool overrideBaseCardCornerRadius;

  /// 基础卡片圆角值 4-28
  final int baseCardCornerRadius;

  /// 启用毛玻璃（BackdropFilter，默认关）
  final bool enableBlur;

  /// 顶栏模糊半径 dp
  final int topBarBlurRadius;

  /// 顶栏底色透明度 0-255
  final int topBarBlurAlpha;

  /// 悬浮底栏模糊半径 dp
  final int bottomBarBlurRadius;

  /// 悬浮底栏底色透明度 0-255
  final int bottomBarBlurAlpha;

  /// 跟随壁纸取色（Material You 动态色，Android 12+）
  final bool wallpaperColorFollow;

  /// 设置行分隔线开关
  final bool enableItemDivider;

  /// 大屏侧栏展开态（持久化）
  final bool railExtended;

  /// 阅读菜单亮度竖条开关
  final bool readMenuBrightnessVertical;

  /// 阅读菜单亮度竖条位置（left/right）
  final String readMenuBrightnessPos;

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
    this.overrideBaseCardCornerRadius = false,
    this.baseCardCornerRadius = 16,
    this.enableBlur = false,
    this.topBarBlurRadius = 24,
    this.topBarBlurAlpha = 73,
    this.bottomBarBlurRadius = 8,
    this.bottomBarBlurAlpha = 40,
    this.wallpaperColorFollow = false,
    this.enableItemDivider = false,
    this.railExtended = false,
    this.readMenuBrightnessVertical = false,
    this.readMenuBrightnessPos = 'right',
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
    bool? overrideBaseCardCornerRadius,
    int? baseCardCornerRadius,
    bool? enableBlur,
    int? topBarBlurRadius,
    int? topBarBlurAlpha,
    int? bottomBarBlurRadius,
    int? bottomBarBlurAlpha,
    bool? wallpaperColorFollow,
    bool? enableItemDivider,
    bool? railExtended,
    bool? readMenuBrightnessVertical,
    String? readMenuBrightnessPos,
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
      overrideBaseCardCornerRadius:
          overrideBaseCardCornerRadius ?? this.overrideBaseCardCornerRadius,
      baseCardCornerRadius: baseCardCornerRadius ?? this.baseCardCornerRadius,
      enableBlur: enableBlur ?? this.enableBlur,
      topBarBlurRadius: topBarBlurRadius ?? this.topBarBlurRadius,
      topBarBlurAlpha: topBarBlurAlpha ?? this.topBarBlurAlpha,
      bottomBarBlurRadius: bottomBarBlurRadius ?? this.bottomBarBlurRadius,
      bottomBarBlurAlpha: bottomBarBlurAlpha ?? this.bottomBarBlurAlpha,
      wallpaperColorFollow: wallpaperColorFollow ?? this.wallpaperColorFollow,
      enableItemDivider: enableItemDivider ?? this.enableItemDivider,
      railExtended: railExtended ?? this.railExtended,
      readMenuBrightnessVertical:
          readMenuBrightnessVertical ?? this.readMenuBrightnessVertical,
      readMenuBrightnessPos:
          readMenuBrightnessPos ?? this.readMenuBrightnessPos,
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
      overrideBaseCardCornerRadius: await _settings.getBoolPref(
        PrefKeys.overrideBaseCardCornerRadius,
        defaultValue: false,
      ),
      baseCardCornerRadius: await _settings.getIntPref(
        PrefKeys.baseCardCornerRadius,
        defaultValue: 16,
      ),
      enableBlur: await _settings.getBoolPref(
        PrefKeys.enableBlur,
        defaultValue: false,
      ),
      topBarBlurRadius: await _settings.getIntPref(
        PrefKeys.topBarBlurRadius,
        defaultValue: 24,
      ),
      topBarBlurAlpha: await _settings.getIntPref(
        PrefKeys.topBarBlurAlpha,
        defaultValue: 73,
      ),
      bottomBarBlurRadius: await _settings.getIntPref(
        PrefKeys.bottomBarBlurRadius,
        defaultValue: 8,
      ),
      bottomBarBlurAlpha: await _settings.getIntPref(
        PrefKeys.bottomBarBlurAlpha,
        defaultValue: 40,
      ),
      wallpaperColorFollow: await _settings.getBoolPref(
        PrefKeys.wallpaperColorFollow,
        defaultValue: false,
      ),
      enableItemDivider: await _settings.getBoolPref(
        PrefKeys.enableItemDivider,
        defaultValue: false,
      ),
      railExtended: await _settings.getBoolPref(
        PrefKeys.railExtended,
        defaultValue: false,
      ),
      readMenuBrightnessVertical: await _settings.getBoolPref(
        PrefKeys.readMenuBrightnessVertical,
        defaultValue: false,
      ),
      readMenuBrightnessPos: await _settings.getStringPref(
        PrefKeys.readMenuBrightnessPos,
        defaultValue: 'right',
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

  /// 圆角覆写开关
  Future<void> setOverrideBaseCardCornerRadius(bool value) async {
    if (state.overrideBaseCardCornerRadius == value) return;
    state = state.copyWith(overrideBaseCardCornerRadius: value);
    _sync();
    await _settings.setBoolPref(PrefKeys.overrideBaseCardCornerRadius, value);
  }

  /// 基础卡片圆角值（4-28，随主题重建生效）
  Future<void> setBaseCardCornerRadius(int value) async {
    final v = value.clamp(4, 28);
    if (state.baseCardCornerRadius == v) return;
    state = state.copyWith(baseCardCornerRadius: v);
    _sync();
    await _settings.setIntPref(PrefKeys.baseCardCornerRadius, v);
  }

  /// 启用毛玻璃
  Future<void> setEnableBlur(bool value) async {
    if (state.enableBlur == value) return;
    state = state.copyWith(enableBlur: value);
    _sync();
    await _settings.setBoolPref(PrefKeys.enableBlur, value);
  }

  /// 顶栏模糊半径
  Future<void> setTopBarBlurRadius(int value) async {
    final v = value.clamp(0, 48);
    if (state.topBarBlurRadius == v) return;
    state = state.copyWith(topBarBlurRadius: v);
    _sync();
    await _settings.setIntPref(PrefKeys.topBarBlurRadius, v);
  }

  /// 顶栏底色透明度（0-255）
  Future<void> setTopBarBlurAlpha(int value) async {
    final v = value.clamp(0, 255);
    if (state.topBarBlurAlpha == v) return;
    state = state.copyWith(topBarBlurAlpha: v);
    _sync();
    await _settings.setIntPref(PrefKeys.topBarBlurAlpha, v);
  }

  /// 悬浮底栏模糊半径
  Future<void> setBottomBarBlurRadius(int value) async {
    final v = value.clamp(0, 48);
    if (state.bottomBarBlurRadius == v) return;
    state = state.copyWith(bottomBarBlurRadius: v);
    _sync();
    await _settings.setIntPref(PrefKeys.bottomBarBlurRadius, v);
  }

  /// 悬浮底栏底色透明度（0-255）
  Future<void> setBottomBarBlurAlpha(int value) async {
    final v = value.clamp(0, 255);
    if (state.bottomBarBlurAlpha == v) return;
    state = state.copyWith(bottomBarBlurAlpha: v);
    _sync();
    await _settings.setIntPref(PrefKeys.bottomBarBlurAlpha, v);
  }

  /// 阅读菜单亮度竖条开关
  Future<void> setReadMenuBrightnessVertical(bool value) async {
    if (state.readMenuBrightnessVertical == value) return;
    state = state.copyWith(readMenuBrightnessVertical: value);
    _sync();
    await _settings.setBoolPref(PrefKeys.readMenuBrightnessVertical, value);
  }

  /// 阅读菜单亮度竖条位置
  Future<void> setReadMenuBrightnessPos(String value) async {
    if (state.readMenuBrightnessPos == value) return;
    state = state.copyWith(readMenuBrightnessPos: value);
    _sync();
    await _settings.setStringPref(PrefKeys.readMenuBrightnessPos, value);
  }

  /// 大屏侧栏展开态
  Future<void> setRailExtended(bool value) async {
    if (state.railExtended == value) return;
    state = state.copyWith(railExtended: value);
    _sync();
    await _settings.setBoolPref(PrefKeys.railExtended, value);
  }

  /// 设置行分隔线开关
  Future<void> setEnableItemDivider(bool value) async {
    if (state.enableItemDivider == value) return;
    state = state.copyWith(enableItemDivider: value);
    _sync();
    await _settings.setBoolPref(PrefKeys.enableItemDivider, value);
  }

  /// 跟随壁纸取色
  Future<void> setWallpaperColorFollow(bool value) async {
    if (state.wallpaperColorFollow == value) return;
    state = state.copyWith(wallpaperColorFollow: value);
    _sync();
    await _settings.setBoolPref(PrefKeys.wallpaperColorFollow, value);
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
