// [UI-fix v2.0.5 | 2026-08-08] 主题设置页对齐原版 pref_config_theme.xml +
// ThemeConfigFragment（24 项）：启动图标/欢迎页样式/沉浸式状态栏/沉浸式导航栏/
// 导航栏阴影/字体缩放/封面设置/主题列表/底栏皮肤/壁纸取色 ×2 +
// 白天/夜间 主色调/强调色/背景色/底栏色/背景图片/透明导航栏/保存主题。
// 颜色配置经 ThemeColorsNotifier 接入 MaterialApp ThemeData 即时生效；
// Android 专属项持久化并以灰字"仅 Android 生效"标注；
// 视觉保持 iOS 分组卡片风格（IosGroup/IosListTile） — Qoder
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import '../widgets/legado_app_bar.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;

import '../bridge/ffi.dart';
import '../constants/pref_keys.dart';
import '../providers/providers.dart';
import '../providers/theme/system_bar_notifier.dart';
import '../providers/theme/theme_colors_notifier.dart';
import '../providers/theme/theme_notifier.dart';
import '../providers/ui_settings/ui_settings_notifier.dart';
import '../routes.dart';
import '../services/launcher_icon_service.dart';
import '../services/settings_service.dart';
import '../theme/md3_colors.dart';
import '../widgets/ios_widgets.dart';

/// 主题设置页面（对齐原版 ThemeConfigFragment）
///
/// 主题模式与全局字体缩放经 [ThemeNotifier] 全局实时生效；
/// 日间/夜间自定义颜色经 [ThemeColorsNotifier] 驱动 MaterialApp 即时生效。
class ThemeConfigScreen extends ConsumerStatefulWidget {
  const ThemeConfigScreen({super.key});

  @override
  ConsumerState<ThemeConfigScreen> createState() => _ThemeConfigScreenState();
}

class _ThemeConfigScreenState extends ConsumerState<ThemeConfigScreen> {
  SettingsService get _settings => ref.read(settingsProvider);

  bool _loading = true;

  // ===== 通用组状态（对齐原版顶部无分组项）=====
  String _launcherIcon = 'iconMain';
  bool _transparentStatusBar = true;
  bool _immNavigationBar = true;
  int _barElevation = 0;
  bool _wallpaperColorFollow = false;
  bool _wallpaperColorAutoUpdate = true;

  // ===== 日间/夜间组状态 =====
  String _bgImage = '';
  String _bgImageNight = '';
  bool _transparentNavBar = false;
  bool _transparentNavBarNight = false;

  /// 颜色选择器预设色板（对齐原版 ColorPreference cpv_dialogType="preset"）
  static const _presetColors = [
    0xFFD32F2F, 0xFFF44336, 0xFFE91E63, 0xFF9C27B0, 0xFF673AB7,
    0xFF3F51B5, 0xFF2196F3, 0xFF03A9F4, 0xFF00BCD4, 0xFF009688,
    0xFF4CAF50, 0xFF8BC34A, 0xFFCDDC39, 0xFFFFEB3B, 0xFFFFC107,
    0xFFFF9800, 0xFFFF5722, 0xFF795548, 0xFF9E9E9E, 0xFF607D8B,
    0xFF000000, 0xFF212121, 0xFF424242, 0xFFFAFAFA, 0xFFFFFFFF,
  ];

  /// 启动图标可选值（对齐原版 arrays.xml icon_names）
  static const _launcherIcons = [
    'iconMain', 'icon1', 'icon2', 'icon3', 'icon4', 'icon5', 'icon6',
  ];

  static const _launcherIconLabels = [
    '默认', '图标 1', '图标 2', '图标 3', '图标 4', '图标 5', '图标 6',
  ];

