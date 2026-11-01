// [UI_SYNC_REFACTOR B2] UI 布局设置状态：顶栏/底栏/详情/阅读菜单开关族的
// 统一加载与分发（UI_SYNC_REFACTOR_PLAN_20260905.md）。key 名对齐参考仓
// PreferKey，经 SharedPreferences 透存（Rust 不解释），改动即时全局生效。
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;

import '../../constants/pref_keys.dart';
import '../../services/settings_service.dart';
import '../../services/theme_background_image_store.dart';

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

  /// 基础卡片圆角值 0-40（0=直角；参考版滑杆 0..40）
  final int baseCardCornerRadius;

  /// 覆写基础卡片边框（参考版 overrideBaseCardBorder，默认关）
  final bool overrideBaseCardBorder;

  /// 基础卡片边框宽度 dp 0-5（0=不绘制）
  final int baseCardBorderWidth;

  /// 日间卡片边框颜色 ARGB（0=跟随主题 outlineVariant）
  final int baseCardBorderColor;

  /// 夜间卡片边框颜色 ARGB（0=跟随主题 outlineVariant）
  final int baseCardBorderColorNight;

  /// 关闭拼接分组圆角（优先级高于 [overrideBaseCardCornerRadius]）
  final bool disableSplicedColumnGroupCornerRadius;

  /// 启用毛玻璃（BackdropFilter，默认关）
  final bool enableBlur;

  /// 拦截书源打开浏览器（批39，默认关）
  ///
  /// 开启后书源 JS 的 openUrl/showBrowser/startBrowser 一律拦截并提示
  /// （对齐参考版 `OtherSettings.blockSourceBrowser`）；随备份 appPrefs 往返。
  final bool blockSourceBrowser;

  /// 限制封面比例（批39，默认开）
  ///
  /// 开启：书架/搜索/发现/详情封面固定 5:7（对齐参考版
  /// `CoverSettings.restrictCoverRatio=true`）；
  /// 关闭：按封面原图宽高比自适应（网格行高随代表比例调整）。
  final bool restrictCoverRatio;

  /// 顶栏模糊半径 dp
  final int topBarBlurRadius;

  /// 顶栏底色透明度 0-255
  final int topBarBlurAlpha;

  /// 悬浮底栏模糊半径 dp
  final int bottomBarBlurRadius;

  /// 悬浮底栏底色透明度 0-255
  final int bottomBarBlurAlpha;

  /// 跟随壁纸取色（Android 12+ Material You / iOS 动态色均接通）
  final bool wallpaperColorFollow;

  /// 设置行分隔线开关
  final bool enableItemDivider;

  /// 设置行分隔线宽度 dp 0-5（0=不绘制）
  final int itemDividerWidth;

  /// 设置行分隔线长度百分比 30-100（占分组可用宽度，不是 dp）
  final int itemDividerLength;

  /// 设置行分隔线颜色 ARGB（0=默认灰色 30%）
  final int itemDividerColor;

  // ===== [设置批2b-1a] 容器外观（对齐参考版 ThemeSettings）=====

  /// 容器卡面不透明度 0-100（参考版 containerOpacity，默认 100）
  ///
  /// 作用于 IosGroup 分组卡面（外部分组底 + 行小卡底）：值越低，底层
  /// 容器背景图/全局壁纸透出越多；文字颜色不随之改变（参考版 GlassCard
  /// 同口径，见 `card/GlassCard.kt:74-75`：`alpha = alpha * containerOpacity`）。
  final int containerOpacity;

  /// 启用容器背景图（参考版 enableContainerBackgroundImage，默认 false）
  ///
  /// 关闭时保留 largeContainerBackgroundImage* 路径但不绘制；选图时自动置 true。
  final bool enableContainerBackgroundImage;

  /// 日间大容器背景图偏好值（相对 Support 目录的可迁移标识；空=未设置）
  final String largeContainerBackgroundImageLight;

  /// 夜间大容器背景图偏好值（相对 Support 目录的可迁移标识；空=未设置）
  final String largeContainerBackgroundImageDark;

  /// 日间全局背景图虚化半径 0-100（参考版 bgImageBlurring，默认 0）
  final int bgImageBlurring;

  /// 夜间全局背景图虚化半径 0-100（参考版 bgImageNBlurring，默认 0）
  final int bgImageDarkBlurring;

  /// 大屏侧栏展开态（持久化）
  final bool railExtended;

  /// 阅读菜单亮度竖条开关
  final bool readMenuBrightnessVertical;

  /// 阅读菜单亮度竖条位置（left/right）
  final String readMenuBrightnessPos;

  /// 主题引擎 paletteStyle（'none'=关闭参数化，9 档见 kPaletteStyles）
  final String themeStyle;

  /// 主题引擎对比度（'0.0'/'0.5'/'1.0'）
  final String themeContrastLevel;

  /// AMOLED 纯黑（仅暗色生效）
  final bool themeAmoled;

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
    this.overrideBaseCardBorder = false,
    this.baseCardBorderWidth = 1,
    this.baseCardBorderColor = 0,
    this.baseCardBorderColorNight = 0,
    this.disableSplicedColumnGroupCornerRadius = false,
    this.enableBlur = false,
    this.blockSourceBrowser = false,
    this.restrictCoverRatio = true,
    this.topBarBlurRadius = 24,
    this.topBarBlurAlpha = 73,
    this.bottomBarBlurRadius = 8,
    this.bottomBarBlurAlpha = 40,
    this.wallpaperColorFollow = false,
    this.enableItemDivider = false,
    this.itemDividerWidth = 1,
    this.itemDividerLength = 80,
    this.itemDividerColor = 0,
    this.containerOpacity = 100,
    this.enableContainerBackgroundImage = false,
    this.largeContainerBackgroundImageLight = '',
    this.largeContainerBackgroundImageDark = '',
    this.bgImageBlurring = 0,
    this.bgImageDarkBlurring = 0,
    this.railExtended = false,
    this.readMenuBrightnessVertical = false,
    this.readMenuBrightnessPos = 'right',
    this.themeStyle = 'none',
    this.themeContrastLevel = '0.0',
    this.themeAmoled = false,
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
    bool? overrideBaseCardBorder,
    int? baseCardBorderWidth,
    int? baseCardBorderColor,
    int? baseCardBorderColorNight,
    bool? disableSplicedColumnGroupCornerRadius,
    bool? enableBlur,
    bool? blockSourceBrowser,
    bool? restrictCoverRatio,
    int? topBarBlurRadius,
    int? topBarBlurAlpha,
    int? bottomBarBlurRadius,
    int? bottomBarBlurAlpha,
    bool? wallpaperColorFollow,
    bool? enableItemDivider,
    int? itemDividerWidth,
    int? itemDividerLength,
    int? itemDividerColor,
    int? containerOpacity,
    bool? enableContainerBackgroundImage,
    String? largeContainerBackgroundImageLight,
    String? largeContainerBackgroundImageDark,
    int? bgImageBlurring,
    int? bgImageDarkBlurring,
    bool? railExtended,
    bool? readMenuBrightnessVertical,
    String? readMenuBrightnessPos,
    String? themeStyle,
    String? themeContrastLevel,
    bool? themeAmoled,
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
      overrideBaseCardBorder:
          overrideBaseCardBorder ?? this.overrideBaseCardBorder,
      baseCardBorderWidth: baseCardBorderWidth ?? this.baseCardBorderWidth,
      baseCardBorderColor: baseCardBorderColor ?? this.baseCardBorderColor,
      baseCardBorderColorNight:
          baseCardBorderColorNight ?? this.baseCardBorderColorNight,
      disableSplicedColumnGroupCornerRadius:
          disableSplicedColumnGroupCornerRadius ??
              this.disableSplicedColumnGroupCornerRadius,
      enableBlur: enableBlur ?? this.enableBlur,
      blockSourceBrowser: blockSourceBrowser ?? this.blockSourceBrowser,
      restrictCoverRatio: restrictCoverRatio ?? this.restrictCoverRatio,
      topBarBlurRadius: topBarBlurRadius ?? this.topBarBlurRadius,
      topBarBlurAlpha: topBarBlurAlpha ?? this.topBarBlurAlpha,
      bottomBarBlurRadius: bottomBarBlurRadius ?? this.bottomBarBlurRadius,
      bottomBarBlurAlpha: bottomBarBlurAlpha ?? this.bottomBarBlurAlpha,
      wallpaperColorFollow: wallpaperColorFollow ?? this.wallpaperColorFollow,
      enableItemDivider: enableItemDivider ?? this.enableItemDivider,
      itemDividerWidth: itemDividerWidth ?? this.itemDividerWidth,
      itemDividerLength: itemDividerLength ?? this.itemDividerLength,
      itemDividerColor: itemDividerColor ?? this.itemDividerColor,
      containerOpacity: containerOpacity ?? this.containerOpacity,
      enableContainerBackgroundImage: enableContainerBackgroundImage ??
          this.enableContainerBackgroundImage,
      largeContainerBackgroundImageLight: largeContainerBackgroundImageLight ??
          this.largeContainerBackgroundImageLight,
      largeContainerBackgroundImageDark: largeContainerBackgroundImageDark ??
          this.largeContainerBackgroundImageDark,
      bgImageBlurring: bgImageBlurring ?? this.bgImageBlurring,
      bgImageDarkBlurring: bgImageDarkBlurring ?? this.bgImageDarkBlurring,
      railExtended: railExtended ?? this.railExtended,
      readMenuBrightnessVertical:
          readMenuBrightnessVertical ?? this.readMenuBrightnessVertical,
      readMenuBrightnessPos:
          readMenuBrightnessPos ?? this.readMenuBrightnessPos,
      themeStyle: themeStyle ?? this.themeStyle,
      themeContrastLevel: themeContrastLevel ?? this.themeContrastLevel,
      themeAmoled: themeAmoled ?? this.themeAmoled,
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

  /// 恢复备份后重读偏好（备份 appPrefs 已写入 SharedPreferences）。
  ///
  /// 用 await 重读而非 invalidate：避免 provider 重建时先以默认值渲染一帧
  /// （容器不透明度/背景图虚化会闪一下 100/0），与护眼模式 reload 同口径。
  Future<void> reload() => _load();

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
      ).then(_clampCardCornerRadius),
      // [设置批2b-1b-1] 卡片边框/分组圆角开关（参考版 ThemeSettings）
      overrideBaseCardBorder: await _settings.getBoolPref(
        PrefKeys.overrideBaseCardBorder,
        defaultValue: false,
      ),
      baseCardBorderWidth: await _settings.getIntPref(
        PrefKeys.baseCardBorderWidth,
        defaultValue: 1,
      ).then(_clampBorderWidth),
      baseCardBorderColor: await _settings.getIntPref(
        PrefKeys.baseCardBorderColor,
        defaultValue: 0,
      ),
      baseCardBorderColorNight: await _settings.getIntPref(
        PrefKeys.baseCardBorderColorNight,
        defaultValue: 0,
      ),
      disableSplicedColumnGroupCornerRadius: await _settings.getBoolPref(
        PrefKeys.disableSplicedColumnGroupCornerRadius,
        defaultValue: false,
      ),
      enableBlur: await _settings.getBoolPref(
        PrefKeys.enableBlur,
        defaultValue: false,
      ),
      blockSourceBrowser: await _settings.getBoolPref(
        PrefKeys.blockSourceBrowser,
        defaultValue: false,
      ),
      restrictCoverRatio: await _settings.getBoolPref(
        PrefKeys.coverRestrictRatio,
        defaultValue: true,
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
      // [设置批2b-1b-1] 条目分隔线几何/颜色（参考版 itemDivider*）
      itemDividerWidth: await _settings.getIntPref(
        PrefKeys.itemDividerWidth,
        defaultValue: 1,
      ).then(_clampBorderWidth),
      itemDividerLength: await _settings.getIntPref(
        PrefKeys.itemDividerLength,
        defaultValue: 80,
      ).then(_clampDividerLength),
      itemDividerColor: await _settings.getIntPref(
        PrefKeys.itemDividerColor,
        defaultValue: 0,
      ),
      // [设置批2b-1a] 容器外观：不透明度/背景图（相对标识）与日夜虚化半径
      containerOpacity: await _settings.getIntPref(
        PrefKeys.containerOpacity,
        defaultValue: 100,
      ).then(_clampOpacity),
      enableContainerBackgroundImage: await _settings.getBoolPref(
        PrefKeys.enableContainerBackgroundImage,
        defaultValue: false,
      ),
      largeContainerBackgroundImageLight: await _settings.getStringPref(
        PrefKeys.largeContainerBackgroundImageLight,
      ),
      largeContainerBackgroundImageDark: await _settings.getStringPref(
        PrefKeys.largeContainerBackgroundImageDark,
      ),
      bgImageBlurring: await _settings.getIntPref(
        PrefKeys.bgImageBlurring,
        defaultValue: 0,
      ).then(_clampOpacity),
      bgImageDarkBlurring: await _settings.getIntPref(
        PrefKeys.bgImageNBlurring,
        defaultValue: 0,
      ).then(_clampOpacity),
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
      themeStyle: await _settings.getStringPref(
        PrefKeys.themeStyle,
        defaultValue: 'none',
      ),
      themeContrastLevel: await _settings.getStringPref(
        PrefKeys.themeContrastLevel,
        defaultValue: '0.0',
      ),
      themeAmoled: await _settings.getBoolPref(
        PrefKeys.themeAmoled,
        defaultValue: false,
      ),
    );
    _sync();
    // [设置批2b-1a] 容器背景图按「相对 Support 目录标识」解析：基目录预热
    // 不阻塞设置加载（避免启动/恢复流程等待平台通道），完成后再通知一次
    // 让已挂载的 IosGroup 从「相对标识未解析」切换到真实图片。
    unawaited(_refreshAfterBackgroundWarm());
  }

  /// 基目录预热完成后，若状态未被用户改动，则推送一次同值新实例触发重建
  ///
  /// 说明：UiSettingsState 未重写 ==，copyWith() 产生新实例 → ValueNotifier
  /// 认为值变化并通知；这是启动时最多一次的重建，不影响持久化。
  Future<void> _refreshAfterBackgroundWarm() async {
    final snapshot = uiSettingsListenable.value;
    await ThemeBackgroundImageStore.ensureWarm();
    if (!ThemeBackgroundImageStore.isWarm) return;
    if (!identical(uiSettingsListenable.value, snapshot)) return;
    uiSettingsListenable.value = snapshot.copyWith();
  }

  static int _clampOpacity(int v) => v.clamp(0, 100);

  /// 卡片圆角 0-40（参考版滑杆 0f..40f；0=直角）
  static int _clampCardCornerRadius(int v) => v.clamp(0, 40);

  /// 边框/分隔线宽度 0-5dp（参考版滑杆 0f..5f）
  static int _clampBorderWidth(int v) => v.clamp(0, 5);

  /// 分隔线长度百分比 30-100（参考版滑杆 30f..100f）
  static int _clampDividerLength(int v) => v.clamp(30, 100);

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

  /// 基础卡片圆角值（0-40，随主题重建生效；0=直角）
  Future<void> setBaseCardCornerRadius(int value) async {
    final v = _clampCardCornerRadius(value);
    if (state.baseCardCornerRadius == v) return;
    state = state.copyWith(baseCardCornerRadius: v);
    _sync();
    await _settings.setIntPref(PrefKeys.baseCardCornerRadius, v);
  }

  /// 覆写基础卡片边框开关（参考版 overrideBaseCardBorder）
  Future<void> setOverrideBaseCardBorder(bool value) async {
    if (state.overrideBaseCardBorder == value) return;
    state = state.copyWith(overrideBaseCardBorder: value);
    _sync();
    await _settings.setBoolPref(PrefKeys.overrideBaseCardBorder, value);
  }

  /// 基础卡片边框宽度 dp（0-5；0 = 不绘制）
  Future<void> setBaseCardBorderWidth(int value) async {
    final v = _clampBorderWidth(value);
    if (state.baseCardBorderWidth == v) return;
    state = state.copyWith(baseCardBorderWidth: v);
    _sync();
    await _settings.setIntPref(PrefKeys.baseCardBorderWidth, v);
  }

  /// 日间卡片边框颜色（0 = 跟随主题 outlineVariant）
  Future<void> setBaseCardBorderColor(int value) async {
    if (state.baseCardBorderColor == value) return;
    state = state.copyWith(baseCardBorderColor: value);
    _sync();
    await _settings.setIntPref(PrefKeys.baseCardBorderColor, value);
  }

  /// 夜间卡片边框颜色（0 = 跟随主题 outlineVariant）
  Future<void> setBaseCardBorderColorNight(int value) async {
    if (state.baseCardBorderColorNight == value) return;
    state = state.copyWith(baseCardBorderColorNight: value);
    _sync();
    await _settings.setIntPref(PrefKeys.baseCardBorderColorNight, value);
  }

  /// 关闭拼接分组圆角（优先级高于圆角覆盖）
  Future<void> setDisableSplicedColumnGroupCornerRadius(bool value) async {
    if (state.disableSplicedColumnGroupCornerRadius == value) return;
    state = state.copyWith(disableSplicedColumnGroupCornerRadius: value);
    _sync();
    await _settings.setBoolPref(
      PrefKeys.disableSplicedColumnGroupCornerRadius,
      value,
    );
  }

  /// 启用毛玻璃
  Future<void> setEnableBlur(bool value) async {
    if (state.enableBlur == value) return;
    state = state.copyWith(enableBlur: value);
    _sync();
    await _settings.setBoolPref(PrefKeys.enableBlur, value);
  }

  /// 拦截书源打开浏览器（批39）
  Future<void> setBlockSourceBrowser(bool value) async {
    if (state.blockSourceBrowser == value) return;
    state = state.copyWith(blockSourceBrowser: value);
    _sync();
    await _settings.setBoolPref(PrefKeys.blockSourceBrowser, value);
  }

  /// 限制封面比例（批39）
  Future<void> setRestrictCoverRatio(bool value) async {
    if (state.restrictCoverRatio == value) return;
    state = state.copyWith(restrictCoverRatio: value);
    _sync();
    await _settings.setBoolPref(PrefKeys.coverRestrictRatio, value);
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

  /// 主题引擎 paletteStyle
  Future<void> setThemeStyle(String value) async {
    if (state.themeStyle == value) return;
    state = state.copyWith(themeStyle: value);
    _sync();
    await _settings.setStringPref(PrefKeys.themeStyle, value);
  }

  /// 主题引擎对比度
  Future<void> setThemeContrastLevel(String value) async {
    if (state.themeContrastLevel == value) return;
    state = state.copyWith(themeContrastLevel: value);
    _sync();
    await _settings.setStringPref(PrefKeys.themeContrastLevel, value);
  }

  /// AMOLED 纯黑
  Future<void> setThemeAmoled(bool value) async {
    if (state.themeAmoled == value) return;
    state = state.copyWith(themeAmoled: value);
    _sync();
    await _settings.setBoolPref(PrefKeys.themeAmoled, value);
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

  /// 设置行分隔线宽度 dp（0-5；0 = 不绘制）
  Future<void> setItemDividerWidth(int value) async {
    final v = _clampBorderWidth(value);
    if (state.itemDividerWidth == v) return;
    state = state.copyWith(itemDividerWidth: v);
    _sync();
    await _settings.setIntPref(PrefKeys.itemDividerWidth, v);
  }

  /// 设置行分隔线长度百分比（30-100）
  Future<void> setItemDividerLength(int value) async {
    final v = _clampDividerLength(value);
    if (state.itemDividerLength == v) return;
    state = state.copyWith(itemDividerLength: v);
    _sync();
    await _settings.setIntPref(PrefKeys.itemDividerLength, v);
  }

  /// 设置行分隔线颜色（0 = 默认灰色 30%）
  Future<void> setItemDividerColor(int value) async {
    if (state.itemDividerColor == value) return;
    state = state.copyWith(itemDividerColor: value);
    _sync();
    await _settings.setIntPref(PrefKeys.itemDividerColor, value);
  }

  /// 跟随壁纸取色
  Future<void> setWallpaperColorFollow(bool value) async {
    if (state.wallpaperColorFollow == value) return;
    state = state.copyWith(wallpaperColorFollow: value);
    _sync();
    await _settings.setBoolPref(PrefKeys.wallpaperColorFollow, value);
  }

  // ===== [设置批2b-1a] 容器外观 =====

  /// 容器卡面不透明度（0-100，默认 100）
  Future<void> setContainerOpacity(int value) async {
    final v = _clampOpacity(value);
    if (state.containerOpacity == v) return;
    state = state.copyWith(containerOpacity: v);
    _sync();
    await _settings.setIntPref(PrefKeys.containerOpacity, v);
  }

  /// 启用容器背景图（参考版 enableContainerBackgroundImage）
  Future<void> setEnableContainerBackgroundImage(bool value) async {
    if (state.enableContainerBackgroundImage == value) return;
    state = state.copyWith(enableContainerBackgroundImage: value);
    _sync();
    await _settings.setBoolPref(
      PrefKeys.enableContainerBackgroundImage,
      value,
    );
  }

  /// 大容器背景图（日/夜；空串 = 清除/恢复默认）
  ///
  /// [storedPath] 为 ThemeBackgroundImageStore 返回的相对可迁移标识。
  /// 清除时移除偏好键（参考版置 null）；旧图文件清理由调用方负责。
  /// 选定非空图片时自动打开总开关（保证「选图即生效」；关闭开关仍保留路径）。
  Future<void> setLargeContainerBackgroundImage({
    required bool night,
    required String storedPath,
  }) async {
    // 选图即生效（含重复选择同一张图）：先开总开关，再按需更新路径
    if (storedPath.isNotEmpty) {
      await setEnableContainerBackgroundImage(true);
    }
    if (night) {
      if (state.largeContainerBackgroundImageDark == storedPath) return;
      state = state.copyWith(largeContainerBackgroundImageDark: storedPath);
      _sync();
      if (storedPath.isEmpty) {
        await _settings.removePref(PrefKeys.largeContainerBackgroundImageDark);
      } else {
        await _settings.setStringPref(
          PrefKeys.largeContainerBackgroundImageDark,
          storedPath,
        );
      }
      return;
    }
    if (state.largeContainerBackgroundImageLight == storedPath) return;
    state = state.copyWith(largeContainerBackgroundImageLight: storedPath);
    _sync();
    if (storedPath.isEmpty) {
      await _settings.removePref(PrefKeys.largeContainerBackgroundImageLight);
    } else {
      await _settings.setStringPref(
        PrefKeys.largeContainerBackgroundImageLight,
        storedPath,
      );
    }
  }

  /// 全局背景图虚化半径（0-100；[night] 区分日夜）
  Future<void> setBgImageBlurring({
    required bool night,
    required int value,
  }) async {
    final v = _clampOpacity(value);
    if (night) {
      if (state.bgImageDarkBlurring == v) return;
      state = state.copyWith(bgImageDarkBlurring: v);
      _sync();
      await _settings.setIntPref(PrefKeys.bgImageNBlurring, v);
      return;
    }
    if (state.bgImageBlurring == v) return;
    state = state.copyWith(bgImageBlurring: v);
    _sync();
    await _settings.setIntPref(PrefKeys.bgImageBlurring, v);
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