  /// Android 专属项统一灰字标注（与阅读设置面板刘海项先例一致）
  static const _androidOnly = '仅 Android 生效';

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  /// 加载持久化偏好（键名对齐原版 PreferKey）
  Future<void> _loadSettings() async {
    final launcherIcon = await _settings.getStringPref(
      PrefKeys.launcherIcon,
      defaultValue: 'iconMain',
    );
    final transparentStatusBar = await _settings.getBoolPref(
      PrefKeys.transparentStatusBar,
      defaultValue: true,
    );
    final immNavigationBar = await _settings.getBoolPref(
      PrefKeys.immNavigationBar,
      defaultValue: true,
    );
    final barElevation =
        await _settings.getIntPref(PrefKeys.barElevation, defaultValue: 0);
    final wallpaperColorFollow = await _settings.getBoolPref(
      PrefKeys.wallpaperColorFollow,
      defaultValue: false,
    );
    final wallpaperColorAutoUpdate = await _settings.getBoolPref(
      PrefKeys.wallpaperColorAutoUpdate,
      defaultValue: true,
    );
    final bgImage = await _settings.getStringPref(PrefKeys.bgImage);
    final bgImageNight = await _settings.getStringPref(PrefKeys.bgImageN);
    final transparentNavBar = await _settings.getBoolPref(
      PrefKeys.transparentNavBar,
      defaultValue: false,
    );
    final transparentNavBarNight = await _settings.getBoolPref(
      PrefKeys.transparentNavBarNight,
      defaultValue: false,
    );
    if (!mounted) return;
    setState(() {
      _launcherIcon = launcherIcon;
      _transparentStatusBar = transparentStatusBar;
      _immNavigationBar = immNavigationBar;
      _barElevation = barElevation;
      _wallpaperColorFollow = wallpaperColorFollow;
      _wallpaperColorAutoUpdate = wallpaperColorAutoUpdate;
      _bgImage = bgImage;
      _bgImageNight = bgImageNight;
      _transparentNavBar = transparentNavBar;
      _transparentNavBarNight = transparentNavBarNight;
      _loading = false;
    });
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  // ===== [UI_SYNC_REFACTOR B2] 顶栏与布局开关 =====

  String _topBarStyleLabel(TopBarButtonStyle s) => switch (s) {
        TopBarButtonStyle.plain => '平面',
        TopBarButtonStyle.tonal => 'Tonal（默认）',
        TopBarButtonStyle.outlined => '描边',
        TopBarButtonStyle.glass => '玻璃',
        TopBarButtonStyle.liquidGlass => '液态玻璃',
      };

  Future<void> _showTopBarStylePicker() async {
    final current = ref.read(uiSettingsProvider).topBarButtonStyle;
    final selected = await showDialog<TopBarButtonStyle>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('顶栏按钮样式'),
        children: [
          for (final s in TopBarButtonStyle.values)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, s),
              child: Row(
                children: [
                  Icon(
                    current == s
                        ? Icons.radio_button_checked
                        : Icons.radio_button_unchecked,
                    size: 20,
                  ),
                  const SizedBox(width: 12),
                  Text(_topBarStyleLabel(s)),
                ],
              ),
            ),
        ],
      ),
    );
    if (selected != null) {
      await ref
          .read(uiSettingsProvider.notifier)
          .setTopBarButtonStyle(selected);
    }
  }

  Future<void> _showTopBarOpacityDialog() async {
    var value = ref.read(uiSettingsProvider).topBarOpacity.toDouble();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('顶栏不透明度'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Slider(
                value: value,
                min: 0,
                max: 100,
                divisions: 20,
                label: '${value.round()}%',
                onChanged: (v) => setDialogState(() => value = v),
              ),
              Text('当前 ${value.round()}%'),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('确定'),
            ),
          ],
        ),
      ),
    );
    if (confirmed == true) {
      await ref
          .read(uiSettingsProvider.notifier)
          .setTopBarOpacity(value.round());
    }
  }

  String _labelModeLabel(BottomBarLabelMode m) => switch (m) {
        BottomBarLabelMode.auto => '仅选中显示（默认）',
        BottomBarLabelMode.labeled => '全部常显',
        BottomBarLabelMode.unlabeled => '纯图标',
      };

  Future<void> _showLabelModePicker() async {
    final current = ref.read(uiSettingsProvider).labelVisibilityMode;
    final selected = await showDialog<BottomBarLabelMode>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('底栏文字'),
        children: [
          for (final m in BottomBarLabelMode.values)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, m),
              child: Row(
                children: [
                  Icon(
                    current == m
                        ? Icons.radio_button_checked
                        : Icons.radio_button_unchecked,
                    size: 20,
                  ),
                  const SizedBox(width: 12),
                  Text(_labelModeLabel(m)),
                ],
              ),
            ),
        ],
      ),
    );
    if (selected != null) {
      await ref
          .read(uiSettingsProvider.notifier)
          .setLabelVisibilityMode(selected);
    }
  }

  Future<void> _showBottomBarOpacityDialog() async {
    var value = ref.read(uiSettingsProvider).bottomBarOpacity.toDouble();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('底栏不透明度'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Slider(
                value: value,
                min: 0,
                max: 100,
                divisions: 20,
                label: '${value.round()}%',
                onChanged: (v) => setDialogState(() => value = v),
              ),
              Text('当前 ${value.round()}%'),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('确定'),
            ),
          ],
        ),
      ),
    );
    if (confirmed == true) {
      await ref
          .read(uiSettingsProvider.notifier)
          .setBottomBarOpacity(value.round());
    }
  }

  String _tabletLabel(TabletInterfaceMode m) => switch (m) {
        TabletInterfaceMode.auto => '自动（宽屏 ≥600dp）',
        TabletInterfaceMode.always => '始终启用侧栏',
        TabletInterfaceMode.landscape => '仅横屏启用',
        TabletInterfaceMode.off => '不启用',
      };

  Future<void> _showTabletModePicker() async {
    final current = ref.read(uiSettingsProvider).tabletInterface;
    final selected = await showDialog<TabletInterfaceMode>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('大屏导航形态'),
        children: [
          for (final m in TabletInterfaceMode.values)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, m),
              child: Row(
                children: [
                  Icon(
                    current == m
                        ? Icons.radio_button_checked
                        : Icons.radio_button_unchecked,
                    size: 20,
                  ),
                  const SizedBox(width: 12),
                  Text(_tabletLabel(m)),
                ],
              ),
            ),
        ],
      ),
    );
    if (selected != null) {
      await ref
          .read(uiSettingsProvider.notifier)
          .setTabletInterface(selected);
    }
  }

  String _styleLabel(String v) => switch (v) {
        'none' => '关闭（内置色板）',
        'tonalSpot' => 'Tonal Spot（默认）',
        'neutral' => 'Neutral',
        'vibrant' => 'Vibrant',
        'expressive' => 'Expressive',
        'fidelity' => 'Fidelity',
        'content' => 'Content',
        'rainbow' => 'Rainbow',
        'fruitSalad' => 'Fruit Salad',
        'monochrome' => 'Monochrome',
        _ => v,
      };

  Future<void> _showThemeStylePicker() async {
    final current = ref.read(uiSettingsProvider).themeStyle;
    const options = <(String, String)>[
      ('none', '关闭（内置色板）'),
      ('tonalSpot', 'Tonal Spot（默认）'),
      ('neutral', 'Neutral'),
      ('vibrant', 'Vibrant'),
      ('expressive', 'Expressive'),
      ('fidelity', 'Fidelity'),
      ('content', 'Content'),
      ('rainbow', 'Rainbow'),
      ('fruitSalad', 'Fruit Salad'),
      ('monochrome', 'Monochrome'),
    ];
    final selected = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('配色风格'),
        children: [
          for (final (value, label) in options)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, value),
              child: Row(
                children: [
                  Icon(
                    current == value
                        ? Icons.radio_button_checked
                        : Icons.radio_button_unchecked,
                    size: 20,
                  ),
                  const SizedBox(width: 12),
                  Text(label),
                ],
              ),
            ),
        ],
      ),
    );
    if (selected != null) {
      await ref.read(uiSettingsProvider.notifier).setThemeStyle(selected);
    }
  }

  String _contrastLabel(String v) => switch (v) {
        '0.5' => 'Medium（中）',
        '1.0' => 'High（高）',
        _ => 'Default（默认）',
      };

  Future<void> _showContrastPicker() async {
    final current = ref.read(uiSettingsProvider).themeContrastLevel;
    const options = <(String, String)>[
      ('0.0', 'Default（默认）'),
      ('0.5', 'Medium（中）'),
      ('1.0', 'High（高）'),
    ];
    final selected = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('对比度'),
        children: [
          for (final (value, label) in options)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, value),
              child: Row(
                children: [
                  Icon(
                    current == value
                        ? Icons.radio_button_checked
                        : Icons.radio_button_unchecked,
                    size: 20,
                  ),
                  const SizedBox(width: 12),
                  Text(label),
                ],
              ),
            ),
        ],
      ),
    );
    if (selected != null) {
      await ref
          .read(uiSettingsProvider.notifier)
          .setThemeContrastLevel(selected);
    }
  }

  String _coverBgLabel(String v) => switch (v) {
        'off' => '显示封面（不模糊）',
        'off_for_default' => '隐藏（仅默认封面档）',
        _ => '模糊显示（默认）',
      };

  Future<void> _showCoverBgPicker(bool isDefaultCover) async {
    final uiNow = ref.read(uiSettingsProvider);
    final current = isDefaultCover
        ? uiNow.bookInfoDefaultCoverBackground
        : uiNow.bookInfoNetworkCoverBackground;
    const options = <(String, String)>[
      ('on', '模糊显示（默认）'),
      ('off', '显示封面（不模糊）'),
      ('off_for_default', '隐藏'),
    ];
    final selected = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('封面背景'),
        children: [
          for (final (value, label) in options)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, value),
              child: Row(
                children: [
                  Icon(
                    current == value
                        ? Icons.radio_button_checked
                        : Icons.radio_button_unchecked,
                    size: 20,
                  ),
                  const SizedBox(width: 12),
                  Text(label),
                ],
              ),
            ),
        ],
      ),
    );
    if (selected != null) {
      await ref
          .read(uiSettingsProvider.notifier)
          .setBookInfoCoverBackground(
            isDefaultCover: isDefaultCover,
            value: selected,
          );
    }
  }

  Future<void> _showCardRadiusDialog() async {
    final uiNow = ref.read(uiSettingsProvider);
    var override = uiNow.overrideBaseCardCornerRadius;
    var radius = uiNow.baseCardCornerRadius.toDouble();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('卡片圆角'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SwitchListTile(
                title: const Text('覆写主题圆角'),
                value: override,
                onChanged: (v) => setDialogState(() => override = v),
              ),
              Slider(
                value: radius,
                min: 4,
                max: 28,
                divisions: 12,
                label: '${radius.round()}dp',
                onChanged: (v) => setDialogState(() => radius = v),
              ),
              Text('当前 ${radius.round()}dp（随主题重建生效）'),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('确定'),
            ),
          ],
        ),
      ),
    );
    if (confirmed == true) {
      final notifier = ref.read(uiSettingsProvider.notifier);
      await notifier.setOverrideBaseCardCornerRadius(override);
      await notifier.setBaseCardCornerRadius(radius.round());
    }
  }

  Future<void> _showBlurRadiusDialog({
    required String title,
    required int currentRadius,
    required int currentAlpha,
    required ValueChanged<int> onRadius,
    required ValueChanged<int> onAlpha,
  }) async {
    var radius = currentRadius.toDouble();
    var alpha = currentAlpha.toDouble();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: Text(title),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('模糊半径 ${radius.round()}dp'),
              Slider(
                value: radius,
                min: 0,
                max: 48,
                divisions: 12,
                onChanged: (v) => setDialogState(() => radius = v),
              ),
              Text('底色透明度 ${alpha.round()}/255'),
              Slider(
                value: alpha,
                min: 0,
                max: 255,
                divisions: 51,
                onChanged: (v) => setDialogState(() => alpha = v),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('确定'),
            ),
          ],
        ),
      ),
    );
    if (confirmed == true) {
      onRadius(radius.round());
      onAlpha(alpha.round());
    }
  }

  Future<void> _showTopBarBlurDialog() async {
    final uiNow = ref.read(uiSettingsProvider);
    final notifier = ref.read(uiSettingsProvider.notifier);
    await _showBlurRadiusDialog(
      title: '顶栏模糊',
      currentRadius: uiNow.topBarBlurRadius,
      currentAlpha: uiNow.topBarBlurAlpha,
      onRadius: notifier.setTopBarBlurRadius,
      onAlpha: notifier.setTopBarBlurAlpha,
    );
  }

  Future<void> _showBottomBarBlurDialog() async {
    final uiNow = ref.read(uiSettingsProvider);
    final notifier = ref.read(uiSettingsProvider.notifier);
    await _showBlurRadiusDialog(
      title: '悬浮底栏模糊',
      currentRadius: uiNow.bottomBarBlurRadius,
      currentAlpha: uiNow.bottomBarBlurAlpha,
      onRadius: notifier.setBottomBarBlurRadius,
      onAlpha: notifier.setBottomBarBlurAlpha,
    );
  }

  @override
  Widget build(BuildContext context) {
    final themeState = ref.watch(themeNotifierProvider);
    final themeNotifier = ref.read(themeNotifierProvider.notifier);
    final colors = ref.watch(themeColorsProvider);
    final ui = ref.watch(uiSettingsProvider);

    return Scaffold(
      // [队列⑦c A3] 页标题对齐参考 R.string.theme_setting=外观
      appBar: LegadoAppBar(title: const Text('外观')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : IosGroupedBody(
              child: ListView(
                padding: const EdgeInsets.only(bottom: 32),
                children: [
                  // === [2.0.269 用户裁决] 外观预览卡已移除（C6 批 b03c2ba444 低优
                  // 增强建议产物，无独立用户授权记录；与配色轮同类，严格红线） ===
                  // === [2.0.268 用户裁决] 配色轮卡已移除（B3-C1 A2 系误判证据
                  // 产物，kazusa 源码无此能力，严格红线）；长按预设主色调选择
                  // 器本体（_showColorPicker，色卡行在用）保留不动 ===
                  // === [队列⑦c A3] IA 对齐参考版 ThemeConfigScreen.kt ===
                  // 分组 1「主题模式」（参考 R.string.theme=主题模式：主题模式
                  // 选择器 + 13 内置色卡同行）。[队列⑦c A3] 恢复页内主题模式
                  // 选择器——此前 2026-08-13 裁决"主题模式仅放「我的」枢纽"，
                  // 本次按参考 IA 指令恢复页内展示；复用既有 ThemeMode 状态与
                  // ThemeNotifier.setThemeMode，非新增功能。
                  // 原「主题导出/导入」独立分区并入下方通用组（对齐参考主题管理
                  // 同簇）；[B3-C1 A3] 导出/导入能力保留不动。
                  const IosSectionHeader('主题模式'),
                  IosGroup(
                      children: [
                        // 参考 ThemeModeSelector（:974-1012）material 引擎分支：
                        // 跟随系统 / 浅色 / 深色（flow_sys/light_mode/dark_mode）
                        _ThemeModeSelector(
                          selected: themeState.themeMode,
                          onChanged: themeNotifier.setThemeMode,
                        ),
                        // 13 套内置 MD3 preset 选择器（UI_MD3_PLAN.md Batch 1，
                        // [队列⑦a A2] 13 色卡横滑一行形态；paletteId 持久化，
                        // 与自定义主题并存——第九节并存模型）
                        _BuiltinPaletteGrid(
                          selectedId: themeState.paletteId,
                          onSelected: themeNotifier.setPaletteId,
                        ),
                      ]),
                  // === 分组 2「主题引擎」（我方 MD3 参数化：paletteStyle +
                  // 对比度；参考版无对应分组——参考"主题风格"=compose 引擎
                  // 开关，属参考独有，仅登记不实现）。[队列⑦c A3] AMOLED 纯黑
                  // 移出本组，改入通用组首位（对齐参考 纯黑深色模式 首位） ===
                  const IosSectionHeader('主题引擎'),
                  IosGroup(
                      children: [
                    IosListTile(
                      title: '配色风格',
                      subtitle: _styleLabel(ui.themeStyle),
                      onTap: _showThemeStylePicker,
                    ),
                    if (ui.themeStyle != 'none')
                      IosListTile(
                        title: '对比度',
                        subtitle: _contrastLabel(ui.themeContrastLevel),
                        onTap: _showContrastPicker,
                      ),
                  ]),

                  // === 分组 3 通用（无分组标题，对齐参考版未分组通用组；
                  // 参考顺序 纯黑→切换图标→字体大小→主题管理→背景图片；
                  // 参考独有 字体设置/自定义颜色/compose 引擎/预见性返回手势
                  // 仅登记不实现） ===
                  // [队列⑦c A3] 通用组排序：纯黑深色模式（自主题引擎移入，
                  // 对齐参考 纯黑 首位）→ 切换图标 → 字体大小 → 主题管理
                  // （原主题列表改名）→ 导出/导入主题（原顶部分区并入）→ 其余
                  // 我方项保持原有相对顺序
                  IosGroup(
                      children: [
                    // 纯黑深色模式（参考 pure_black=纯黑深色模式；原"AMOLED
                    // 纯黑"，标题对齐参考，副标题保留）
                    SwitchListTile(
                      title: const Text('纯黑深色模式'),
                      subtitle: const Text('暗色模式背景纯黑（省电护屏）'),
                      value: ui.themeAmoled,
                      onChanged: (v) => ref
                          .read(uiSettingsProvider.notifier)
                          .setThemeAmoled(v),
                    ),
                    // 切换图标（参考 change_icon=切换图标，摘要
                    // change_icon_summary=切换软件显示在桌面的图标；
                    // Android/iOS 支持，Windows 等桌面端整项隐藏）
                    if (LauncherIconService.isSupported)
                      IosListTile(
                        title: '切换图标',
                        subtitle: '切换软件显示在桌面的图标',
                        value: _launcherIconLabels[
                            _launcherIcons.indexOf(_launcherIcon).clamp(0, 6)],
                        onTap: _showLauncherIconPicker,
                      ),
                    // 字体大小（参考 font_scale=字体大小；摘要半角冒号对齐
                    // font_scale_summary「当前字体大小: %.1f」，见 theme_state）
                    IosListTile(
                      title: '字体大小',
                      subtitle: themeState.fontScaleLabel,
                      onTap: () => _showFontScalePicker(
                          context, themeState, themeNotifier),
                    ),
                    // 主题管理（参考 theme_pack=主题管理；原"主题列表"改名，
                    // 副标题保留；参考完整主题包管理屏属参考独有，仅登记）
                    IosListTile(
                      title: '主题管理',
                      subtitle: '使用、保存、导入或分享主题',
                      onTap: _showThemeListDialog,
                    ),
                    // 导出/导入主题（[B3-C1 A3] 复用 ThemeColorsNotifier +
                    // ThemeNotifier，全部经主题槽位，无硬编码色值）
                    IosListTile(
                      icon: Symbols.ios_share_rounded,
                      title: '导出主题',
                      subtitle: '将当前配色导出为 JSON 文件',
                      onTap: _exportTheme,
                    ),
                    IosListTile(
                      icon: Symbols.download_rounded,
                      title: '导入主题',
                      subtitle: '导入主题 JSON 文件并应用',
                      onTap: _importTheme,
                    ),
                    IosListTile(
                      title: '启动界面样式',
                      subtitle: '设定显示时间，更改背景图片，是否显示文字等',
                      onTap: () {
                        Navigator.of(context)
                            .pushNamed(AppRoutes.welcomeConfig);
                      },
                    ),
                    SwitchListTile(
                      title: const Text('沉浸式状态栏'),
                      subtitle: const Text('状态栏颜色透明'),
                      value: _transparentStatusBar,
                      onChanged: (v) async {
                        setState(() => _transparentStatusBar = v);
                        await ref
                            .read(systemBarProvider.notifier)
                            .setTransparentStatusBar(v);
                      },
                    ),
                    SwitchListTile(
                      title: const Text('沉浸式导航栏'),
                      subtitle: const Text('导航栏颜色透明'),
                      value: _immNavigationBar,
                      onChanged: (v) async {
                        setState(() => _immNavigationBar = v);
                        await ref
                            .read(systemBarProvider.notifier)
                            .setImmNavigationBar(v);
                      },
                    ),
                    IosListTile(
                      title: '导航栏阴影',
                      subtitle: '当前阴影大小（elevation）：$_barElevation',
                      onTap: _showBarElevationDialog,
                    ),
                    IosListTile(
                      title: '封面设置',
                      subtitle: '通用封面规则及默认封面样式',
                      onTap: _showCoverConfigDialog,
                    ),
                    IosListTile(
                      title: '底栏图集',
                      subtitle: '导入 zip 自定义底栏图标',
                      onTap: () => Navigator.pushNamed(
                        context,
                        AppRoutes.bottomBarSkin,
                      ),
                    ),
                    SwitchListTile(
                      title: const Text('跟随壁纸配色'),
                      subtitle: const Text(
                        '使用系统壁纸色板生成日间和夜间主题（Android 12+/iOS）',
                      ),
                      value: _wallpaperColorFollow,
                      onChanged: (v) {
                        setState(() => _wallpaperColorFollow = v);
                        _settings.setBoolPref(PrefKeys.wallpaperColorFollow, v);
                        // [UI_SYNC_REFACTOR R1] 同步 uiSettings（dynamic_color 接线读取）
                        ref
                            .read(uiSettingsProvider.notifier)
                            .setWallpaperColorFollow(v);
                      },
                    ),
                    if (_wallpaperColorFollow)
                      SwitchListTile(
                        title: const Text('壁纸变化时自动更新'),
                        subtitle: const Text('系统壁纸变化后自动应用新色板'),
                        value: _wallpaperColorAutoUpdate,
                        onChanged: (v) {
                          setState(() => _wallpaperColorAutoUpdate = v);
                          _settings.setBoolPref(
                              PrefKeys.wallpaperColorAutoUpdate, v);
                        },
                      ),
                  ]),

                  // === 分组 4「主界面」（参考 R.string.main_activity=主界面；
                  // [队列⑦c A3] 合并原"顶栏与布局"+"底栏与导航"两组为参考的单
                  // 主界面组，设置经 uiSettings 即时全局生效；参考 首页与导航/
                  // 显示状态栏/启用滑动时动画 属参考独有，仅登记不实现） ===
                  const IosSectionHeader('主界面'),
                  IosGroup(
                      children: [
                    IosListTile(
                      title: '顶栏按钮样式',
                      subtitle: _topBarStyleLabel(ui.topBarButtonStyle),
                      onTap: _showTopBarStylePicker,
                    ),
                    SwitchListTile(
                      title: const Text('合并顶栏按钮'),
                      subtitle: const Text('顶栏按钮收进胶囊容器'),
                      value: ui.mergeTopBarActions,
                      onChanged: (v) => ref
                          .read(uiSettingsProvider.notifier)
                          .setMergeTopBarActions(v),
                    ),
                    SwitchListTile(
                      title: const Text('大顶栏形态'),
                      subtitle: const Text('书架/我的等根页使用可折叠大标题'),
                      value: ui.useFlexibleTopAppBar,
                      onChanged: (v) => ref
                          .read(uiSettingsProvider.notifier)
                          .setUseFlexibleTopAppBar(v),
                    ),
                    IosListTile(
                      title: '顶栏不透明度',
                      subtitle: '当前 ${ui.topBarOpacity}%',
                      onTap: _showTopBarOpacityDialog,
                    ),
                    SwitchListTile(
                      title: const Text('显示底栏'),
                      subtitle: const Text('隐藏后仅侧栏/手势切页'),
                      value: ui.showBottomView,
                      onChanged: (v) => ref
                          .read(uiSettingsProvider.notifier)
                          .setShowBottomView(v),
                    ),
                    SwitchListTile(
                      title: const Text('悬浮底栏'),
                      subtitle: const Text('64dp 胶囊悬浮形态（ Experimental）'),
                      value: ui.useFloatingBottomBar,
                      onChanged: (v) => ref
                          .read(uiSettingsProvider.notifier)
                          .setUseFloatingBottomBar(v),
                    ),
                    IosListTile(
                      title: '底栏文字',
                      subtitle: _labelModeLabel(ui.labelVisibilityMode),
                      onTap: _showLabelModePicker,
                    ),
                    IosListTile(
                      title: '底栏不透明度',
                      subtitle: '当前 ${ui.bottomBarOpacity}%',
                      onTap: _showBottomBarOpacityDialog,
                    ),
                    // 大屏导航形态（参考 main_activity 组 tabletInterface=平板界面；
                    // 四档 自动/始终/仅横屏/关闭）
                    IosListTile(
                      title: '大屏导航形态',
                      subtitle: _tabletLabel(ui.tabletInterface),
                      onTap: _showTabletModePicker,
                    ),
                  ]),

                  // === 分组 5「书籍详情页」（参考 R.string.book_info_page=
                  // 书籍详情页；原"详情与圆角"的封面三行；卡片圆角/分隔线移入
                  // 下方"容器设置"组） ===
                  const IosSectionHeader('书籍详情页'),
                  IosGroup(
                      children: [
                    // 参考 book_info_follow_cover_color=界面颜色跟随封面取色，
                    // 摘要 book_info_follow_cover_color_s=仅在显示背景封面时生效
                    SwitchListTile(
                      title: const Text('界面颜色跟随封面取色'),
                      subtitle: const Text('仅在显示背景封面时生效'),
                      value: ui.bookInfoFollowCoverColor,
                      onChanged: (v) => ref
                          .read(uiSettingsProvider.notifier)
                          .setBookInfoFollowCoverColor(v),
                    ),
                    // 参考 book_info_network_cover_background=网络封面背景设置
                    IosListTile(
                      title: '网络封面背景设置',
                      subtitle: _coverBgLabel(ui.bookInfoNetworkCoverBackground),
                      onTap: () => _showCoverBgPicker(false),
                    ),
                    // 参考 book_info_default_cover_background=默认封面背景设置
                    IosListTile(
                      title: '默认封面背景设置',
                      subtitle: _coverBgLabel(ui.bookInfoDefaultCoverBackground),
                      onTap: () => _showCoverBgPicker(true),
                    ),
                  ]),

                  // === 分组 8「容器设置」（参考 R.string
                  // .theme_manage_section_container=容器设置；原"详情与圆角"的
                  // 卡片圆角/分隔线两行；参考 容器背景图/容器背景不透明度/
                  // 关闭设置分组圆角/覆盖卡片边框/边框粗细/日夜卡片边框颜色/
                  // 分割线粗细/长度/颜色 等子项属参考独有，仅登记不实现） ===
                  const IosSectionHeader('容器设置'),
                  IosGroup(
                      children: [
                    // 参考 base_card_corner_radius=卡片圆角（0-40 滑杆）；我方为
                    // 单对话框（覆写开关 + 4-28），参考 覆盖卡片圆角 双行开关
                    // 结构属参考独有，仅登记
                    IosListTile(
                      title: '卡片圆角',
                      subtitle: ui.overrideBaseCardCornerRadius
                          ? '覆写中：${ui.baseCardCornerRadius}dp'
                          : '跟随主题（20dp）',
                      onTap: _showCardRadiusDialog,
                    ),
                    // 参考 show_divider_line=显示分隔线
                    SwitchListTile(
                      title: const Text('显示分隔线'),
                      subtitle: const Text('分组列表行底部显示短分隔线'),
                      value: ui.enableItemDivider,
                      onChanged: (v) => ref
                          .read(uiSettingsProvider.notifier)
                          .setEnableItemDivider(v),
                    ),
                  ]),

                  // === 分组 7「模糊效果」（参考 R.string.blur_effects=模糊效果；
                  // [队列⑦c A3] 原"毛玻璃"改组名对齐参考；我方 启用毛玻璃 +
                  // 顶栏/悬浮底栏模糊参数，参考 启用控件模糊/启用渐变模糊 开关
                  // 结构属参考独有，仅登记；默认关——低端机掉帧保护） ===
                  const IosSectionHeader('模糊效果'),
                  // [B3-C1 A6] 每区独立圆角卡（IosGroup 卡片模式）
                  IosGroup(
                      children: [
                    SwitchListTile(
                      title: const Text('启用毛玻璃'),
                      subtitle: const Text('低端设备开启可能掉帧'),
                      value: ui.enableBlur,
                      onChanged: (v) => ref
                          .read(uiSettingsProvider.notifier)
                          .setEnableBlur(v),
                    ),
                    IosListTile(
                      title: '顶栏模糊',
                      subtitle: ui.enableBlur
                          ? '半径 ${ui.topBarBlurRadius}dp · 底色 ${ui.topBarBlurAlpha}/255'
                          : '需先启用毛玻璃',
                      onTap: ui.enableBlur ? _showTopBarBlurDialog : null,
                    ),
                    IosListTile(
                      title: '悬浮底栏模糊',
                      subtitle: ui.enableBlur
                          ? '半径 ${ui.bottomBarBlurRadius}dp · 底色 ${ui.bottomBarBlurAlpha}/255'
                          : '需先启用毛玻璃',
                      onTap:
                          ui.enableBlur ? _showBottomBarBlurDialog : null,
                    ),
                  ]),

                  // === 自定义主题·白天（对齐原版 day category，themeConfigList
                  // 功能完整保留——UI_MD3_PLAN.md 第九节） ===
                  const IosSectionHeader('自定义主题 · 白天'),
                  // [B3-C1 A6] 每区独立圆角卡（IosGroup 卡片模式）
                  IosGroup(
                      children: [
                    _colorTile(PrefKeys.cPrimary, '主色调', colors),
                    _colorTile(PrefKeys.cAccent, '强调色', colors),
                    _colorTile(PrefKeys.cBackground, '背景色', colors,
                        isBackground: true),
                    _colorTile(PrefKeys.cBBackground, '底部操作栏颜色', colors),
                    IosListTile(
                      icon: Symbols.wallpaper_rounded,
                      title: '背景图片',
                      subtitle: _bgImage.isEmpty ? '未设置' : _bgImage,
                      onTap: () => _showBgImageDialog(PrefKeys.bgImage),
                    ),
                    SwitchListTile(
                      title: const Text('透明导航栏'),
                      subtitle: const Text(_androidOnly),
                      value: _transparentNavBar,
                      onChanged: (v) {
                        setState(() => _transparentNavBar = v);
                        _settings.setBoolPref(PrefKeys.transparentNavBar, v);
                      },
                    ),
                    IosListTile(
                      icon: Symbols.save_rounded,
                      title: '保存白天主题',
                      subtitle: '将当前白天颜色保存到主题列表',
                      onTap: () => _saveTheme(isNight: false),
                    ),
                  ]),

                  // === 自定义主题·夜间（对齐原版 night category）===
                  const IosSectionHeader('自定义主题 · 夜间'),
                  // [B3-C1 A6] 每区独立圆角卡（IosGroup 卡片模式）
                  IosGroup(
                      children: [
                    _colorTile(PrefKeys.cNPrimary, '主色调', colors,
                        isNight: true),
                    _colorTile(PrefKeys.cNAccent, '强调色', colors,
                        isNight: true),
                    _colorTile(PrefKeys.cNBackground, '背景色', colors,
                        isNight: true, isBackground: true),
                    _colorTile(PrefKeys.cNBBackground, '底部操作栏颜色', colors,
                        isNight: true),
                    IosListTile(
                      icon: Symbols.wallpaper_rounded,
                      title: '背景图片',
                      subtitle: _bgImageNight.isEmpty ? '未设置' : _bgImageNight,
                      onTap: () => _showBgImageDialog(PrefKeys.bgImageN),
                    ),
                    SwitchListTile(
                      title: const Text('透明导航栏'),
                      subtitle: const Text(_androidOnly),
                      value: _transparentNavBarNight,
                      onChanged: (v) {
                        setState(() => _transparentNavBarNight = v);
                        _settings.setBoolPref(
                            PrefKeys.transparentNavBarNight, v);
                      },
                    ),
                    IosListTile(
                      icon: Symbols.save_rounded,
                      title: '保存夜间主题',
                      subtitle: '将当前夜间颜色保存到主题列表',
                      onTap: () => _saveTheme(isNight: true),
                    ),
                  ]),
                  const IosSectionFooter(
                      '背景图片将作为全局窗口壁纸显示（分组列表卡片保持不透明底）'),
                ],
              ),
            ),
    );
  }

  /// 颜色配置行（值为空时显示"默认"，否则显示色块）
  Widget _colorTile(
    String key,
    String title,
    ThemeColorsState colors, {
    bool isNight = false,
    bool isBackground = false,
  }) {
    final value = colors.valueOf(key);
    return IosListTile(
      icon: Symbols.palette_rounded,
      title: title,
      value: value == null ? '默认' : null,
      trailing: value == null
          ? null
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 22,
                  height: 22,
                  decoration: BoxDecoration(
                    color: Color(value),
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: Theme.of(context).colorScheme.outlineVariant,
                    ),
                  ),
                ),
              ],
            ),
      onTap: () => _showColorPicker(
        key,
        title,
        isNight: isNight,
        isBackground: isBackground,
      ),
    );
  }

  /// 预设色板选择器（对齐原版 ColorPreference preset 对话框 + 背景明暗校验）
  Future<void> _showColorPicker(
    String key,
    String title, {
    required bool isNight,
    required bool isBackground,
  }) async {
    final selected = await showDialog<int>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: SizedBox(
          width: 300,
          child: Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              for (final c in _presetColors)
                InkWell(
                  onTap: () => Navigator.pop(ctx, c),
                  borderRadius: BorderRadius.circular(20),
                  child: Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: Color(c),
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: Theme.of(ctx).colorScheme.outlineVariant,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
        actions: [
          // 对齐原版长按恢复默认：清除自定义值
          TextButton(
            onPressed: () {
              ref
                  .read(themeColorsProvider.notifier)
                  .setColor(key, null);
              Navigator.pop(ctx);
            },
            child: const Text('恢复默认'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
        ],
      ),
    );
    // [UI-fix v2.0.5 | 2026-08-08] 异步对话框返回后统一补 mounted 防护，
    // 避免页面已销毁时继续使用 ref/setState — Qoder
    if (selected == null || !mounted) return;
    // 对齐原版 onColorSelected 背景明暗校验（白天背景过暗/夜间背景过亮拒绝）
    if (isBackground) {
      final isLight = ThemeData.estimateBrightnessForColor(Color(selected)) ==
          Brightness.light;
      if (!isNight && !isLight) {
        _toast('白天背景不能太暗');
        return;
      }
      if (isNight && isLight) {
        _toast('夜间背景不能太亮');
        return;
      }
    }
    await ref.read(themeColorsProvider.notifier).setColor(key, selected);
  }

  /// 启动图标选择（对齐原版 launcherIcon ListPreference，仅 Android 生效）
  Future<void> _showLauncherIconPicker() async {
    final selected = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('启动图标'),
        children: [
          // 用 RadioGroup 统一管理选中值（避免 groupValue/onChanged 废弃 API）
          RadioGroup<String>(
            groupValue: _launcherIcon,
            onChanged: (v) => Navigator.pop(ctx, v),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (var i = 0; i < _launcherIcons.length; i++)
                  RadioListTile<String>(
                    title: Text(_launcherIconLabels[i]),
                    value: _launcherIcons[i],
                  ),
              ],
            ),
          ),
        ],
      ),
    );
    if (selected == null || !mounted) return;
    setState(() => _launcherIcon = selected);
    await _settings.setStringPref(PrefKeys.launcherIcon, selected);
    // 下发原生侧实际切换（Android setComponentEnabledSetting /
    // iOS setAlternateIconName）；失败时提示真实原因，不阻断偏好保存
    final result = await LauncherIconService.setIcon(selected);
    if (!mounted) return;
    if (result.ok) {
      if (LauncherIconService.isIos) {
        _toast('图标已切换，重启应用后生效');
      }
    } else {
      // 展示原生侧真实错误（如 iOS"本次启动已切换过一次"、Android API<26），
      // 不再笼统提示"当前平台或系统版本不支持"
      _toast(result.message ?? '当前平台或系统版本不支持更换图标');
    }
  }

  /// 封面设置（对齐原版 pref_config_cover 布尔项；封面规则依赖书源引擎，
  /// 已登记台账后置）
  Future<void> _showCoverConfigDialog() async {
    var onlyWifi = await _settings.getBoolPref(
      PrefKeys.loadCoverOnlyWifi,
      defaultValue: false,
    );
    var useDefault = await _settings.getBoolPref(
      PrefKeys.useDefaultCover,
      defaultValue: false,
    );
    var showName = await _settings.getBoolPref(
      PrefKeys.coverShowName,
      defaultValue: true,
    );
    var showAuthor = await _settings.getBoolPref(
      PrefKeys.coverShowAuthor,
      defaultValue: true,
    );
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('封面设置'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('仅 Wifi 加载封面'),
                value: onlyWifi,
                onChanged: (v) {
                  setDialogState(() => onlyWifi = v);
                  _settings.setBoolPref(PrefKeys.loadCoverOnlyWifi, v);
                },
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('优先使用默认封面'),
                value: useDefault,
                onChanged: (v) {
                  setDialogState(() => useDefault = v);
                  _settings.setBoolPref(PrefKeys.useDefaultCover, v);
                },
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('默认封面显示书名'),
                value: showName,
                onChanged: (v) {
                  setDialogState(() => showName = v);
                  _settings.setBoolPref(PrefKeys.coverShowName, v);
                },
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('默认封面显示作者'),
                value: showAuthor,
                onChanged: (v) {
                  setDialogState(() => showAuthor = v);
                  _settings.setBoolPref(PrefKeys.coverShowAuthor, v);
                },
              ),
              // F4：对齐原版 CoverRuleConfigDialog（get/save/delete + 测试搜索）
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('封面规则'),
                subtitle: const Text('配置搜索 URL 与提取规则，可按书名测试'),
                onTap: _showCoverRuleConfigDialog,
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('关闭'),
            ),
          ],
        ),
      ),
    );
  }

  /// 封面规则配置对话框（契约 §2.4 F4；对齐原版 CoverRuleConfigDialog）
  Future<void> _showCoverRuleConfigDialog() async {
    final api = ref.read(bookApiProvider);
    await showDialog<void>(
      context: context,
      builder: (_) => _CoverRuleConfigDialog(
        loadRule: api.getCoverRule,
        saveRule: api.saveCoverRule,
        deleteRule: api.deleteCoverRule,
        onSearch: api.searchCoverRules,
      ),
    );
  }

  // ===== 主题列表（对齐原版 ThemeConfig.configList 本地版）=====

  static const _themeListKey = 'themeConfigList';

  /// 读取已保存主题配置列表
  Future<List<Map<String, dynamic>>> _loadThemeList() async {
    final raw = await _settings.getStringPref(_themeListKey);
    if (raw.isEmpty) return [];
    try {
      return (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
    } catch (e) {
      debugPrint('ThemeConfigScreen._loadThemeList 解析异常: $e');
      return [];
    }
  }

  /// 主题管理对话框（[队列⑦c A3] 原"主题列表"改名对齐参考 theme_pack=主题管理）：
  /// 点击应用、删除按钮移除
  Future<void> _showThemeListDialog() async {
    var list = await _loadThemeList();
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          // [队列⑦c A3] 对话框标题与入口行一致（主题管理）
          title: const Text('主题管理'),
          content: SizedBox(
            width: 320,
            child: list.isEmpty
                ? const Padding(
                    padding: EdgeInsets.all(16),
                    child: Text('暂无保存的主题配置\n可在下方"保存白天/夜间主题"后于此切换'),
                  )
                : ListView.builder(
                    shrinkWrap: true,
                    itemCount: list.length,
                    itemBuilder: (ctx2, index) {
                      final item = list[index];
                      final isNight = item['isNight'] == true;
                      return ListTile(
                        leading: Icon(
                          isNight ? Symbols.dark_mode_rounded : Symbols.light_mode_rounded,
                        ),
                        title: Text('${item['name'] ?? '未命名'}'),
                        subtitle: Text(isNight ? '夜间主题' : '白天主题'),
                        trailing: IconButton(
                          icon: const Icon(Symbols.delete_rounded),
                          onPressed: () async {
                            list = List.of(list)..removeAt(index);
                            await _settings.setStringPref(
                                _themeListKey, jsonEncode(list));
                            setDialogState(() {});
                          },
                        ),
                        onTap: () async {
                          await _applyThemeConfig(item);
                          if (ctx.mounted) Navigator.pop(ctx);
                        },
                      );
                    },
                  ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('关闭'),
            ),
          ],
        ),
      ),
    );
  }

  /// 应用一份已保存的主题配置（按日/夜写入对应颜色组）
  Future<void> _applyThemeConfig(Map<String, dynamic> config) async {
    final isNight = config['isNight'] == true;
    await ref.read(themeColorsProvider.notifier).applyColors({
      if (isNight) ...{
        PrefKeys.cNPrimary: config['primary'] as int?,
        PrefKeys.cNAccent: config['accent'] as int?,
        PrefKeys.cNBackground: config['background'] as int?,
        PrefKeys.cNBBackground: config['bottomBackground'] as int?,
      } else ...{
        PrefKeys.cPrimary: config['primary'] as int?,
        PrefKeys.cAccent: config['accent'] as int?,
        PrefKeys.cBackground: config['background'] as int?,
        PrefKeys.cBBackground: config['bottomBackground'] as int?,
      },
    });
    _toast('已应用主题「${config['name'] ?? '未命名'}」');
  }

  /// 保存当前日/夜颜色为命名主题（对齐原版 saveDayTheme/saveNightTheme）
  Future<void> _saveTheme({required bool isNight}) async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(isNight ? '保存夜间主题' : '保存白天主题'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: '主题名称'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    if (name == null || name.isEmpty || !mounted) return;
    final colors = ref.read(themeColorsProvider);
    final list = await _loadThemeList();
    list.add({
      'name': name,
      'isNight': isNight,
      'primary': isNight ? colors.primaryNight : colors.primary,
      'accent': isNight ? colors.accentNight : colors.accent,
      'background': isNight ? colors.backgroundNight : colors.background,
      'bottomBackground':
          isNight ? colors.bottomBackgroundNight : colors.bottomBackground,
    });
    await _settings.setStringPref(_themeListKey, jsonEncode(list));
    _toast('已保存主题「$name」');
  }

  // ===== [B3-C1 A3 | 全栈工程师 + UI] 导出/导入主题（文件级最小实现） =====
  // grep 结论：既有能力仅有 SharedPreferences 内 themeConfigList 保存/应用
  // 与 association 关联导入（数据级），无文件级导入导出 → 此处最小实现：
  // 导出当前配色 JSON / 导入应用。颜色值全部来自主题槽位
  // （ThemeColorsState 的 ARGB int + paletteId + themeMode），无硬编码色值。

  /// ThemeMode → JSON 名称
  static String _themeModeName(ThemeMode mode) => switch (mode) {
        ThemeMode.light => 'light',
        ThemeMode.dark => 'dark',
        _ => 'system',
      };

  /// 导出当前配色为 JSON 文件（paletteId + 主题模式 + 日/夜 4 色组）
  Future<void> _exportTheme() async {
    final colors = ref.read(themeColorsProvider);
    final themeState = ref.read(themeNotifierProvider);
    final payload = <String, dynamic>{
      'app': 'legado',
      'type': 'theme',
      'version': 1,
      'paletteId': themeState.paletteId,
      'themeMode': _themeModeName(themeState.themeMode),
      'day': <String, int?>{
        'primary': colors.primary,
        'accent': colors.accent,
        'background': colors.background,
        'bottomBackground': colors.bottomBackground,
      },
      'night': <String, int?>{
        'primary': colors.primaryNight,
        'accent': colors.accentNight,
        'background': colors.backgroundNight,
        'bottomBackground': colors.bottomBackgroundNight,
      },
    };
    final path = await FilePicker.platform.saveFile(
      dialogTitle: '导出主题',
      fileName: 'legado_theme.json',
    );
    if (path == null || !mounted) return;
    try {
      await File(path).writeAsString(
        const JsonEncoder.withIndent('  ').convert(payload),
      );
      _toast('主题已导出');
    } catch (e) {
      debugPrint('ThemeConfigScreen._exportTheme 写入异常: $e');
      if (mounted) _toast('导出失败：$e');
    }
  }

  /// 导入主题 JSON 并应用（日/夜颜色组 + paletteId + 主题模式）
  Future<void> _importTheme() async {
    final result = await FilePicker.platform.pickFiles(
      dialogTitle: '导入主题',
      type: FileType.custom,
      allowedExtensions: ['json'],
    );
    final path = result?.files.single.path;
    if (path == null || !mounted) return;
    dynamic decoded;
    try {
      decoded = jsonDecode(await File(path).readAsString());
    } catch (e) {
      debugPrint('ThemeConfigScreen._importTheme 解析异常: $e');
      _toast('导入失败：主题文件格式不正确');
      return;
    }
    if (decoded is! Map<String, dynamic>) {
      _toast('导入失败：主题文件格式不正确');
      return;
    }

    final notifier = ref.read(themeColorsProvider.notifier);
    // 日/夜颜色组：缺省组整组恢复默认（null 清除），保证导入结果确定
    final dayMap = decoded['day'] is Map<String, dynamic>
        ? (decoded['day'] as Map<String, dynamic>)
        : const <String, dynamic>{};
    final nightMap = decoded['night'] is Map<String, dynamic>
        ? (decoded['night'] as Map<String, dynamic>)
        : const <String, dynamic>{};
    int? intOf(Map<String, dynamic> m, String k) {
      final v = m[k];
      return v is int ? v : (v is num ? v.toInt() : null);
    }

    await notifier.applyColors({
      PrefKeys.cPrimary: intOf(dayMap, 'primary'),
      PrefKeys.cAccent: intOf(dayMap, 'accent'),
      PrefKeys.cBackground: intOf(dayMap, 'background'),
      PrefKeys.cBBackground: intOf(dayMap, 'bottomBackground'),
      PrefKeys.cNPrimary: intOf(nightMap, 'primary'),
      PrefKeys.cNAccent: intOf(nightMap, 'accent'),
      PrefKeys.cNBackground: intOf(nightMap, 'background'),
      PrefKeys.cNBBackground: intOf(nightMap, 'bottomBackground'),
    });

    // paletteId（未知 id 经 Md3Palettes.byId 回退默认 def，安全）
    final paletteId = decoded['paletteId'];
    if (paletteId is String && paletteId.isNotEmpty) {
      await ref.read(themeNotifierProvider.notifier).setPaletteId(paletteId);
    }
    // 主题模式（未知值忽略）
    switch (decoded['themeMode']) {
      case 'light':
        await ref.read(themeNotifierProvider.notifier).setThemeMode(
              ThemeMode.light,
            );
      case 'dark':
        await ref.read(themeNotifierProvider.notifier).setThemeMode(
              ThemeMode.dark,
            );
      case 'system':
        await ref.read(themeNotifierProvider.notifier).setThemeMode(
              ThemeMode.system,
            );
      default:
        break;
    }
    if (mounted) _toast('主题已导入');
  }

  /// 背景图片选择/删除（对齐原版 backgroundImage；经 ThemeColorsNotifier
  /// 驱动 MaterialApp 全局壁纸即时生效）
  Future<void> _showBgImageDialog(String key) async {
    final isNight = key == PrefKeys.bgImageN;
    final current = isNight ? _bgImageNight : _bgImage;
    final action = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('背景图片'),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, 'select'),
            child: const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Text('选择图片'),
            ),
          ),
          if (current.isNotEmpty)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, 'delete'),
              child: const Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: Text('删除'),
              ),
            ),
        ],
      ),
    );
    // 异步对话框/文件选择器返回后先检查 mounted，再 setState/持久化
    if (!mounted) return;
    if (action == 'select') {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.image,
        dialogTitle: '选择背景图片',
      );
      final path = result?.files.single.path;
      if (path == null || !mounted) return;
      setState(() {
        if (isNight) {
          _bgImageNight = path;
        } else {
          _bgImage = path;
        }
      });
      final notifier = ref.read(themeColorsProvider.notifier);
      if (isNight) {
        await notifier.setBgImage(night: path);
      } else {
        await notifier.setBgImage(day: path);
      }
    } else if (action == 'delete') {
      setState(() {
        if (isNight) {
          _bgImageNight = '';
        } else {
          _bgImage = '';
        }
      });
      final notifier = ref.read(themeColorsProvider.notifier);
      if (isNight) {
        await notifier.setBgImage(night: '');
      } else {
        await notifier.setBgImage(day: '');
      }
    }
  }

  /// 导航栏阴影数值设置（对齐原版 barElevation NumberPicker 0~32）
  Future<void> _showBarElevationDialog() async {
    final value = await _showNumberInputDialog(
      title: '导航栏阴影',
      current: _barElevation,
      min: 0,
      max: 32,
    );
    // 异步对话框返回后先检查 mounted，再 setState/持久化
    if (value == null || !mounted) return;
    setState(() => _barElevation = value);
    await _settings.setIntPref(PrefKeys.barElevation, value);
  }

  /// 通用数字输入对话框（返回 null 表示取消）
  Future<int?> _showNumberInputDialog({
    required String title,
    required int current,
    required int min,
    required int max,
  }) async {
    final controller = TextEditingController(text: '$current');
    return showDialog<int>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: TextInputType.number,
          decoration: InputDecoration(hintText: '$min ~ $max'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              final parsed = int.tryParse(controller.text.trim());
              if (parsed == null || parsed < min || parsed > max) {
                _toast('请输入 $min ~ $max 之间的数字');
                return;
              }
              Navigator.pop(ctx, parsed);
            },
            child: const Text('确定'),
          ),
        ],
      ),
    );
  }

  /// 全局字体缩放选择（对齐原版 ThemeConfigFragment fontScale NumberPickerDialog）
  ///
  /// 原版取值 8~16（0.8x~1.6x），「默认」按钮重置为 0（跟随系统）。
  void _showFontScalePicker(
    BuildContext context,
    ThemeState themeState,
    ThemeNotifier notifier,
  ) {
    // 跟随系统时默认展示 1.0x
    var current = themeState.fontScaleRaw.toDouble();
    if (current < 8 || current > 16) current = 10;
    showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('字体缩放'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // [队列⑦c A3] 半角冒号 + 空格，对齐参考 font_scale_summary
              // 「当前字体大小: %.1f」（values-zh-rCN/strings.xml :1203），
              // 与 theme_state.fontScaleLabel 保持一致
              Text(
                '当前字体大小: ${(current / 10).toStringAsFixed(1)}',
                style: Theme.of(ctx).textTheme.bodyMedium,
              ),
              const SizedBox(height: 8),
              Slider(
                value: current,
                min: 8,
                max: 16,
                divisions: 8,
                label: (current / 10).toStringAsFixed(1),
                onChanged: (v) => setDialogState(() => current = v),
              ),
            ],
          ),
          actions: [
            // 对齐原版「默认」按钮：重置为跟随系统
            TextButton(
              onPressed: () {
                notifier.setFontScale(0);
                Navigator.pop(ctx);
              },
              child: const Text('跟随系统'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () {
                notifier.setFontScale(current.round());
                Navigator.pop(ctx);
              },
              child: const Text('确定'),
            ),
          ],
        ),
      ),
    );
  }
}

/// 封面规则配置对话框（对齐原版 CoverRuleConfigDialog + 测试搜索）
/// F4 | 2026-08-13 — Auto + UI
class _CoverRuleConfigDialog extends StatefulWidget {
  final Future<Map<String, dynamic>> Function() loadRule;
  final Future<bool> Function(Map<String, dynamic> rule) saveRule;
  final Future<bool> Function() deleteRule;
  final Future<List<String>> Function(String name) onSearch;

  const _CoverRuleConfigDialog({
    required this.loadRule,
    required this.saveRule,
    required this.deleteRule,
    required this.onSearch,
  });

  @override
  State<_CoverRuleConfigDialog> createState() => _CoverRuleConfigDialogState();
}

class _CoverRuleConfigDialogState extends State<_CoverRuleConfigDialog> {
  late final TextEditingController _searchUrlController =
      TextEditingController();
  late final TextEditingController _coverRuleController =
      TextEditingController();
  late final TextEditingController _nameController = TextEditingController();
  bool _enable = true;
  bool _loading = true;
  bool _saving = false;
  bool _searching = false;
  bool _searched = false;
  String? _error;
  List<String> _results = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _searchUrlController.dispose();
    _coverRuleController.dispose();
    _nameController.dispose();
    super.dispose();
  }

  String _errMsg(Object e) => e is BridgeError ? e.message : e.toString();

  Future<void> _load() async {
    try {
      final rule = await widget.loadRule();
      if (!mounted) return;
      setState(() {
        _enable = rule['enable'] == true || rule['enable'] == 1;
        _searchUrlController.text = '${rule['searchUrl'] ?? ''}';
        _coverRuleController.text = '${rule['coverRule'] ?? ''}';
        _loading = false;
      });
    } catch (e) {
      debugPrint('CoverRuleConfig 加载失败: $e');
      if (!mounted) return;
      setState(() {
        _error = '加载失败: ${_errMsg(e)}';
        _loading = false;
      });
    }
  }

  Future<void> _save() async {
    final searchUrl = _searchUrlController.text.trim();
    final coverRule = _coverRuleController.text.trim();
    if (searchUrl.isEmpty || coverRule.isEmpty) {
      setState(() => _error = '搜索url和cover规则不能为空');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.saveRule({
        'enable': _enable,
        'searchUrl': searchUrl,
        'coverRule': coverRule,
      });
      if (!mounted) return;
      Navigator.pop(context);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '保存失败: ${_errMsg(e)}';
        _saving = false;
      });
    }
  }

  Future<void> _delete() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.deleteRule();
      if (!mounted) return;
      Navigator.pop(context);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '删除失败: ${_errMsg(e)}';
        _saving = false;
      });
    }
  }

  Future<void> _search() async {
    final name = _nameController.text.trim();
    if (name.isEmpty) {
      setState(() => _error = '请输入书名');
      return;
    }
    setState(() {
      _searching = true;
      _error = null;
    });
    try {
      final list = await widget.onSearch(name);
      if (!mounted) return;
      setState(() {
        _results = list;
        _searched = true;
        _searching = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '搜索失败: ${_errMsg(e)}';
        _results = [];
        _searched = true;
        _searching = false;
      });
    }
  }

  void _preview(String url) {
    showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('封面预览'),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 360),
          child: Image.network(
            url,
            fit: BoxFit.contain,
            errorBuilder: (_, _, _) => const Padding(
              padding: EdgeInsets.all(16),
              child: Text('图片加载失败'),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  void _copy(String url) {
    Clipboard.setData(ClipboardData(text: url));
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(const SnackBar(content: Text('封面 URL 已复制')));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('封面规则'),
      content: SizedBox(
        width: double.maxFinite,
        child: _loading
            ? const Padding(
                padding: EdgeInsets.all(24),
                child: Center(child: CircularProgressIndicator()),
              )
            : SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('启用'),
                      value: _enable,
                      onChanged: _saving
                          ? null
                          : (v) => setState(() => _enable = v),
                    ),
                    TextField(
                      controller: _searchUrlController,
                      decoration: const InputDecoration(
                        labelText: '搜索 URL',
                        hintText: '支持 {{key}} 模板',
                        border: OutlineInputBorder(),
                      ),
                      minLines: 2,
                      maxLines: 4,
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _coverRuleController,
                      decoration: const InputDecoration(
                        labelText: '封面提取规则',
                        border: OutlineInputBorder(),
                      ),
                      minLines: 2,
                      maxLines: 6,
                    ),
                    const SizedBox(height: 16),
                    Text(
                      '按书名测试',
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _nameController,
                            decoration: const InputDecoration(
                              hintText: '输入书名',
                              border: OutlineInputBorder(),
                            ),
                            onSubmitted: (_) => _search(),
                          ),
                        ),
                        const SizedBox(width: 8),
                        FilledButton(
                          onPressed: _searching || _saving ? null : _search,
                          child: const Text('测试'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    if (_searching)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 16),
                        child: Center(
                          child: SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                        ),
                      )
                    else if (_error != null)
                      Text(
                        _error!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                          fontSize: 13,
                        ),
                      )
                    else if (_searched && _results.isEmpty)
                      const Text(
                        '未搜到候选封面（无启用规则或全部失败）',
                        style: TextStyle(fontSize: 13),
                      )
                    else if (_results.isNotEmpty)
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxHeight: 200),
                        child: ListView.separated(
                          shrinkWrap: true,
                          itemCount: _results.length,
                          separatorBuilder: (_, _) =>
                              const Divider(height: 1),
                          itemBuilder: (_, i) {
                            final url = _results[i];
                            return ListTile(
                              dense: true,
                              contentPadding: EdgeInsets.zero,
                              title: Text(
                                url,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 12),
                              ),
                              trailing: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  IconButton(
                                    icon: const Icon(
                                      Symbols.image_rounded,
                                      size: 18,
                                    ),
                                    tooltip: '预览',
                                    visualDensity: VisualDensity.compact,
                                    onPressed: () => _preview(url),
                                  ),
                                  IconButton(
                                    icon: const Icon(Symbols.content_copy_rounded, size: 18),
                                    tooltip: '复制',
                                    visualDensity: VisualDensity.compact,
                                    onPressed: () => _copy(url),
                                  ),
                                ],
                              ),
                            );
                          },
                        ),
                      ),
                  ],
                ),
              ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : _delete,
          child: Text(
            '删除',
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ),
        TextButton(
          onPressed: _saving ? null : () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: _saving
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('确定'),
        ),
      ],
    );
  }
}

/// 主题模式三选分段控件（跟随系统 / 浅色 / 深色）。
///
/// [队列⑦c A3] 对齐参考 ThemeModeSelector（ThemeConfigScreen.kt:974-1012，
/// 3 个相连 ToggleButton，material 引擎分支文案 跟随系统/浅色/深色，
/// flow_sys/light_mode/dark_mode）。此前 2026-08-13 裁决"主题模式仅放
/// 「我的」枢纽"，本次 A3 任务指令"IA 对齐参考版"予以覆盖，恢复页内选择器；
/// 复用既有 ThemeState.themeMode 与 ThemeNotifier.setThemeMode（经
/// SettingsService 持久化），非新增功能。
class _ThemeModeSelector extends StatelessWidget {
  final ThemeMode selected;
  final ValueChanged<ThemeMode> onChanged;

  const _ThemeModeSelector({
    required this.selected,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          for (final mode in ThemeMode.values)
            Expanded(
              child: _ModeSegment(
                label: switch (mode) {
                  ThemeMode.system => '跟随系统',
                  ThemeMode.light => '浅色',
                  ThemeMode.dark => '深色',
                },
                selected: mode == selected,
                onTap: () => onChanged(mode),
                selectedBg: scheme.primary,
                selectedFg: scheme.onPrimary,
                normalBg: scheme.surfaceContainerHighest,
                normalFg: scheme.onSurface,
              ),
            ),
        ],
      ),
    );
  }
}

/// 主题模式选择器单段（相连三段，圆角矩形 + 选中主色底，对齐参考 3 相连
/// ToggleButton 形态）
class _ModeSegment extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  final Color selectedBg;
  final Color selectedFg;
  final Color normalBg;
  final Color normalFg;

  const _ModeSegment({
    required this.label,
    required this.selected,
    required this.onTap,
    required this.selectedBg,
    required this.selectedFg,
    required this.normalBg,
    required this.normalFg,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 3),
      child: Material(
        color: selected ? selectedBg : normalBg,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(8),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: Center(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: selected ? selectedFg : normalFg,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 内置 MD3 调色板横滑选择行（UI_MD3_PLAN.md Batch 1「内置 13 主题」区，
/// 阶段D 2.0.270 起 13 套：def「默认」为默认选中，wh 黑白等 12 套保留）
///
/// [队列⑦a A2] 形态对齐参考 ThemeColorSelector（ThemeConfigScreen.kt:1020，
/// LazyRow 横滑一行 + Arrangement.spacedBy(16.dp) :1031-1032）。
/// 每张卡片左半为亮色预览、右半为暗色预览（tonal 配对），底部显示
/// 中文主题名；选中项 2dp 主色描边 + 40dp 主色圆角底对勾。点按经
/// [ThemeNotifier] 全局实时生效并持久化 paletteId。
class _BuiltinPaletteGrid extends StatelessWidget {
  final String selectedId;
  final ValueChanged<String> onSelected;

  const _BuiltinPaletteGrid({
    required this.selectedId,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    // 横滑一行（参考 LazyRow；卡间距 16 对齐 spacedBy(16.dp)）
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          for (var i = 0; i < Md3Palettes.all.length; i += 1) ...[
            if (i > 0) const SizedBox(width: 16),
            _PaletteCard(
              palette: Md3Palettes.all[i],
              selected: Md3Palettes.all[i].id == selectedId,
              onSelected: () => onSelected(Md3Palettes.all[i].id),
            ),
          ],
        ],
      ),
    );
  }
}

/// 单张调色板预览卡片（64x64 方卡，形态对齐参考 ThemeColorButton
/// ThemeConfigScreen.kt:1054：size(64.dp) + RoundedCornerShape(16.dp)
/// :1089-1096；选中 2dp 主色描边 :1092-1095；选中 40dp/12dp 圆角主色底
/// 24dp 对勾 :1134-1148；12dp 下距 :1152；labelSmall 标签
/// :1154-1158）
///
/// 卡片内部保留我方左亮/右暗 surface 预览 + 色点（功能实现倾向我方；
/// 参考为 48dp 半圆 arc 单模式预览 :1102-1132）。
class _PaletteCard extends StatelessWidget {
  final Md3Palette palette;
  final bool selected;
  final VoidCallback onSelected;

  const _PaletteCard({
    required this.palette,
    required this.selected,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final light = Color(palette.light.surface);
    final dark = Color(palette.dark.surface);
    final primary = Color(palette.light.primary);
    final secondary = Color(palette.light.secondary);
    final tertiary = Color(palette.light.tertiary);

    return SizedBox(
      width: 64,
      child: InkWell(
        onTap: onSelected,
        borderRadius: BorderRadius.circular(16),
        child: Column(
          children: [
            SizedBox(
              height: 64,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  Container(
                    decoration: BoxDecoration(
                      color: scheme.surfaceContainer,
                      borderRadius: BorderRadius.circular(16),
                      // 参考：选中 2dp 主色描边，未选中无描边（:1092-1095 else null）
                      border: selected
                          ? Border.all(color: primary, width: 2)
                          : null,
                    ),
                    clipBehavior: Clip.antiAlias,
                    // 左亮右暗：展示该套调色板的 tonal 亮暗配对
                    child: Row(
                      children: [
                        Expanded(
                          child: ColoredBox(
                            color: light,
                            child: Center(
                              child: _PaletteDots(
                                primary: primary,
                                secondary: secondary,
                                tertiary: tertiary,
                              ),
                            ),
                          ),
                        ),
                        Expanded(
                          child: ColoredBox(
                            color: dark,
                            child: Center(
                              child: _PaletteDots(
                                primary: primary,
                                secondary: secondary,
                                tertiary: tertiary,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (selected)
                    Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color: primary,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Icon(
                        Icons.check,
                        size: 24,
                        color: scheme.onPrimary,
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Text(
              palette.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: selected ? primary : scheme.onSurface,
                  ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 预览色点行（primary/secondary/tertiary 三点示意）
class _PaletteDots extends StatelessWidget {
  final Color primary;
  final Color secondary;
  final Color tertiary;

  const _PaletteDots({
    required this.primary,
    required this.secondary,
    required this.tertiary,
  });

  @override
  Widget build(BuildContext context) {
    // FittedBox 兜底：[队列⑦a A2] 64px 方卡内左/右半预览区约 30px 宽，
    // 色点行 39px 需缩放下放（原 4 列网格半卡 ~37dp 时的兜底同样适用，
    // md3_acceptance_matrix_test 回归守护）
    return FittedBox(
      fit: BoxFit.scaleDown,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final color in [primary, secondary, tertiary]) ...[
            Container(
              width: 10,
              height: 10,
              margin: const EdgeInsets.symmetric(horizontal: 1.5),
              decoration: BoxDecoration(
                color: color,
                shape: BoxShape.circle,
              ),
            ),
          ],
        ],
      ),
    );
  }
}
