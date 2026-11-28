// [UI-fix v2.0.5 | 2026-08-08] 主题设置页对齐原版 pref_config_theme.xml +
// ThemeConfigFragment（23 项，封面设置已于设置批6b-1 迁至独立页）：启动图标/
// 欢迎页样式/沉浸式状态栏/沉浸式导航栏/导航栏阴影/字体缩放/主题列表/底栏皮肤/
// 壁纸取色 ×2 + 白天/夜间 主色调/强调色/背景色/底栏色/背景图片/透明导航栏/保存主题。
// 颜色配置经 ThemeColorsNotifier 接入 MaterialApp ThemeData 即时生效；
// Android 专属项持久化并以灰字"仅 Android 生效"标注；
// 视觉保持 iOS 分组卡片风格（IosGroup/IosListTile） — Qoder
//
// [批13 | 2026-11-10] 白天/夜间各补「主要字体色」「次要字体色」两行
// （12 槽中的字体色两槽；第 6 槽我方为底栏色、参考为标签容器色），
// 复用既有预设色盘 + 恢复默认（清除=0）；
// 保存/应用 themeConfigList 与导入/导出主题 JSON 同步携带字体色字段，
// 旧数据缺字段按 0（未设置）处理。— 全栈工程师 + UI
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:path_provider/path_provider.dart';
import '../l10n/app_strings.dart';
import '../widgets/app_scaffold.dart';
import '../widgets/container_color_dialog.dart';
import '../widgets/legado_app_bar.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;

import '../constants/pref_keys.dart';
import '../providers/providers.dart';
import '../providers/theme/app_font_notifier.dart';
import '../providers/theme/eye_protection_notifier.dart';
import '../providers/theme/system_bar_notifier.dart';
import '../providers/theme/theme_colors_notifier.dart';
import '../providers/theme/theme_notifier.dart';
import '../providers/ui_settings/ui_settings_notifier.dart';
import '../routes.dart';
import '../services/container_image_picker.dart';
import '../services/export_file_service.dart';
import '../services/launcher_icon_service.dart';
import '../services/settings_service.dart';
import '../services/theme_background_image_store.dart';
import '../services/theme_config_json.dart';
import '../services/theme_package_service.dart';
import '../theme/md3_colors.dart';
import '../utils/color_hex.dart';
import '../utils/error_message.dart';
import '../utils/multi_pane_layout.dart';
import '../widgets/eye_protection_config_sheet.dart';
import '../widgets/ios_widgets.dart';
import '../widgets/setting_slider_row.dart';
import 'main_navigation_settings_sheet.dart';

/// 主题设置页面（对齐原版 ThemeConfigFragment）
///
/// 主题模式与全局字体缩放经 [ThemeNotifier] 全局实时生效；
/// 日间/夜间自定义颜色经 [ThemeColorsNotifier] 驱动 MaterialApp 即时生效。
class ThemeConfigScreen extends ConsumerStatefulWidget {
  const ThemeConfigScreen({
    super.key,
    this.exportFileService = const ExportFileService(),
    this.themePackageFilePicker,
  });

  /// 导出文件服务（测试注入；默认真实落盘实现）
  final ExportFileService exportFileService;

  /// 测试注入：返回已选主题包 zip 路径；null 时走系统文件选择器
  final Future<String?> Function()? themePackageFilePicker;

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

  /// 启动图标可选值（对齐原版 arrays.xml icon_names）
  static const _launcherIcons = [
    'iconMain',
    'icon1',
    'icon2',
    'icon3',
    'icon4',
    'icon5',
    'icon6',
  ];

  /// 启动图标可选值文案（L10N 阶段 2：随 locale 切换，故不再是 const）
  static List<String> get _launcherIconLabels => [
    AppStrings.defaultLabelShort,
    AppStrings.launcherIcon1,
    AppStrings.launcherIcon2,
    AppStrings.launcherIcon3,
    AppStrings.launcherIcon4,
    AppStrings.launcherIcon5,
    AppStrings.launcherIcon6,
  ];

  /// Android 专属项统一灰字标注（与阅读设置面板刘海项先例一致）
  static String get _androidOnly => AppStrings.androidOnlyLabel;

  /// [批13] 字体色行副标题：提示与动态取色叠加时的对比度风险（不改映射）
  static String get _fontColorHint => AppStrings.fontColorDynamicHint;

  @override
  void initState() {
    super.initState();
    _loadSettings();
    // [设置批2b-1b-2b P3] 预热背景图基目录：完成后重建一次，让相对标识从
    // 「未解析」切换为真实图片/可用性判断（不阻塞首帧，失败静默）。
    ThemeBackgroundImageStore.ensureWarm().then((_) {
      if (mounted) setState(() {});
    });
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
    final barElevation = await _settings.getIntPref(
      PrefKeys.barElevation,
      defaultValue: 0,
    );
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
    // [P2.4] 低成本孤儿清理：删除 theme_backgrounds 四个槽位
    // （large_light/large_dark/item_light/item_dark）下未被引用的自有图片与
    // 中断残留 tmp（[设置批2b-1b-2b] 起包含项目图槽位）；非自有命名不动。
    // 基目录未预热时直接跳过，不触发平台通道。
    // [P2 回修] 数据安全：任一 keep 读取失败，或四个 keep 全为空时跳过清理
    //（避免偏好读取异常/空值把用户图片当孤儿删除）；读取失败不影响页面。
    String containerImageLight = '';
    String containerImageDark = '';
    String itemImageLight = '';
    String itemImageDark = '';
    var backgroundPrefsReadable = true;
    try {
      containerImageLight = await _settings.getStringPref(
        PrefKeys.largeContainerBackgroundImageLight,
      );
      containerImageDark = await _settings.getStringPref(
        PrefKeys.largeContainerBackgroundImageDark,
      );
      itemImageLight = await _settings.getStringPref(
        PrefKeys.itemBackgroundImageLight,
      );
      itemImageDark = await _settings.getStringPref(
        PrefKeys.itemBackgroundImageDark,
      );
    } catch (e) {
      backgroundPrefsReadable = false;
      debugPrint('ThemeConfigScreen 读取背景图偏好失败，跳过孤儿清理：$e');
    }
    // [批14] 已保存主题包背景图（theme_light/theme_dark 槽位）也纳入 keep，
    // 否则本次孤儿清理会把导入主题的壁纸删掉；当前全局壁纸同理。
    // [批14 回修 P2-6] 列表读取/解析失败时 themeListReadable=false，
    // 整轮孤儿清理跳过，避免把已保存主题引用的图片误判为孤儿。
    List<Map<String, dynamic>>? savedThemes;
    try {
      savedThemes = await _tryLoadThemeList();
    } catch (e) {
      debugPrint('ThemeConfigScreen 读取主题列表失败（跳过清理）：$e');
    }
    final themeListReadable = savedThemes != null;
    final savedThemeBackgrounds = <String>[];
    if (savedThemes != null) {
      for (final item in savedThemes) {
        final day = item['bgImage'];
        final night = item['bgImageNight'];
        if (day is String && day.isNotEmpty) savedThemeBackgrounds.add(day);
        if (night is String && night.isNotEmpty) {
          savedThemeBackgrounds.add(night);
        }
      }
    }
    final backgroundKeep = <String>[
      containerImageLight,
      containerImageDark,
      itemImageLight,
      itemImageDark,
      bgImage,
      bgImageNight,
      ...savedThemeBackgrounds,
    ];
    if (backgroundPrefsReadable &&
        themeListReadable &&
        backgroundKeep.any((value) => value.isNotEmpty) &&
        ThemeBackgroundImageStore.isWarm) {
      // best effort：清理失败（权限/IO）不得阻断外观页加载
      try {
        ThemeBackgroundImageStore.cleanupOrphansSync(keep: backgroundKeep);
      } catch (e) {
        debugPrint('ThemeConfigScreen 容器背景图孤儿清理失败（不阻断）：$e');
      }
    }
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
    TopBarButtonStyle.plain => AppStrings.topBarStylePlain,
    TopBarButtonStyle.tonal => AppStrings.topBarStyleTonal,
    TopBarButtonStyle.outlined => AppStrings.iconStyleOutline,
    TopBarButtonStyle.glass => AppStrings.topBarStyleGlass,
    TopBarButtonStyle.liquidGlass => AppStrings.topBarStyleLiquidGlass,
  };

  Future<void> _showTopBarStylePicker() async {
    final current = ref.read(uiSettingsProvider).topBarButtonStyle;
    final selected = await showDialog<TopBarButtonStyle>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text(AppStrings.topBarButtonStyle),
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
          title: Text(AppStrings.topBarOpacity),
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
              Text(AppStrings.currentPercent(value.round())),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(AppStrings.cancel),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(AppStrings.confirm),
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

  Future<void> _showBottomBarOpacityDialog() async {
    var value = ref.read(uiSettingsProvider).bottomBarOpacity.toDouble();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: Text(AppStrings.bottomBarOpacity),
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
              Text(AppStrings.currentPercent(value.round())),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(AppStrings.cancel),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(AppStrings.confirm),
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
    TabletInterfaceMode.auto => AppStrings.tabletModeAuto,
    TabletInterfaceMode.always => AppStrings.tabletModeAlways,
    TabletInterfaceMode.landscape => AppStrings.tabletModeLandscape,
    TabletInterfaceMode.off => AppStrings.tabletModeOff,
  };

  Future<void> _showTabletModePicker() async {
    final current = ref.read(uiSettingsProvider).tabletInterface;
    final selected = await showDialog<TabletInterfaceMode>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text(AppStrings.tabletNavMode),
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
      await ref.read(uiSettingsProvider.notifier).setTabletInterface(selected);
    }
  }

  /// [设置批2b-2b] 多栏布局档位文案（对齐参考版 multi_pane.xml 中文条目）
  String _multiPaneLabel(MultiPaneMode m) => switch (m) {
    MultiPaneMode.auto => AppStrings.multiPaneAuto,
    MultiPaneMode.landscape => AppStrings.multiPaneLandscape,
    MultiPaneMode.always => AppStrings.multiPaneAlways,
    MultiPaneMode.off => AppStrings.modeOff,
  };

  Future<void> _showMultiPanePicker() async {
    final current = ref.read(uiSettingsProvider).multiPaneMode;
    final selected = await showDialog<MultiPaneMode>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text(AppStrings.multiPaneLayout),
        children: [
          for (final m in MultiPaneMode.values)
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
                  Flexible(child: Text(_multiPaneLabel(m))),
                ],
              ),
            ),
        ],
      ),
    );
    if (selected != null) {
      await ref.read(uiSettingsProvider.notifier).setMultiPaneMode(selected);
    }
  }

  String _styleLabel(String v) => switch (v) {
    'none' => AppStrings.paletteNone,
    'tonalSpot' => AppStrings.paletteTonalSpot,
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
    final options = <(String, String)>[
      ('none', AppStrings.paletteNone),
      ('tonalSpot', AppStrings.paletteTonalSpot),
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
        title: Text(AppStrings.colorStyle),
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
    '0.5' => AppStrings.contrastMedium,
    '1.0' => AppStrings.contrastHigh,
    _ => AppStrings.contrastDefault,
  };

  Future<void> _showContrastPicker() async {
    final current = ref.read(uiSettingsProvider).themeContrastLevel;
    final options = <(String, String)>[
      ('0.0', AppStrings.contrastDefault),
      ('0.5', AppStrings.contrastMedium),
      ('1.0', AppStrings.contrastHigh),
    ];
    final selected = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text(AppStrings.contrast),
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
    'off' => AppStrings.coverBlurOff,
    'off_for_default' => AppStrings.coverBlurOffForDefault,
    _ => AppStrings.coverBlurOn,
  };

  Future<void> _showCoverBgPicker(bool isDefaultCover) async {
    final uiNow = ref.read(uiSettingsProvider);
    final current = isDefaultCover
        ? uiNow.bookInfoDefaultCoverBackground
        : uiNow.bookInfoNetworkCoverBackground;
    final options = <(String, String)>[
      ('on', AppStrings.coverBlurOn),
      ('off', AppStrings.coverBlurOff),
      ('off_for_default', AppStrings.hideLabel),
    ];
    final selected = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text(AppStrings.coverBackground),
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
              Text(AppStrings.blurRadiusValue(radius.round())),
              Slider(
                value: radius,
                min: 0,
                max: 48,
                divisions: 12,
                onChanged: (v) => setDialogState(() => radius = v),
              ),
              Text(AppStrings.blurAlphaValue(alpha.round())),
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
              child: Text(AppStrings.cancel),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(AppStrings.confirm),
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
      title: AppStrings.topBarBlur,
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
      title: AppStrings.floatingBottomBarBlur,
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
    // [应用字体入口 2026-11-11] 应用界面字体状态（与阅读正文字体分离）
    final appFont = ref.watch(appFontProvider);
    // [设置批2a-1] 护眼模式：与全局叠加层共用同一 Notifier（写入即全局生效）
    final eyeProtection = ref.watch(eyeProtectionProvider);
    final eyeProtectionNotifier = ref.read(eyeProtectionProvider.notifier);
    // [设置批2b-1b-2a P2-3] 大容器图片透明度行只在「总开关开 + 当前亮暗
    // 图片可用」时显示（参考版该滑杆在图片管理面板内、随图片出现）。
    final containerBgForCurrentBrightness =
        Theme.of(context).brightness == Brightness.dark
        ? ui.largeContainerBackgroundImageDark
        : ui.largeContainerBackgroundImageLight;
    final showAppColumnBackgroundOpacity =
        ui.enableContainerBackgroundImage &&
        ThemeBackgroundImageStore.isUsableSync(containerBgForCurrentBrightness);
    // [设置批2b-1b-2b] 项目背景图透明度行：与 Large 图同口径，仅总开关开
    // 且**任一日/夜**项目图可用时显示（[P3] 不在切换亮暗时隐藏，便于统一
    // 调整；参考版滑杆在图片管理面板内、随图片出现）。
    final hasUsableItemBgLight = ThemeBackgroundImageStore.isUsableSync(
      ui.itemBackgroundImageLight,
    );
    final hasUsableItemBgDark = ThemeBackgroundImageStore.isUsableSync(
      ui.itemBackgroundImageDark,
    );
    final showGlassCardBackgroundOpacity =
        ui.enableContainerBackgroundImage &&
        (hasUsableItemBgLight || hasUsableItemBgDark);

    // [GLOBALCOMP B4] 页壳统一：AppScaffold（行为等价直通 Scaffold）
    return AppScaffold(
      // [队列⑦c A3] 页标题对齐参考 R.string.theme_setting=外观
      topBar: LegadoAppBar(title: Text(AppStrings.appearanceEntry)),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : IosGroupedBody(
              child: ListView(
                padding: const EdgeInsets.only(bottom: 32),
                children: [
                  // === [R50 | 2026-11-28 用户裁决] 恢复外观预览（参考版 3.26.19
                  // 标题「外观」正下方的手机示意图：128×256dp、纯展示、无文案）。
                  // 2.0.269 曾按「外观预览」文案 grep 参考版二进制资源零命中而误删；
                  // 实机重采证实该控件 text/content-desc 本为空（按文案搜必然零命中），
                  // 证据见 docs/R50_APPEARANCE_PREVIEW_VERIFY_20261128.md ===
                  const _ThemePreviewCard(),
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
                  IosSectionHeader(AppStrings.themeMode),
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
                    ],
                  ),
                  // === 分组 2「主题引擎」（我方 MD3 参数化：paletteStyle +
                  // 对比度；参考版无对应分组——参考"主题风格"=compose 引擎
                  // 开关，属参考独有，仅登记不实现）。[队列⑦c A3] AMOLED 纯黑
                  // 移出本组，改入通用组首位（对齐参考 纯黑深色模式 首位） ===
                  IosSectionHeader(AppStrings.themeEngine),
                  IosGroup(
                    children: [
                      IosListTile(
                        title: AppStrings.colorStyle,
                        subtitle: _styleLabel(ui.themeStyle),
                        onTap: _showThemeStylePicker,
                      ),
                      if (ui.themeStyle != 'none')
                        IosListTile(
                          title: AppStrings.contrast,
                          subtitle: _contrastLabel(ui.themeContrastLevel),
                          onTap: _showContrastPicker,
                        ),
                    ],
                  ),

                  // === 分组 3 通用（无分组标题，对齐参考版未分组通用组；
                  // 参考顺序 纯黑→切换图标→字体大小→主题管理→字体设置→
                  // 背景图片；字体设置已实现（2026-11-11，独立应用字体，
                  // 不影响阅读正文）；参考独有 自定义颜色/compose 引擎/
                  // 预见性返回手势仍仅登记不实现） ===
                  // [队列⑦c A3] 通用组排序：纯黑深色模式（自主题引擎移入，
                  // 对齐参考 纯黑 首位）→ 切换图标 → 字体大小 → 主题管理
                  // （原主题列表改名）→ 导出/导入主题（原顶部分区并入）→ 其余
                  // 我方项保持原有相对顺序
                  IosGroup(
                    children: [
                      // 纯黑深色模式（参考 pure_black=纯黑深色模式；原"AMOLED
                      // 纯黑"，标题对齐参考，副标题保留）
                      SettingSwitchRow(
                        title: AppStrings.trueBlackMode,
                        subtitle: AppStrings.trueBlackModeDesc,
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
                          title: AppStrings.changeIcon,
                          subtitle: AppStrings.changeIconDesc,
                          value:
                              _launcherIconLabels[_launcherIcons
                                  .indexOf(_launcherIcon)
                                  .clamp(0, 6)],
                          onTap: _showLauncherIconPicker,
                        ),
                      // 字体大小（参考 font_scale=字体大小；摘要半角冒号对齐
                      // font_scale_summary「当前字体大小: %.1f」，见 theme_state）
                      IosListTile(
                        title: AppStrings.fontSize,
                        subtitle: themeState.fontScaleLabel,
                        onTap: () => _showFontScalePicker(
                          context,
                          themeState,
                          themeNotifier,
                        ),
                      ),
                      // 主题管理（参考 theme_pack=主题管理；原"主题列表"改名，
                      // 副标题保留；参考完整主题包管理屏属参考独有，仅登记）
                      IosListTile(
                        title: AppStrings.themeManagement,
                        subtitle: AppStrings.themeManagementDesc,
                        onTap: _showThemeListDialog,
                      ),
                      // 字体设置（参考版外观页「字体设置」，位于主题管理之后、
                      // 背景图片之前；日/夜共用，仅影响 App 界面文字。参考版
                      // 与阅读正文字体分离——正文仍由阅读设置/字体页管理）
                      IosListTile(
                        title: AppStrings.fontSettings,
                        subtitle: _appFontSubtitle(appFont),
                        onTap: _showAppFontDialog,
                      ),
                      // 导出/导入主题（[B3-C1 A3] 复用 ThemeColorsNotifier +
                      // ThemeNotifier，全部经主题槽位，无硬编码色值）
                      IosListTile(
                        icon: Symbols.ios_share_rounded,
                        title: AppStrings.exportTheme,
                        subtitle: AppStrings.exportThemeDesc,
                        onTap: _exportTheme,
                      ),
                      IosListTile(
                        icon: Symbols.download_rounded,
                        title: AppStrings.importTheme,
                        subtitle: AppStrings.importThemeDesc,
                        onTap: _importTheme,
                      ),
                      IosListTile(
                        title: AppStrings.launchStyle,
                        subtitle: AppStrings.launchStyleDesc,
                        onTap: () {
                          Navigator.of(
                            context,
                          ).pushNamed(AppRoutes.welcomeConfig);
                        },
                      ),
                      SettingSwitchRow(
                        title: AppStrings.immersiveStatusBar,
                        subtitle: AppStrings.immersiveStatusBarDesc,
                        value: _transparentStatusBar,
                        onChanged: (v) async {
                          setState(() => _transparentStatusBar = v);
                          await ref
                              .read(systemBarProvider.notifier)
                              .setTransparentStatusBar(v);
                        },
                      ),
                      SettingSwitchRow(
                        title: AppStrings.immersiveNavBar,
                        subtitle: AppStrings.immersiveNavBarDesc,
                        value: _immNavigationBar,
                        onChanged: (v) async {
                          setState(() => _immNavigationBar = v);
                          await ref
                              .read(systemBarProvider.notifier)
                              .setImmNavigationBar(v);
                        },
                      ),
                      IosListTile(
                        title: AppStrings.navBarShadow,
                        subtitle: AppStrings.navBarShadowValue(_barElevation),
                        onTap: _showBarElevationDialog,
                      ),
                      IosListTile(
                        title: AppStrings.bottomBarAtlas,
                        subtitle: AppStrings.bottomBarAtlasDesc,
                        onTap: () => Navigator.pushNamed(
                          context,
                          AppRoutes.bottomBarSkin,
                        ),
                      ),
                      SettingSwitchRow(
                        title: AppStrings.wallpaperColors,
                        subtitle: AppStrings.wallpaperColorsDesc,
                        value: _wallpaperColorFollow,
                        onChanged: (v) {
                          setState(() => _wallpaperColorFollow = v);
                          _settings.setBoolPref(
                            PrefKeys.wallpaperColorFollow,
                            v,
                          );
                          // [UI_SYNC_REFACTOR R1] 同步 uiSettings（dynamic_color 接线读取）
                          ref
                              .read(uiSettingsProvider.notifier)
                              .setWallpaperColorFollow(v);
                        },
                      ),
                      if (_wallpaperColorFollow)
                        SettingSwitchRow(
                          title: AppStrings.wallpaperAutoUpdate,
                          subtitle: AppStrings.wallpaperAutoUpdateDesc,
                          value: _wallpaperColorAutoUpdate,
                          onChanged: (v) {
                            setState(() => _wallpaperColorAutoUpdate = v);
                            _settings.setBoolPref(
                              PrefKeys.wallpaperColorAutoUpdate,
                              v,
                            );
                          },
                        ),
                    ],
                  ),

                  // === 分组 4「主界面」（参考 R.string.main_activity=主界面；
                  // [队列⑦c A3] 合并原"顶栏与布局"+"底栏与导航"两组为参考的单
                  // 主界面组，设置经 uiSettings 即时全局生效；参考 首页与导航/
                  // 显示状态栏/启用滑动时动画 属参考独有，仅登记不实现） ===
                  IosSectionHeader(AppStrings.mainInterfaceSection),
                  IosGroup(
                    children: [
                      // [设置批2b-2a] 参考版「首页与导航」独立设置项
                      //（MainNavigationSettingsSheet）：显隐首页/发现/订阅、
                      // 排序、默认首页、底栏文字、导航图标。参考版将其放在
                      // 外观页「主界面」组首位，本项同位置对齐 — 全栈工程师
                      IosListTile(
                        icon: Symbols.explore_rounded,
                        title: AppStrings.homeAndNavigation,
                        subtitle: AppStrings.homeAndNavigationDesc,
                        onTap: () => MainNavigationSettingsSheet.show(context),
                      ),
                      IosListTile(
                        title: AppStrings.topBarButtonStyle,
                        subtitle: _topBarStyleLabel(ui.topBarButtonStyle),
                        onTap: _showTopBarStylePicker,
                      ),
                      SettingSwitchRow(
                        title: AppStrings.mergeTopBarButtons,
                        subtitle: AppStrings.topBarCapsuleDesc,
                        value: ui.mergeTopBarActions,
                        onChanged: (v) => ref
                            .read(uiSettingsProvider.notifier)
                            .setMergeTopBarActions(v),
                      ),
                      SettingSwitchRow(
                        title: AppStrings.largeTopBar,
                        subtitle: AppStrings.largeTopBarDesc,
                        value: ui.useFlexibleTopAppBar,
                        onChanged: (v) => ref
                            .read(uiSettingsProvider.notifier)
                            .setUseFlexibleTopAppBar(v),
                      ),
                      IosListTile(
                        title: AppStrings.topBarOpacity,
                        subtitle: AppStrings.currentPercent(ui.topBarOpacity),
                        onTap: _showTopBarOpacityDialog,
                      ),
                      SettingSwitchRow(
                        title: AppStrings.showBottomBar,
                        subtitle: AppStrings.showBottomBarDesc,
                        value: ui.showBottomView,
                        onChanged: (v) => ref
                            .read(uiSettingsProvider.notifier)
                            .setShowBottomView(v),
                      ),
                      SettingSwitchRow(
                        title: AppStrings.floatingBottomBarSection,
                        subtitle: AppStrings.floatingBottomBarSectionDesc,
                        value: ui.useFloatingBottomBar,
                        onChanged: (v) => ref
                            .read(uiSettingsProvider.notifier)
                            .setUseFloatingBottomBar(v),
                      ),
                      IosListTile(
                        title: AppStrings.bottomBarOpacity,
                        subtitle: AppStrings.currentPercent(ui.bottomBarOpacity),
                        onTap: _showBottomBarOpacityDialog,
                      ),
                      // 大屏导航形态（参考 main_activity 组 tabletInterface=平板界面；
                      // 四档 自动/始终/仅横屏/关闭）
                      IosListTile(
                        title: AppStrings.tabletNavMode,
                        subtitle: _tabletLabel(ui.tabletInterface),
                        onTap: _showTabletModePicker,
                      ),
                      // [设置批2b-2b] 多栏布局（参考版主界面组 multiPaneMode
                      // 紧随 tabletInterface：四档 auto/landscape/always/off）
                      IosListTile(
                        title: AppStrings.multiPaneLayout,
                        subtitle: _multiPaneLabel(ui.multiPaneMode),
                        onTap: _showMultiPanePicker,
                      ),
                    ],
                  ),

                  // === 分组 5「书籍详情页」（参考 R.string.book_info_page=
                  // 书籍详情页；原"详情与圆角"的封面三行；卡片圆角/分隔线移入
                  // 下方"容器设置"组） ===
                  IosSectionHeader(AppStrings.bookDetailPage),
                  IosGroup(
                    children: [
                      // 参考 book_info_follow_cover_color=界面颜色跟随封面取色，
                      // 摘要 book_info_follow_cover_color_s=仅在显示背景封面时生效
                      SettingSwitchRow(
                        title: AppStrings.uiColorFromCover,
                        subtitle: AppStrings.uiColorFromCoverDesc,
                        value: ui.bookInfoFollowCoverColor,
                        onChanged: (v) => ref
                            .read(uiSettingsProvider.notifier)
                            .setBookInfoFollowCoverColor(v),
                      ),
                      // 参考 book_info_network_cover_background=网络封面背景设置
                      IosListTile(
                        title: AppStrings.networkCoverBackground,
                        subtitle: _coverBgLabel(
                          ui.bookInfoNetworkCoverBackground,
                        ),
                        onTap: () => _showCoverBgPicker(false),
                      ),
                      // 参考 book_info_default_cover_background=默认封面背景设置
                      IosListTile(
                        title: AppStrings.defaultCoverBackground,
                        subtitle: _coverBgLabel(
                          ui.bookInfoDefaultCoverBackground,
                        ),
                        onTap: () => _showCoverBgPicker(true),
                      ),
                    ],
                  ),

                  // === 分组「护眼模式」（设置批2a-1；对齐参考版
                  // ThemeConfigScreen.kt:433-521 同名分组：启用护眼模式 →
                  // 深色模式时自动开启 → 已配置时展开「色温」滑杆 → 定时开启 →
                  // 起止时间。值经 ThemeSettings 六键持久化，全局叠加见
                  // EyeProtectionLayer） ===
                  IosSectionHeader(AppStrings.eyeProtection),
                  IosGroup(
                    children: [
                      SettingSwitchRow(
                        title: AppStrings.enableEyeProtection,
                        subtitle: AppStrings.enableEyeProtectionDesc,
                        value: eyeProtection.enabled,
                        onChanged: eyeProtectionNotifier.setEnabled,
                      ),
                      SettingSwitchRow(
                        title: AppStrings.eyeProtectionAutoDark,
                        subtitle: AppStrings.eyeProtectionAutoDarkDesc,
                        value: eyeProtection.autoNight,
                        onChanged: eyeProtectionNotifier.setAutoNight,
                      ),
                      // 参考版 AnimatedVisibility(theme.isEyeProtectionConfigured)：
                      // 未启用（总开关与自动夜间均关）时不显示强度/定时行
                      if (eyeProtection.isConfigured) ...[
                        EyeProtectionIntensityRow(
                          value: eyeProtection.intensity,
                          onChanged: eyeProtectionNotifier.setIntensity,
                        ),
                        SettingSwitchRow(
                          title: AppStrings.eyeProtectionScheduled,
                          subtitle: AppStrings.eyeProtectionScheduledDesc,
                          value: eyeProtection.schedule,
                          onChanged: eyeProtectionNotifier.setSchedule,
                        ),
                        if (eyeProtection.schedule) ...[
                          IosListTile(
                            title: AppStrings.startTime,
                            value: eyeProtection.startTime,
                            onTap: () => pickEyeProtectionTime(
                              context,
                              ref,
                              start: true,
                            ),
                          ),
                          IosListTile(
                            title: AppStrings.endTime,
                            value: eyeProtection.endTime,
                            onTap: () => pickEyeProtectionTime(
                              context,
                              ref,
                              start: false,
                            ),
                          ),
                        ],
                      ],
                    ],
                  ),

                  // === 分组 8「容器设置」（参考 R.string
                  // .theme_manage_section_container=容器设置）
                  //
                  // [设置批2b-1a] 补齐参考版容器背景（日/夜）+ 容器不透明度 +
                  // 背景图虚化（日/夜）：
                  // - 总开关 enableContainerBackgroundImage（默认 false，键名对
                  //   齐参考 PreferKey.kt:270）；关闭保留路径不渲染，选图自动置
                  //   true。图片行仅在开关开启时显示（参考 :534-544 条件显隐）。
                  // - 大容器背景图键 largeContainerBackgroundImageLight/Dark，
                  //   选择后复制到应用目录（内容哈希命名），IosGroup 分组卡面
                  //   按当前亮暗绘制；文件缺失回落纯主题底色。
                  // - 容器不透明度 containerOpacity 0..100（默认 100），乘调色板
                  //   alpha（参考 GlassCard.kt:74-75），作用于分组卡面与行小卡面；
                  //   [设置批2b-1b-2b] 起同时作用于全局 CardTheme 默认色
                  //   （含显式 shape 但未显式 color 的 Card；显式 color 不受
                  //   影响）、IosGroup 与设置首页手写卡片；书架/详情/对话框
                  //   等剩余 GlassCard 卡面登记 2b-1b-2c。
                  // - 大容器背景图自身不透明度 appColumnBackgroundOpacity
                  //   0..100（默认 100；参考 ThemeSettings.kt:61，
                  //   AppContainerBackground.kt:61 对 Large 图 alpha=value/100），
                  //   仅乘在 IosGroup 容器背景图上，与 containerOpacity 独立叠加。
                  // - 背景图虚化 backgroundImageBlurring/backgroundImageNightBlurring
                  //   0..100（默认 0），仅作用全局壁纸，不影响内容/文字。
                  // [设置批2b-1b-1] 补齐参考版容器卡面三项覆盖（当前开关即时
                  // 生效，重启保持；随 appPrefs 往返）：
                  // - 关闭设置分组圆角 disableSplicedColumnGroupCornerRadius：
                  //   分组外角 0，优先级高于卡片圆角覆盖（参考
                  //   SplicedColumnGroup.kt:50-53）。
                  // - 覆盖卡片圆角 overrideBaseCardCornerRadius +
                  //   baseCardCornerRadius 0..40；作用于 IosGroup 与全局
                  //   CardTheme（参考版 BaseCard/GlassCard 同源分支）。
                  //   形状覆盖范围：仅未显式 shape 的 Card；18 处显式 shape
                  //   的卡片（字典/首页/阅读器内面板等）形状不覆盖，登记
                  //   2b-1b-2c；其底色若未显式 color，仍随 CardTheme 乘 alpha。
                  // - 覆盖卡片边框 overrideBaseCardBorder + 宽度 0..5 + 日夜色
                  //   （0=outlineVariant）；IosGroup 用 foregroundDecoration
                  //   绘制，不改变布局/不裁剪内容。
                  // - 显示分隔线 enableItemDivider + 宽度 0..5 + 长度 30..100%
                  //   + 颜色（0=灰色 30%）；行之间插入胶囊线，行间距保持 2dp
                  //   （参考 SplicedColumnGroup + SettingItemDivider）。
                  // [设置批2b-1b-2b] 项目（卡片）背景图：
                  // - itemBackgroundImageLight/Dark（默认 null，槽位
                  //   item_light/item_dark）+ glassCardBackgroundOpacity
                  //   0..100（默认 100）；与 Large 图共用本组总开关
                  //   （参考 AppContainerBackground.kt:51-63）。
                  // - 渲染范围：IosGroup 行卡 + 设置首页手写卡片；图片层在卡面
                  //   色之上、内容之下，`.9.png` 按 centerSlice 拉伸。
                  //   `.9.png` 仅识别带 npTc 的编译产物（32B 序列化 header、
                  //   大端 divs）；源码形态（仅黑边/无 npTc）回落普通图
                  //   cover。100% 图片不遮挡行水波纹（内容层透明 Material）。
                  //   超过单边 8192 / 32MP 的 `.9` 回落 ResizeImage cover
                  //   （设备项：超大 `.9` 峰值内存）。
                  // - 登记（2b-1b-2c）：书架/详情/对话框等其余 GlassCard 卡面；
                  //   设置首页仍不渲染大容器图（appColumn 在该页无视觉作用）；
                  //   IosGroup(flat) 扁平模式无卡片面，不参与容器背景/不透明度/
                  //   圆角/边框/分隔线开关；虚化行常显。
                  IosSectionHeader(AppStrings.containerSection),
                  IosGroup(
                    children: [
                      // 参考 容器背景图 总开关（enableContainerBackgroundImage）
                      SettingSwitchRow(
                        title: AppStrings.containerBackground,
                        subtitle: AppStrings.containerBackgroundDesc,
                        value: ui.enableContainerBackgroundImage,
                        onChanged: (v) => ref
                            .read(uiSettingsProvider.notifier)
                            .setEnableContainerBackgroundImage(v),
                      ),
                      // 参考 AnimatedVisibility(enableContainerBackgroundImage)：
                      // 关闭时隐藏图片行但保留已选路径（再次开启即恢复）
                      if (ui.enableContainerBackgroundImage) ...[
                        IosListTile(
                          icon: Symbols.wallpaper_rounded,
                          title: AppStrings.containerBackgroundDay,
                          subtitle: _containerBgLabel(
                            ui.largeContainerBackgroundImageLight,
                          ),
                          onTap: () =>
                              _showContainerBgImageDialog(night: false),
                        ),
                        IosListTile(
                          icon: Symbols.wallpaper_rounded,
                          title: AppStrings.containerBackgroundNight,
                          subtitle: _containerBgLabel(
                            ui.largeContainerBackgroundImageDark,
                          ),
                          onTap: () => _showContainerBgImageDialog(night: true),
                        ),
                        // [设置批2b-1b-2b] 项目（卡片）背景图日/夜行：槽位
                        // item_light/item_dark，渲染于设置页行卡与设置首页卡片。
                        IosListTile(
                          icon: Symbols.wallpaper_rounded,
                          title: AppStrings.itemBackgroundDay,
                          subtitle: _containerBgLabel(
                            ui.itemBackgroundImageLight,
                          ),
                          onTap: () => _showItemBgImageDialog(night: false),
                        ),
                        IosListTile(
                          icon: Symbols.wallpaper_rounded,
                          title: AppStrings.itemBackgroundNight,
                          subtitle: _containerBgLabel(
                            ui.itemBackgroundImageDark,
                          ),
                          onTap: () => _showItemBgImageDialog(night: true),
                        ),
                      ],
                      // 参考 appColumnBackgroundOpacity：大容器背景图自身透明度
                      // 0..100，默认 100；仅乘图片 alpha，与行卡 scrim 独立叠加。
                      // [P2-3] 参考版该滑杆位于图片管理面板内，仅图片存在时可见。
                      if (showAppColumnBackgroundOpacity)
                        SettingSliderRow(
                          title: AppStrings.containerImageOpacity,
                          subtitle: AppStrings.containerImageOpacityHint,
                          value: ui.appColumnBackgroundOpacity,
                          min: 0,
                          max: 100,
                          onChanged: (v) => ref
                              .read(uiSettingsProvider.notifier)
                              .setAppColumnBackgroundOpacity(v),
                        ),
                      // [设置批2b-1b-2b] 参考 glassCardBackgroundOpacity：项目图
                      // 自身透明度 0..100，默认 100；仅乘项目图 alpha，与
                      // containerOpacity/大容器图透明度三者独立叠加。
                      if (showGlassCardBackgroundOpacity)
                        SettingSliderRow(
                          title: AppStrings.itemImageOpacity,
                          subtitle: AppStrings.itemImageOpacityHint,
                          value: ui.glassCardBackgroundOpacity,
                          min: 0,
                          max: 100,
                          onChanged: (v) => ref
                              .read(uiSettingsProvider.notifier)
                              .setGlassCardBackgroundOpacity(v),
                        ),
                      // 参考 container_opacity 滑杆：0..100，默认 100
                      SettingSliderRow(
                        title: AppStrings.containerOpacity,
                        subtitle: AppStrings.containerOpacityHint,
                        value: ui.containerOpacity,
                        min: 0,
                        max: 100,
                        onChanged: (v) => ref
                            .read(uiSettingsProvider.notifier)
                            .setContainerOpacity(v),
                      ),
                      // 参考版虚化在「背景图片」面板内（日/夜各一条 0..100）；
                      // 我方按用户指令并入「容器设置」分组，仅影响全局壁纸。
                      // 登记：虚化行常显（无背景图时调值不产生视觉变化）。
                      SettingSliderRow(
                        title: AppStrings.backgroundBlurDay,
                        subtitle: AppStrings.backgroundBlurDesc,
                        value: ui.bgImageBlurring,
                        min: 0,
                        max: 100,
                        onChanged: (v) => ref
                            .read(uiSettingsProvider.notifier)
                            .setBgImageBlurring(night: false, value: v),
                      ),
                      SettingSliderRow(
                        title: AppStrings.backgroundBlurNight,
                        subtitle: AppStrings.backgroundBlurDesc,
                        value: ui.bgImageDarkBlurring,
                        min: 0,
                        max: 100,
                        onChanged: (v) => ref
                            .read(uiSettingsProvider.notifier)
                            .setBgImageBlurring(night: true, value: v),
                      ),
                      // 参考 disable_spliced_group_corner_radius：分组外角 0，
                      // 优先级高于下方圆角覆盖（参考 SplicedColumnGroup.kt:50-53）
                      SettingSwitchRow(
                        title: AppStrings.disableGroupRadius,
                        subtitle: AppStrings.disableGroupRadiusDesc,
                        value: ui.disableSplicedColumnGroupCornerRadius,
                        onChanged: (v) => ref
                            .read(uiSettingsProvider.notifier)
                            .setDisableSplicedColumnGroupCornerRadius(v),
                      ),
                      // 参考 覆盖卡片圆角 开关 + 卡片圆角滑杆（0..40dp）
                      SettingSwitchRow(
                        title: AppStrings.overrideCardRadius,
                        subtitle: AppStrings.overrideCardRadiusDesc,
                        value: ui.overrideBaseCardCornerRadius,
                        onChanged: (v) => ref
                            .read(uiSettingsProvider.notifier)
                            .setOverrideBaseCardCornerRadius(v),
                      ),
                      if (ui.overrideBaseCardCornerRadius)
                        SettingSliderRow(
                          title: AppStrings.cardRadius,
                          subtitle: AppStrings.cardRadiusDesc,
                          value: ui.baseCardCornerRadius,
                          min: 0,
                          max: 40,
                          valueSuffix: 'dp',
                          onChanged: (v) => ref
                              .read(uiSettingsProvider.notifier)
                              .setBaseCardCornerRadius(v),
                        ),
                      // 参考 覆盖卡片边框 开关 + 宽度 + 日/夜颜色
                      SettingSwitchRow(
                        title: AppStrings.overrideCardBorder,
                        subtitle: AppStrings.overrideCardBorderDesc,
                        value: ui.overrideBaseCardBorder,
                        onChanged: (v) => ref
                            .read(uiSettingsProvider.notifier)
                            .setOverrideBaseCardBorder(v),
                      ),
                      if (ui.overrideBaseCardBorder) ...[
                        SettingSliderRow(
                          title: AppStrings.borderWidth,
                          subtitle: AppStrings.cardBorderWidthDesc,
                          value: ui.baseCardBorderWidth,
                          min: 0,
                          max: 5,
                          valueSuffix: 'dp',
                          onChanged: (v) => ref
                              .read(uiSettingsProvider.notifier)
                              .setBaseCardBorderWidth(v),
                        ),
                        _containerColorTile(
                          title: AppStrings.dayBorderColor,
                          color: ui.baseCardBorderColor,
                          defaultHint: AppStrings.defaultFollowThemeBorder,
                          showDotWhenZero: true,
                          onTap: () => _showContainerColorPicker(
                            title: AppStrings.dayBorderColor,
                            initialColor: ui.baseCardBorderColor,
                            defaultHint: AppStrings.restoreDefault,
                            onSelected: (v) => ref
                                .read(uiSettingsProvider.notifier)
                                .setBaseCardBorderColor(v),
                          ),
                        ),
                        _containerColorTile(
                          title: AppStrings.nightBorderColor,
                          color: ui.baseCardBorderColorNight,
                          defaultHint: AppStrings.defaultFollowThemeBorder,
                          showDotWhenZero: true,
                          onTap: () => _showContainerColorPicker(
                            title: AppStrings.nightBorderColor,
                            initialColor: ui.baseCardBorderColorNight,
                            defaultHint: AppStrings.restoreDefault,
                            onSelected: (v) => ref
                                .read(uiSettingsProvider.notifier)
                                .setBaseCardBorderColorNight(v),
                          ),
                        ),
                      ],
                      // 参考 show_divider_line：行之间显示分隔线
                      SettingSwitchRow(
                        title: AppStrings.showDivider,
                        subtitle: AppStrings.showDividerDesc,
                        value: ui.enableItemDivider,
                        onChanged: (v) => ref
                            .read(uiSettingsProvider.notifier)
                            .setEnableItemDivider(v),
                      ),
                      if (ui.enableItemDivider) ...[
                        SettingSliderRow(
                          title: AppStrings.dividerWidth,
                          subtitle: AppStrings.dividerWidthDesc,
                          value: ui.itemDividerWidth,
                          min: 0,
                          max: 5,
                          valueSuffix: 'dp',
                          onChanged: (v) => ref
                              .read(uiSettingsProvider.notifier)
                              .setItemDividerWidth(v),
                        ),
                        SettingSliderRow(
                          title: AppStrings.dividerLength,
                          subtitle: AppStrings.dividerLengthDesc,
                          value: ui.itemDividerLength,
                          min: 30,
                          max: 100,
                          valueSuffix: '%',
                          onChanged: (v) => ref
                              .read(uiSettingsProvider.notifier)
                              .setItemDividerLength(v),
                        ),
                        _containerColorTile(
                          title: AppStrings.dividerColor,
                          color: ui.itemDividerColor,
                          defaultHint: AppStrings.dividerColorDefault,
                          showDotWhenZero: false,
                          showChevron: ui.itemDividerColor != 0,
                          onTap: () => _showContainerColorPicker(
                            title: AppStrings.dividerColor,
                            initialColor: ui.itemDividerColor,
                            defaultHint: AppStrings.restoreDefault,
                            onSelected: (v) => ref
                                .read(uiSettingsProvider.notifier)
                                .setItemDividerColor(v),
                          ),
                        ),
                      ],
                    ],
                  ),

                  // === 分组 7「模糊效果」（参考 R.string.blur_effects=模糊效果；
                  // [队列⑦c A3] 原"毛玻璃"改组名对齐参考；我方 启用毛玻璃 +
                  // 顶栏/悬浮底栏模糊参数，参考 启用控件模糊/启用渐变模糊 开关
                  // 结构属参考独有，仅登记；默认关——低端机掉帧保护） ===
                  IosSectionHeader(AppStrings.blurEffectsSection),
                  // [B3-C1 A6] 每区独立圆角卡（IosGroup 卡片模式）
                  IosGroup(
                    children: [
                      SettingSwitchRow(
                        title: AppStrings.enableBlur,
                        subtitle: AppStrings.enableBlurDesc,
                        value: ui.enableBlur,
                        onChanged: (v) => ref
                            .read(uiSettingsProvider.notifier)
                            .setEnableBlur(v),
                      ),
                      IosListTile(
                        title: AppStrings.topBarBlur,
                        subtitle: ui.enableBlur
                            ? AppStrings.blurDetailValue(ui.topBarBlurRadius, ui.topBarBlurAlpha)
                            : AppStrings.enableBlurFirst,
                        onTap: ui.enableBlur ? _showTopBarBlurDialog : null,
                      ),
                      IosListTile(
                        title: AppStrings.floatingBottomBarBlur,
                        subtitle: ui.enableBlur
                            ? AppStrings.blurDetailValue(
                              ui.bottomBarBlurRadius,
                              ui.bottomBarBlurAlpha,
                            )
                            : AppStrings.enableBlurFirst,
                        onTap: ui.enableBlur ? _showBottomBarBlurDialog : null,
                      ),
                    ],
                  ),

                  // === 自定义主题·白天（对齐原版 day category，themeConfigList
                  // 功能完整保留——UI_MD3_PLAN.md 第九节） ===
                  IosSectionHeader(AppStrings.customThemeDay),
                  // [B3-C1 A6] 每区独立圆角卡（IosGroup 卡片模式）
                  IosGroup(
                    children: [
                      _colorTile(PrefKeys.cPrimary, AppStrings.primaryColor, colors),
                      _colorTile(PrefKeys.cAccent, AppStrings.accentColor, colors),
                      // [批13] 字体色两行：顺序对齐参考 CustomThemeScreen
                      // CustomColorSettings（主题色→次要主题色→主要字体色→
                      // 次要字体色→背景色→标签容器色）。第 6 槽我方是底部
                      // 操作栏色、参考是标签容器色，构成不同见状态类注释。
                      _colorTile(
                        PrefKeys.cPrimaryText,
                        AppStrings.primaryTextColor,
                        colors,
                        subtitle: _fontColorHint,
                      ),
                      _colorTile(
                        PrefKeys.cSecondaryText,
                        AppStrings.secondaryTextColor,
                        colors,
                        subtitle: _fontColorHint,
                      ),
                      _colorTile(
                        PrefKeys.cBackground,
                        AppStrings.bgColor,
                        colors,
                        isBackground: true,
                      ),
                      _colorTile(PrefKeys.cBBackground, AppStrings.navBarColor, colors),
                      IosListTile(
                        icon: Symbols.wallpaper_rounded,
                        title: AppStrings.backgroundImages,
                        subtitle: _bgImage.isEmpty ? AppStrings.notSetLabel : _bgImage,
                        onTap: () => _showBgImageDialog(PrefKeys.bgImage),
                      ),
                      SettingSwitchRow(
                        title: AppStrings.transparentNavBar,
                        subtitle: _androidOnly,
                        value: _transparentNavBar,
                        onChanged: (v) {
                          setState(() => _transparentNavBar = v);
                          _settings.setBoolPref(PrefKeys.transparentNavBar, v);
                        },
                      ),
                      IosListTile(
                        icon: Symbols.save_rounded,
                        title: AppStrings.saveDayTheme,
                        subtitle: AppStrings.saveDayThemeDesc,
                        onTap: () => _saveTheme(isNight: false),
                      ),
                    ],
                  ),

                  // === 自定义主题·夜间（对齐原版 night category）===
                  IosSectionHeader(AppStrings.customThemeNight),
                  // [B3-C1 A6] 每区独立圆角卡（IosGroup 卡片模式）
                  IosGroup(
                    children: [
                      _colorTile(
                        PrefKeys.cNPrimary,
                        AppStrings.primaryColor,
                        colors,
                        isNight: true,
                      ),
                      _colorTile(
                        PrefKeys.cNAccent,
                        AppStrings.accentColor,
                        colors,
                        isNight: true,
                      ),
                      // [批13] 夜间字体色为 0 时逐字段继承日间（不改写偏好值，
                      // 由 ThemeColorsState 解析），行内仍显示「默认」以便用户
                      // 显式选择夜间独立值
                      _colorTile(
                        PrefKeys.cNPrimaryText,
                        AppStrings.primaryTextColor,
                        colors,
                        isNight: true,
                        subtitle: _fontColorHint,
                      ),
                      _colorTile(
                        PrefKeys.cNSecondaryText,
                        AppStrings.secondaryTextColor,
                        colors,
                        isNight: true,
                        subtitle: _fontColorHint,
                      ),
                      _colorTile(
                        PrefKeys.cNBackground,
                        AppStrings.bgColor,
                        colors,
                        isNight: true,
                        isBackground: true,
                      ),
                      _colorTile(
                        PrefKeys.cNBBackground,
                        AppStrings.navBarColor,
                        colors,
                        isNight: true,
                      ),
                      IosListTile(
                        icon: Symbols.wallpaper_rounded,
                        title: AppStrings.backgroundImages,
                        subtitle: _bgImageNight.isEmpty ? AppStrings.notSetLabel : _bgImageNight,
                        onTap: () => _showBgImageDialog(PrefKeys.bgImageN),
                      ),
                      SettingSwitchRow(
                        title: AppStrings.transparentNavBar,
                        subtitle: _androidOnly,
                        value: _transparentNavBarNight,
                        onChanged: (v) {
                          setState(() => _transparentNavBarNight = v);
                          _settings.setBoolPref(
                            PrefKeys.transparentNavBarNight,
                            v,
                          );
                        },
                      ),
                      IosListTile(
                        icon: Symbols.save_rounded,
                        title: AppStrings.saveNightTheme,
                        subtitle: AppStrings.saveNightThemeDesc,
                        onTap: () => _saveTheme(isNight: true),
                      ),
                    ],
                  ),
                  IosSectionFooter(AppStrings.bgImageWallpaperFooter),
                ],
              ),
            ),
    );
  }

  /// 颜色配置行（值为空时显示"默认"，否则显示色块）
  ///
  /// [批13] 0 与 null 都按「未设置」展示：字体色槽位以 0 表示未设置
  /// （参考版重置写透明 #00000000），旧备份/参考版备份里的 0 值不应被
  /// 画成透明色块。每行带 `theme-color-<key>` ValueKey 便于测试定位。
  Widget _colorTile(
    String key,
    String title,
    ThemeColorsState colors, {
    bool isNight = false,
    bool isBackground = false,
    String? subtitle,
  }) {
    final value = colors.valueOf(key);
    final isUnset = value == null || value == 0;
    return IosListTile(
      key: ValueKey('theme-color-$key'),
      icon: Symbols.palette_rounded,
      title: title,
      subtitle: subtitle,
      value: isUnset ? AppStrings.defaultLabel : null,
      trailing: isUnset
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

  /// 容器设置颜色行（卡片边框/分隔线）：0 = 默认语义，显示回落色/说明
  ///
  /// [设置批2b-1b-1] 参考版 `BaseCardBorderColorSettingItem` / 分隔线颜色行
  /// 形态：标题 + 副标题（十六进制或"默认"）+ 右侧色点；0 色时边框行仍
  /// 显示 outlineVariant 色点，分隔线行不显示色点（参考版同口径）。
  /// [设置批2b-1b-1-b] 分隔线颜色 0 时隐藏 Chevron（无下一级可选值语义）。
  Widget _containerColorTile({
    required String title,
    required int color,
    required String defaultHint,
    required VoidCallback onTap,
    required bool showDotWhenZero,
    bool showChevron = true,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return IosListTile(
      title: title,
      subtitle: color == 0 ? defaultHint : argbToHex(color),
      trailing: (color != 0 || showDotWhenZero)
          ? Container(
              width: 22,
              height: 22,
              decoration: BoxDecoration(
                color: color != 0 ? Color(color) : scheme.outlineVariant,
                shape: BoxShape.circle,
                border: Border.all(color: scheme.outlineVariant),
              ),
            )
          : null,
      showChevron: showChevron,
      onTap: onTap,
    );
  }

  /// 卡片边框/分隔线颜色选择（预设色板 + HEX 输入 + 恢复默认=0）
  ///
  /// 与 [_showColorPicker] 同源色板，但结果写回 UiSettings（而非
  /// ThemeColorsNotifier），0 表示跟随主题/默认色。HEX 支持
  /// `#RRGGBB`/`#AARRGGBB`（# 可省略），非法输入禁用确定并提示。
  Future<void> _showContainerColorPicker({
    required String title,
    required int initialColor,
    required String defaultHint,
    required Future<void> Function(int value) onSelected,
  }) async {
    final selected = await showDialog<int>(
      context: context,
      builder: (ctx) => ContainerColorDialog(
        title: title,
        initialColor: initialColor,
        defaultHint: defaultHint,
        presetColors: kContainerColorPresets,
      ),
    );
    if (selected == null || !mounted) return;
    await onSelected(selected);
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
              for (final c in kContainerColorPresets)
                InkWell(
                  // [批13] 稳定 Key 供 widget 测试点选真实色值
                  key: ValueKey('theme-color-preset-$c'),
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
              ref.read(themeColorsProvider.notifier).setColor(key, null);
              Navigator.pop(ctx);
            },
            child: Text(AppStrings.restoreDefault),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(AppStrings.cancel),
          ),
        ],
      ),
    );
    // [UI-fix v2.0.5 | 2026-08-08] 异步对话框返回后统一补 mounted 防护，
    // 避免页面已销毁时继续使用 ref/setState — Qoder
    if (selected == null || !mounted) return;
    // 对齐原版 onColorSelected 背景明暗校验（白天背景过暗/夜间背景过亮拒绝）
    if (isBackground) {
      final isLight =
          ThemeData.estimateBrightnessForColor(Color(selected)) ==
          Brightness.light;
      if (!isNight && !isLight) {
        _toast(AppStrings.dayBgTooDark);
        return;
      }
      if (isNight && isLight) {
        _toast(AppStrings.nightBgTooBright);
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
        title: Text(AppStrings.launcherIcon),
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
        _toast(AppStrings.launcherIconChanged);
      }
    } else {
      // 展示原生侧真实错误（如 iOS"本次启动已切换过一次"、Android API<26），
      // 不再笼统提示"当前平台或系统版本不支持"
      _toast(result.message ?? AppStrings.launcherIconUnsupported);
    }
  }

  // ===== 主题列表（对齐原版 ThemeConfig.configList 本地版）=====

  static const _themeListKey = 'themeConfigList';

  /// 读取已保存主题配置列表（解析失败按空列表处理，兼容旧调用方）
  Future<List<Map<String, dynamic>>> _loadThemeList() async =>
      await _tryLoadThemeList() ?? [];

  /// 读取已保存主题配置列表；读取/解析失败返回 null
  ///
  /// [批14 回修 P2-6] 孤儿清理依赖该列表中的背景图引用；返回 null 表示
  /// 「引用未知」，调用方必须跳过本轮清理，不能按空列表处理。
  Future<List<Map<String, dynamic>>?> _tryLoadThemeList() async {
    final raw = await _settings.getStringPref(_themeListKey);
    if (raw.isEmpty) return [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return null;
      return [for (final item in decoded) item as Map<String, dynamic>];
    } catch (e) {
      debugPrint('ThemeConfigScreen._tryLoadThemeList 解析异常: $e');
      return null;
    }
  }

  /// 主题管理对话框（[队列⑦c A3] 原"主题列表"改名对齐参考 theme_pack=主题管理）：
  /// 点击应用，行内支持重命名/删除
  Future<void> _showThemeListDialog() async {
    var list = await _loadThemeList();
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          // [队列⑦c A3] 对话框标题与入口行一致（主题管理）
          title: Text(AppStrings.themeManagement),
          // [批14] 列表行增加导出按钮后，用更小的水平留白换取标题宽度
          //（360dp 下 8 个中文字符仍可完整显示）。
          insetPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 24,
          ),
          // [设备验收 8b] 收紧内容内边距，把宽度留给标题
          contentPadding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
          content: SizedBox(
            width: 320,
            child: list.isEmpty
                ? Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(AppStrings.noSavedThemes),
                  )
                : ListView.builder(
                    shrinkWrap: true,
                    itemCount: list.length,
                    itemBuilder: (ctx2, index) {
                      final item = list[index];
                      final isNight = item['isNight'] == true;
                      // [设备验收 8b] 不用 ListTile 默认 leading/trailing 宽度：
                      // 默认 48dp 按钮会把 320dp 标题挤成「测…」。自定义 Row
                      // 给标题 Expanded，按钮可点区 40dp（批14 增加导出按钮后
                      // 由 36dp 调整为 40dp，视觉仍紧凑），标题允许换行不截断。
                      final titleStyle = Theme.of(context).textTheme.bodyLarge;
                      final subtitleStyle = Theme.of(context)
                          .textTheme
                          .bodyMedium
                          ?.copyWith(
                            color: Theme.of(
                              context,
                            ).colorScheme.onSurfaceVariant,
                          );
                      return InkWell(
                        key: ValueKey('theme-config-item-$index'),
                        onTap: () async {
                          await _applyThemeConfig(item);
                          if (ctx.mounted) Navigator.pop(ctx);
                        },
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 4,
                            vertical: 6,
                          ),
                          child: Row(
                            children: [
                              Icon(
                                isNight
                                    ? Symbols.dark_mode_rounded
                                    : Symbols.light_mode_rounded,
                                color: Theme.of(
                                  context,
                                ).colorScheme.onSurfaceVariant,
                              ),
                              const SizedBox(width: 4),
                              Expanded(
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      '${item['name'] ?? AppStrings.unnamedTheme}',
                                      // [批14 回修] 窄屏 + 大字体允许两行，
                                      // 避免新增导出按钮后标题被省略号截断。
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: titleStyle,
                                    ),
                                    const SizedBox(height: 2),
                                    Text(
                                      isNight ? AppStrings.nightTheme : AppStrings.dayTheme,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: subtitleStyle,
                                    ),
                                  ],
                                ),
                              ),
                              IconButton(
                                key: ValueKey('theme-config-export-$index'),
                                icon: const Icon(
                                  Symbols.ios_share_rounded,
                                  size: 18,
                                ),
                                tooltip: AppStrings.exportThemePackage,
                                visualDensity: VisualDensity.compact,
                                padding: EdgeInsets.zero,
                                constraints: const BoxConstraints.tightFor(
                                  width: 40,
                                  height: 40,
                                ),
                                onPressed: () => _exportSavedTheme(item),
                              ),
                              IconButton(
                                key: ValueKey('theme-config-rename-$index'),
                                icon: const Icon(
                                  Symbols.edit_rounded,
                                  size: 18,
                                ),
                                tooltip: AppStrings.rename,
                                visualDensity: VisualDensity.compact,
                                padding: EdgeInsets.zero,
                                constraints: const BoxConstraints.tightFor(
                                  width: 40,
                                  height: 40,
                                ),
                                onPressed: () => _renameThemeConfig(
                                  list,
                                  index,
                                  setDialogState,
                                ),
                              ),
                              IconButton(
                                key: ValueKey('theme-config-delete-$index'),
                                icon: const Icon(
                                  Symbols.delete_rounded,
                                  size: 18,
                                ),
                                tooltip: AppStrings.delete,
                                visualDensity: VisualDensity.compact,
                                padding: EdgeInsets.zero,
                                constraints: const BoxConstraints.tightFor(
                                  width: 40,
                                  height: 40,
                                ),
                                onPressed: () async {
                                  list = List.of(list)..removeAt(index);
                                  await _settings.setStringPref(
                                    _themeListKey,
                                    jsonEncode(list),
                                  );
                                  setDialogState(() {});
                                },
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
          ),
          actions: [
            TextButton(
              key: const ValueKey('theme-package-import'),
              onPressed: () => _importThemePackage(list, setDialogState),
              child: Text(AppStrings.importThemePackage),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(AppStrings.modeOff),
            ),
          ],
        ),
      ),
    );
  }

  /// 重命名主题管理列表项：trim 后为空/取消不改；持久化并刷新对话框
  Future<void> _renameThemeConfig(
    List<Map<String, dynamic>> list,
    int index,
    StateSetter setDialogState,
  ) async {
    final current = '${list[index]['name'] ?? AppStrings.unnamedTheme}';
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => _ThemeConfigRenameDialog(initialValue: current),
    );
    if (!mounted) return;
    final trimmed = name?.trim() ?? '';
    if (trimmed.isEmpty) return;
    list[index] = Map<String, dynamic>.of(list[index])..['name'] = trimmed;
    await _settings.setStringPref(_themeListKey, jsonEncode(list));
    if (!mounted) return;
    setDialogState(() {});
  }

  /// 应用一份已保存的主题配置
  ///
  /// - 主题包条目带完整 `colors`（12 槽）时应用全部槽位；旧版条目只有
  ///   当前日/夜半组字段，按原有半组逻辑应用。
  /// - 带 `paletteId` 且落在内置调色板范围内时切换调色板；无效/缺失保持
  ///   当前调色板。
  /// - 背景图：条目显式含 `bgImage`/`bgImageNight` 时按值应用，空串表示
  ///   「明确无背景」并清除旧壁纸；旧版条目无字段则保持当前壁纸不动。
  ///
  /// [批13] 旧版 `themeConfigList` 条目没有 `primaryText`/`secondaryText`
  /// 字段：按未设置（0 → 清除）处理，不抛异常。类型容错统一走
  /// [ThemeConfigJson.asInt]（与导入 JSON 同一实现，旧 JSON 缺字段/数值被
  /// 序列化为 double 均安全）。
  Future<void> _applyThemeConfig(Map<String, dynamic> config) async {
    final colorsNotifier = ref.read(themeColorsProvider.notifier);
    final storedColors = config['colors'];
    if (storedColors is Map) {
      // [批14 回修] 主题包携带完整 12 槽，不能只应用 isNight 半组
      await colorsNotifier.applyColors({
        for (final key in _themeColorKeys)
          key: ThemeConfigJson.asInt(storedColors[key]),
      });
    } else {
      final isNight = config['isNight'] == true;
      await colorsNotifier.applyColors({
        if (isNight) ...{
          PrefKeys.cNPrimary: ThemeConfigJson.asInt(config['primary']),
          PrefKeys.cNAccent: ThemeConfigJson.asInt(config['accent']),
          PrefKeys.cNBackground: ThemeConfigJson.asInt(config['background']),
          PrefKeys.cNBBackground: ThemeConfigJson.asInt(
            config['bottomBackground'],
          ),
          PrefKeys.cNPrimaryText: ThemeConfigJson.asInt(config['primaryText']),
          PrefKeys.cNSecondaryText: ThemeConfigJson.asInt(
            config['secondaryText'],
          ),
        } else ...{
          PrefKeys.cPrimary: ThemeConfigJson.asInt(config['primary']),
          PrefKeys.cAccent: ThemeConfigJson.asInt(config['accent']),
          PrefKeys.cBackground: ThemeConfigJson.asInt(config['background']),
          PrefKeys.cBBackground: ThemeConfigJson.asInt(
            config['bottomBackground'],
          ),
          PrefKeys.cPrimaryText: ThemeConfigJson.asInt(config['primaryText']),
          PrefKeys.cSecondaryText: ThemeConfigJson.asInt(
            config['secondaryText'],
          ),
        },
      });
    }

    // [批14 回修 P2] paletteId 不再只存不用：有效索引才切换，未知值静默忽略
    final paletteId = ThemeConfigJson.asInt(config['paletteId']);
    if (paletteId != null &&
        paletteId >= 0 &&
        paletteId < Md3Palettes.all.length) {
      await ref
          .read(themeNotifierProvider.notifier)
          .setPaletteId(Md3Palettes.all[paletteId].id);
    }

    // [批14 回修 P1-2/P2-5] 只有显式背景字段才动壁纸；空串 = 清除旧壁纸，
    // 避免从「有背景主题」切到「无背景主题」时残留上一套壁纸。
    final hasDayBackground = config.containsKey('bgImage');
    final hasNightBackground = config.containsKey('bgImageNight');
    if (hasDayBackground || hasNightBackground) {
      await ThemeBackgroundImageStore.ensureWarm();
      final dayPath = _resolveSavedBackground(config['bgImage']);
      final nightPath = _resolveSavedBackground(config['bgImageNight']);
      await colorsNotifier.setBgImage(
        day: hasDayBackground ? (dayPath ?? '') : null,
        night: hasNightBackground ? (nightPath ?? '') : null,
      );
      if (mounted) {
        setState(() {
          if (hasDayBackground) _bgImage = dayPath ?? '';
          if (hasNightBackground) _bgImageNight = nightPath ?? '';
        });
      }
    }
    _toast(
      AppStrings.themeAppliedNamed(config['name'] ?? AppStrings.unnamedTheme),
    );
  }

  /// 已保存主题中的背景图引用 → 可用文件绝对路径（缺失/非法返回 null）
  ///
  /// 主题包导入的背景图落盘为相对 Support 目录的标识；全局壁纸渲染仍按
  /// 绝对路径读取，故应用主题时先经 [ThemeBackgroundImageStore.resolveSync]。
  String? _resolveSavedBackground(dynamic raw) {
    if (raw is! String || raw.isEmpty) return null;
    if (!ThemeBackgroundImageStore.isUsableSync(raw)) return null;
    return ThemeBackgroundImageStore.resolveSync(raw);
  }

  /// 保存当前日/夜颜色为命名主题（对齐原版 saveDayTheme/saveNightTheme）
  Future<void> _saveTheme({required bool isNight}) async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(isNight ? AppStrings.saveNightTheme : AppStrings.saveDayTheme),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(hintText: AppStrings.themeName),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(AppStrings.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: Text(AppStrings.confirm),
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
      'bottomBackground': isNight
          ? colors.bottomBackgroundNight
          : colors.bottomBackground,
      // [批13] 字体色槽位以 0 落盘（0=未设置，对齐参考版语义与导入兼容）
      'primaryText': isNight
          ? colors.primaryTextColorNight
          : colors.primaryTextColor,
      'secondaryText': isNight
          ? colors.secondaryTextColorNight
          : colors.secondaryTextColor,
    });
    await _settings.setStringPref(_themeListKey, jsonEncode(list));
    _toast(AppStrings.themeSavedNamed(name));
  }

  // ===== [批14 | 全栈工程师 + UI] 主题包 zip：单条导出 / 导入 =====

  /// 12 个颜色槽位（保存主题、主题包完整色表共用）
  static const List<String> _themeColorKeys = [
    PrefKeys.cPrimary,
    PrefKeys.cAccent,
    PrefKeys.cBackground,
    PrefKeys.cBBackground,
    PrefKeys.cPrimaryText,
    PrefKeys.cSecondaryText,
    PrefKeys.cNPrimary,
    PrefKeys.cNAccent,
    PrefKeys.cNBackground,
    PrefKeys.cNBBackground,
    PrefKeys.cNPrimaryText,
    PrefKeys.cNSecondaryText,
  ];

  /// 导出一条已保存主题为完整主题包 zip（名称 + 12 色槽 + 已有的日/夜背景图）
  ///
  /// 背景图只取条目内记录的 `bgImage`/`bgImageNight`（主题包导入时落盘）；
  /// 旧版保存的主题没有这两个字段，按「无背景」导出，不回落到当前全局壁纸。
  Future<void> _exportSavedTheme(Map<String, dynamic> item) async {
    final name = '${item['name'] ?? AppStrings.unnamedTheme}';
    final isNight = item['isNight'] == true;
    final colors = _colorsFromSavedTheme(item, isNight: isNight);
    final paletteId = ThemeConfigJson.asInt(item['paletteId']);
    final (backgroundLight, backgroundDark) = _savedThemeBackgroundFiles(item);
    final fileName = ThemePackageService.exportFileName(
      name: name,
      millis: DateTime.now().millisecondsSinceEpoch,
    );
    String? tempPath;
    try {
      final tempDir = await getTemporaryDirectory();
      tempPath = '${tempDir.path}${Platform.pathSeparator}$fileName';
      await ThemePackageService.exportThemePackage(
        name: name,
        colors: colors,
        paletteId: paletteId,
        isNight: isNight,
        backgroundLight: backgroundLight,
        backgroundDark: backgroundDark,
        targetPath: tempPath,
      );
      if (!mounted) return;
      final saved = await widget.exportFileService.saveExistingFile(
        sourcePath: tempPath,
        fileName: fileName,
      );
      if (saved == null || !mounted) return; // 用户取消
      _toast(
        widget.exportFileService.savedMessage(
          saved: saved,
          requestedFileName: fileName,
        ),
      );
    } catch (e) {
      debugPrint('ThemeConfigScreen._exportSavedTheme 异常: $e');
      if (mounted) _toast(AppStrings.exportThemePackageFailedWithReason(errorMessage(e)));
    } finally {
      if (tempPath != null) {
        try {
          final temp = File(tempPath);
          if (await temp.exists()) await temp.delete();
        } catch (e) {
          debugPrint('ThemeConfigScreen 主题包临时文件清理失败: $e');
        }
      }
    }
  }

  /// 已保存主题 → 12 色槽状态
  ///
  /// 优先读取主题包导入时保存的完整 `colors` 表（无损再导出）；旧版条目
  /// 只有当前日/夜半组字段，另半组按 0（未设置）处理。
  ThemeColorsState _colorsFromSavedTheme(
    Map<String, dynamic> item, {
    required bool isNight,
  }) {
    final storedColors = item['colors'];
    if (storedColors is Map) {
      int read(String key) => ThemeConfigJson.asInt(storedColors[key]) ?? 0;
      int? nonZero(String key) {
        final value = read(key);
        return value == 0 ? null : value;
      }

      return ThemeColorsState(
        primary: nonZero(PrefKeys.cPrimary),
        accent: nonZero(PrefKeys.cAccent),
        background: nonZero(PrefKeys.cBackground),
        bottomBackground: nonZero(PrefKeys.cBBackground),
        primaryNight: nonZero(PrefKeys.cNPrimary),
        accentNight: nonZero(PrefKeys.cNAccent),
        backgroundNight: nonZero(PrefKeys.cNBackground),
        bottomBackgroundNight: nonZero(PrefKeys.cNBBackground),
        primaryTextColor: read(PrefKeys.cPrimaryText),
        secondaryTextColor: read(PrefKeys.cSecondaryText),
        primaryTextColorNight: read(PrefKeys.cNPrimaryText),
        secondaryTextColorNight: read(PrefKeys.cNSecondaryText),
      );
    }

    int legacy(String key) => ThemeConfigJson.asInt(item[key]) ?? 0;
    int? nonZero(int value) => value == 0 ? null : value;
    if (isNight) {
      return ThemeColorsState(
        primaryNight: nonZero(legacy('primary')),
        accentNight: nonZero(legacy('accent')),
        backgroundNight: nonZero(legacy('background')),
        bottomBackgroundNight: nonZero(legacy('bottomBackground')),
        primaryTextColorNight: legacy('primaryText'),
        secondaryTextColorNight: legacy('secondaryText'),
      );
    }
    return ThemeColorsState(
      primary: nonZero(legacy('primary')),
      accent: nonZero(legacy('accent')),
      background: nonZero(legacy('background')),
      bottomBackground: nonZero(legacy('bottomBackground')),
      primaryTextColor: legacy('primaryText'),
      secondaryTextColor: legacy('secondaryText'),
    );
  }

  /// 已保存主题的背景图文件（日/夜）
  ///
  /// 只有条目显式记录 `bgImage`/`bgImageNight` 时才入包（空值 = 无图）。
  /// 旧版保存的主题没有背景字段，**不得**回落到用户当前全局壁纸，
  /// 避免把与主题无关的私人壁纸打进分享包。
  (File?, File?) _savedThemeBackgroundFiles(Map<String, dynamic> item) {
    File? usable(dynamic raw) {
      if (raw is! String || raw.isEmpty) return null;
      final resolved = ThemeBackgroundImageStore.resolveSync(raw);
      if (resolved.isEmpty) return null;
      try {
        final file = File(resolved);
        return file.existsSync() && file.lengthSync() > 0 ? file : null;
      } catch (_) {
        return null;
      }
    }

    return (usable(item['bgImage']), usable(item['bgImageNight']));
  }

  /// 导入主题包：解析 → 背景图落盘 → 重名递增 → 写入 themeConfigList
  ///
  /// 与参考版的差异（已登记）：参考版导入后立即应用；我方只入库，由用户
  /// 在列表中主动点应用，避免误改当前主题。
  Future<void> _importThemePackage(
    List<Map<String, dynamic>> list,
    StateSetter setDialogState,
  ) async {
    final path = await _pickThemePackagePath();
    if (path == null || !mounted) return;
    try {
      final data = await ThemePackageService.importThemePackage(File(path));
      final name = ThemePackageService.uniqueThemeName(
        data.name,
        list.map((item) => '${item['name'] ?? ''}'),
      );

      String? backgroundLight;
      String? backgroundDark;
      if (data.backgroundLight != null) {
        backgroundLight = await ThemeBackgroundImageStore.storeBytes(
          data.backgroundLight!,
          originalName: data.backgroundLightName ?? 'light.png',
          slot: ThemeBackgroundImageStore.themeLightSlot,
        );
      }
      if (data.backgroundDark != null) {
        backgroundDark = await ThemeBackgroundImageStore.storeBytes(
          data.backgroundDark!,
          originalName: data.backgroundDarkName ?? 'dark.png',
          slot: ThemeBackgroundImageStore.themeDarkSlot,
        );
      }

      int read(String key) => data.colors[key] ?? 0;
      final isNight = data.isNight;
      list.add(<String, dynamic>{
        'name': name,
        'isNight': isNight,
        if (data.paletteId != null) 'paletteId': data.paletteId,
        // 应用现有主题时仍读取半组字段（与 _saveTheme 同构）
        'primary': isNight ? read(PrefKeys.cNPrimary) : read(PrefKeys.cPrimary),
        'accent': isNight ? read(PrefKeys.cNAccent) : read(PrefKeys.cAccent),
        'background': isNight
            ? read(PrefKeys.cNBackground)
            : read(PrefKeys.cBackground),
        'bottomBackground': isNight
            ? read(PrefKeys.cNBBackground)
            : read(PrefKeys.cBBackground),
        'primaryText': isNight
            ? read(PrefKeys.cNPrimaryText)
            : read(PrefKeys.cPrimaryText),
        'secondaryText': isNight
            ? read(PrefKeys.cNSecondaryText)
            : read(PrefKeys.cSecondaryText),
        // 完整 12 色槽（再导出时无损）
        'colors': <String, int>{
          for (final key in _themeColorKeys) key: read(key),
        },
        // 两侧都写（空串 = 明确无背景），避免应用时跨主题残留旧壁纸
        'bgImage': backgroundLight ?? '',
        'bgImageNight': backgroundDark ?? '',
      });
      await _settings.setStringPref(_themeListKey, jsonEncode(list));
      if (!mounted) return;
      setDialogState(() {});
      _toast(AppStrings.themePackageImportedNamed(name));
    } on ThemePackageException catch (e) {
      if (mounted) _toast(AppStrings.importFailedShortWithReason(e.message));
    } catch (e) {
      debugPrint('ThemeConfigScreen._importThemePackage 异常: $e');
      if (mounted) _toast(AppStrings.importFailedShortWithReason(errorMessage(e)));
    }
  }

  /// 选择主题包 zip（测试可注入路径）
  Future<String?> _pickThemePackagePath() async {
    final injected = widget.themePackageFilePicker;
    if (injected != null) return injected();
    try {
      final result = await FilePicker.platform.pickFiles(
        dialogTitle: AppStrings.importThemePackage,
        type: FileType.custom,
        allowedExtensions: ['zip'],
      );
      return result?.files.single.path;
    } catch (e) {
      debugPrint('ThemeConfigScreen._pickThemePackagePath 异常: $e');
      if (mounted) _toast(AppStrings.importFailedNoFile);
      return null;
    }
  }

  // ===== [B3-C1 A3 | 全栈工程师 + UI] 导出/导入主题（文件级最小实现） =====
  // grep 结论：既有能力仅有 SharedPreferences 内 themeConfigList 保存/应用
  // 与 association 关联导入（数据级），无文件级导入导出 → 此处最小实现：
  // 导出当前配色 JSON / 导入应用。颜色值全部来自主题槽位
  // （ThemeColorsState 的 ARGB int + paletteId + themeMode），无硬编码色值。

  /// 导出当前配色为 JSON 文件（paletteId + 主题模式 + 日/夜 6 色组）
  ///
  /// [批13] 配色字段构造抽到 [ThemeConfigJson.buildExportPayload]，与导入
  /// 解码共用同一实现并可做往返测试。
  Future<void> _exportTheme() async {
    final colors = ref.read(themeColorsProvider);
    final themeState = ref.read(themeNotifierProvider);
    final payload = ThemeConfigJson.buildExportPayload(
      colors: colors,
      paletteId: themeState.paletteId,
      themeMode: themeState.themeMode,
    );
    final content = const JsonEncoder.withIndent('  ').convert(payload);
    // [D1 回修 P2-4] 迁移到统一系统另存服务：Android 走自建 SAF 通道
    //（原生写字节 + 异常捕获 + DownloadsProvider 回退），iOS 由插件写
    // bytes，桌面端由服务写盘；禁止裸调 FilePicker.saveFile 不传 bytes
    //（Android/iOS 抛 ArgumentError「Bytes are required」）
    const fileName = 'legado_theme.json';
    const service = ExportFileService();
    try {
      final saved = await service.saveToLocal(
        fileName: fileName,
        content: content,
      );
      if (saved == null || !mounted) return; // 用户取消
      _toast(service.savedMessage(saved: saved, requestedFileName: fileName));
    } catch (e) {
      debugPrint('ThemeConfigScreen._exportTheme 写入异常: $e');
      if (mounted) _toast(AppStrings.exportFailedWithReason(errorMessage(e)));
    }
  }

  /// 导入主题 JSON 并应用（日/夜颜色组 + paletteId + 主题模式）
  Future<void> _importTheme() async {
    final result = await FilePicker.platform.pickFiles(
      dialogTitle: AppStrings.importTheme,
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
      _toast(AppStrings.importFailedBadFormat);
      return;
    }
    if (decoded is! Map<String, dynamic>) {
      _toast(AppStrings.importFailedBadFormat);
      return;
    }

    final notifier = ref.read(themeColorsProvider.notifier);
    // 日/夜颜色组：缺省组/缺字段 → null 清除，保证导入结果确定
    // [批13] 解码与导出共用 [ThemeConfigJson]，旧版主题 JSON 无字体色字段
    // 时同样按 0（未设置）处理，不报错。
    await notifier.applyColors(ThemeConfigJson.decodeColors(decoded));

    // paletteId（未知 id 经 Md3Palettes.byId 回退默认 def，安全）
    final paletteId = decoded['paletteId'];
    if (paletteId is String && paletteId.isNotEmpty) {
      await ref.read(themeNotifierProvider.notifier).setPaletteId(paletteId);
    }
    // 主题模式（未知/缺省值忽略，保持当前模式）
    final importedThemeMode = ThemeConfigJson.themeModeFromName(
      decoded['themeMode'],
    );
    if (importedThemeMode != null) {
      await ref
          .read(themeNotifierProvider.notifier)
          .setThemeMode(importedThemeMode);
    }
    if (mounted) _toast(AppStrings.themeImported);
  }

  /// 应用字体行副标题：未设置 / 文件名 / 加载失败提示
  ///
  /// 文件名截断到 24 字符：IosListTile 副标题允许换行，但长文件名在
  /// 360dp + 大字体下会明显撑高行；截断只影响展示，不改偏好值。
  String _appFontSubtitle(AppFontState state) {
    if (!state.initialized || state.loading) return AppStrings.fontLoading;
    if (!state.isSet) return AppStrings.fontSystemDefault;
    final name = state.displayName ?? AppStrings.fontCustom;
    final short = name.length <= 24 ? name : '${name.substring(0, 23)}…';
    if (state.errorMessage != null) {
      return AppStrings.fontAppliedWithFailure(short);
    }
    return AppStrings.fontAppliedValue(short);
  }

  /// 应用字体选择/清除（参考版外观页「字体设置」；日/夜共用）
  ///
  /// 选中的文件由 [AppFontStore] 复制到应用 Support 目录并校验；
  /// 成功后 Notifier 立即注册新字体族 → MaterialApp 重建即时生效。
  Future<void> _showAppFontDialog() async {
    final appFont = ref.read(appFontProvider);
    final action = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text(AppStrings.fontSettings),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, 'select'),
            child: Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Text(AppStrings.pickFontFile),
            ),
          ),
          if (appFont.isSet)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, 'clear'),
              child: Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: Text(AppStrings.clearFont),
              ),
            ),
        ],
      ),
    );
    if (!mounted || action == null) return;
    if (action == 'select') {
      final outcome = await ref.read(appFontProvider.notifier).pickAndImport();
      if (!mounted) return;
      if (outcome.canceled) return;
      if (outcome.error != null) {
        _toast(outcome.error!);
        return;
      }
      _toast(AppStrings.fontUpdated);
    } else if (action == 'clear') {
      await ref.read(appFontProvider.notifier).clear();
      if (!mounted) return;
      _toast(AppStrings.fontRestoredDefault);
    }
  }

  /// 背景图片选择/删除（对齐原版 backgroundImage；经 ThemeColorsNotifier
  /// 驱动 MaterialApp 全局壁纸即时生效）
  Future<void> _showBgImageDialog(String key) async {
    final isNight = key == PrefKeys.bgImageN;
    final current = isNight ? _bgImageNight : _bgImage;
    final action = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text(AppStrings.backgroundImages),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, 'select'),
            child: Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Text(AppStrings.pickImage),
            ),
          ),
          if (current.isNotEmpty)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, 'delete'),
              child: Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: Text(AppStrings.delete),
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
        dialogTitle: AppStrings.pickBackgroundImage,
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

  /// 容器背景图（日/夜）行副标题：未设置 / 文件名 / 文件缺失提示
  ///
  /// 偏好值可能是相对 Support 目录的可迁移标识（新选图）、绝对路径
  /// （参考版备份/存量），故统一经 store 解析后取文件名；解析不到或文件
  /// 不存在时明确提示「已回落」，与 IosGroup 实际渲染行为一致。
  String _containerBgLabel(String stored) {
    if (stored.isEmpty) return AppStrings.notSetLabel;
    final resolved = ThemeBackgroundImageStore.resolveSync(stored);
    // 相对标识用 `/`（Windows 未预热时 resolveSync 原样返回），绝对路径用
    // 平台分隔符；统一按 `/` 切分取末段文件名。
    final name = resolved.replaceAll('\\', '/').split('/').last;
    return ThemeBackgroundImageStore.isUsableSync(stored)
        ? name
        : AppStrings.fileMissingNamed(name);
  }

  /// 大容器背景图选择/清除（日/夜独立）
  ///
  /// 对齐参考版 `ThemeConfigViewModel.setContainerBackground`：
  /// 选图后复制到应用目录（内容哈希命名，自动去重），偏好存可迁移标识；
  /// 替换/清除时删除上一张自有图片（外部/参考版路径不删）。
  Future<void> _showContainerBgImageDialog({required bool night}) {
    final ui = ref.read(uiSettingsProvider);
    return _showBackgroundImageDialog(
      title: night ? AppStrings.containerBackgroundNight : AppStrings.containerBackgroundDay,
      current: night
          ? ui.largeContainerBackgroundImageDark
          : ui.largeContainerBackgroundImageLight,
      slot: night
          ? ThemeBackgroundImageStore.largeDarkSlot
          : ThemeBackgroundImageStore.largeLightSlot,
      pickerTitle: AppStrings.pickContainerBackgroundImage,
      failurePrefix: AppStrings.setContainerBackgroundFailed,
      apply: (stored) => ref
          .read(uiSettingsProvider.notifier)
          .setLargeContainerBackgroundImage(night: night, storedPath: stored),
    );
  }

  /// 项目（卡片）背景图选择/清除（日/夜独立）
  ///
  /// [设置批2b-1b-2b] 槽位 item_light/item_dark；存储/校验/原子写/去重
  /// 与大容器图完全同口径（[ThemeBackgroundImageStore.storeBytes]）。
  Future<void> _showItemBgImageDialog({required bool night}) {
    final ui = ref.read(uiSettingsProvider);
    return _showBackgroundImageDialog(
      title: night ? AppStrings.itemBackgroundNight : AppStrings.itemBackgroundDay,
      current: night ? ui.itemBackgroundImageDark : ui.itemBackgroundImageLight,
      slot: night
          ? ThemeBackgroundImageStore.itemDarkSlot
          : ThemeBackgroundImageStore.itemLightSlot,
      pickerTitle: AppStrings.pickItemBackgroundImage,
      failurePrefix: AppStrings.setItemBackgroundFailed,
      apply: (stored) => ref
          .read(uiSettingsProvider.notifier)
          .setItemBackgroundImage(night: night, storedPath: stored),
    );
  }

  /// 通用背景图选择/清除对话框（大容器图与项目图共用）
  ///
  /// [current] 为当前偏好值（非空才显示「清除图片」）；[slot] 为
  /// ThemeBackgroundImageStore 槽位；[apply] 负责持久化对应键。
  /// Android 走 SAF 字节流（规避 file_picker MediaStore 陈旧缩略图 FATAL）；
  /// iOS/桌面仍由 picker 内部走 file_picker。
  Future<void> _showBackgroundImageDialog({
    required String title,
    required String current,
    required String slot,
    required String pickerTitle,
    required String failurePrefix,
    required Future<void> Function(String storedPath) apply,
  }) async {
    final action = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text(title),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, 'select'),
            child: Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Text(AppStrings.pickImage),
            ),
          ),
          if (current.isNotEmpty)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, 'delete'),
              child: Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: Text(AppStrings.clearImage),
              ),
            ),
        ],
      ),
    );
    if (!mounted || action == null) return;
    if (action == 'select') {
      try {
        final picked = await ContainerImagePicker.pick(
          dialogTitle: pickerTitle,
        );
        if (picked == null || !mounted) return;
        final stored = await ThemeBackgroundImageStore.storeBytes(
          picked.bytes,
          originalName: picked.name,
          slot: slot,
        );
        await apply(stored);
        // 仅删除自有旧图；参考版/外部绝对路径不动
        if (current.isNotEmpty && current != stored) {
          await ThemeBackgroundImageStore.deleteOwned(current);
        }
      } on ContainerImagePickException catch (e) {
        debugPrint('ThemeConfigScreen.$title 选择失败: $e');
        if (mounted) _toast(e.message);
      } catch (e) {
        debugPrint('ThemeConfigScreen.$title 设置异常: $e');
        if (mounted) {
          // 非图片/超大图（FormatException）直接给中文原因，避免包一层异常名
          final detail = e is FormatException ? e.message : errorMessage(e);
          _toast('$failurePrefix：$detail');
        }
      }
    } else if (action == 'delete') {
      await apply('');
      await ThemeBackgroundImageStore.deleteOwned(current);
    }
  }

  /// 导航栏阴影数值设置（对齐原版 barElevation NumberPicker 0~32）
  Future<void> _showBarElevationDialog() async {
    final value = await _showNumberInputDialog(
      title: AppStrings.navBarShadow,
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
            child: Text(AppStrings.cancel),
          ),
          FilledButton(
            onPressed: () {
              final parsed = int.tryParse(controller.text.trim());
              if (parsed == null || parsed < min || parsed > max) {
                _toast(AppStrings.numberRangeInputHint(min, max));
                return;
              }
              Navigator.pop(ctx, parsed);
            },
            child: Text(AppStrings.confirm),
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
          title: Text(AppStrings.fontScale),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // [队列⑦c A3] 半角冒号 + 空格，对齐参考 font_scale_summary
              // 「当前字体大小: %.1f」（values-zh-rCN/strings.xml :1203），
              // 与 theme_state.fontScaleLabel 保持一致
              Text(
                AppStrings.currentFontSize((current / 10).toStringAsFixed(1)),
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
              child: Text(AppStrings.themeSystem),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(AppStrings.cancel),
            ),
            FilledButton(
              onPressed: () {
                notifier.setFontScale(current.round());
                Navigator.pop(ctx);
              },
              child: Text(AppStrings.confirm),
            ),
          ],
        ),
      ),
    );
  }
}

/// 外观页顶部主题预览（R50 恢复，对齐参考版 3.26.19 实测形态）。
///
/// 参考版标题「外观」正下方是一台居中的手机示意图（dump bounds
/// 384×768px @480dpi = 128×256dp），该控件 `clickable=false`、
/// `text=''`、`content-desc=''`：纯展示且**不带任何文案**。2.0.269 曾因
/// 按「外观预览」文案 grep 参考版二进制资源零命中而误删——控件本来就没有
/// 文案，零命中不等于功能不存在。证据见
/// docs/R50_APPEARANCE_PREVIEW_VERIFY_20261128.md。
///
/// 几何按参考截图逐像素换算（1dp = 3px @480dpi）：
/// - 机身 128×256dp、圆角 16dp、1.5dp primary 描边；
/// - 顶部胶囊开孔 48×16dp，左/上内缩 12dp（实测参考版非水平居中：
///   开孔左边距 37px≈12dp、右边距 206px≈69dp）；
/// - 封面块 56×80dp，左 12dp / 上 36dp，primaryContainer 底 + 右上角
///   16×12dp 的 secondary 角标（内缩 4dp）；
/// - 底部条 40dp 高，surfaceContainerHigh 底 + 居中 20dp primary 圆点。
///
/// 颜色全部取自当前 [ColorScheme]，明暗主题/调色板切换后本页重建即联动。
class _ThemePreviewCard extends StatelessWidget {
  /// 预览定位 Key（参考版无文案，测试只能按 Key 定位）
  static const Key previewKey = Key('theme-preview-card');

  // 机身
  static const double _width = 128;
  static const double _height = 256;
  static const double _cornerRadius = 16;
  static const double _borderWidth = 1.5;

  // 顶部胶囊开孔
  static const double _notchLeft = 12;
  static const double _notchTop = 12;
  static const double _notchWidth = 48;
  static const double _notchHeight = 16;

  // 封面块与右上角角标
  static const double _coverLeft = 12;
  static const double _coverTop = 36;
  static const double _coverWidth = 56;
  static const double _coverHeight = 80;
  static const double _coverRadius = 8;
  static const double _badgeWidth = 16;
  static const double _badgeHeight = 12;
  static const double _badgeInset = 4;

  // 底部条与圆点
  static const double _bottomBarHeight = 40;
  static const double _dotDiameter = 20;

  const _ThemePreviewCard();

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    // Container 的 border 会把 child 内缩 borderWidth；下列坐标均为机身
    // 外框坐标，统一减去描边宽度换算到内容区坐标。
    const double inset = _borderWidth;
    return Padding(
      // 参考版：标题底 → 预览顶 70px≈23dp；下方「主题模式」标题自带
      // 24dp 上间距（IosSectionHeader 默认 padding），合成约 24dp。
      padding: const EdgeInsets.only(top: 24),
      child: Center(
        child: SizedBox(
          key: previewKey,
          width: _width,
          height: _height,
          child: Container(
            decoration: BoxDecoration(
              color: colorScheme.surface,
              borderRadius: BorderRadius.circular(_cornerRadius),
              border: Border.all(
                color: colorScheme.primary,
                width: _borderWidth,
              ),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(_cornerRadius - _borderWidth),
              child: Stack(
                children: [
                  // 顶部胶囊开孔（深灰，取 onSurfaceVariant）
                  Positioned(
                    left: _notchLeft - inset,
                    top: _notchTop - inset,
                    width: _notchWidth,
                    height: _notchHeight,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: colorScheme.onSurfaceVariant,
                        borderRadius: BorderRadius.circular(_notchHeight / 2),
                      ),
                    ),
                  ),
                  // 封面块（primaryContainer）+ 右上角深色角标
                  Positioned(
                    left: _coverLeft - inset,
                    top: _coverTop - inset,
                    width: _coverWidth,
                    height: _coverHeight,
                    child: Container(
                      decoration: BoxDecoration(
                        color: colorScheme.primaryContainer,
                        borderRadius: BorderRadius.circular(_coverRadius),
                      ),
                      child: Stack(
                        children: [
                          Positioned(
                            right: _badgeInset,
                            top: _badgeInset,
                            width: _badgeWidth,
                            height: _badgeHeight,
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                color: colorScheme.secondary,
                                borderRadius: BorderRadius.circular(4),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  // 底部浅色条（surfaceContainerHigh）+ 居中 primary 圆点
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    height: _bottomBarHeight,
                    child: ColoredBox(
                      color: colorScheme.surfaceContainerHigh,
                      child: Center(
                        child: SizedBox(
                          width: _dotDiameter,
                          height: _dotDiameter,
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: colorScheme.primary,
                              shape: BoxShape.circle,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
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

  const _ThemeModeSelector({required this.selected, required this.onChanged});

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
                  ThemeMode.system => AppStrings.themeSystem,
                  ThemeMode.light => AppStrings.themeLight,
                  ThemeMode.dark => AppStrings.themeDark,
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
              // 调色板 label 为引擎数据值（生成器产物 + 传给 Rust 的 themeName），
              // 界面显示名按 id 走 AppStrings 本地化（L10N 批3）
              AppStrings.md3PaletteName(palette.id),
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
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            ),
          ],
        ],
      ),
    );
  }
}

/// 主题配置重命名对话框（自带 controller 生命周期）
class _ThemeConfigRenameDialog extends StatefulWidget {
  const _ThemeConfigRenameDialog({required this.initialValue});

  final String initialValue;

  @override
  State<_ThemeConfigRenameDialog> createState() =>
      _ThemeConfigRenameDialogState();
}

class _ThemeConfigRenameDialogState extends State<_ThemeConfigRenameDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initialValue,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _confirm() => Navigator.pop(context, _controller.text);

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(AppStrings.renameTheme),
      content: TextField(
        key: const ValueKey('theme-config-rename-field'),
        controller: _controller,
        autofocus: true,
        maxLength: 40,
        decoration: InputDecoration(hintText: AppStrings.themeName),
        onSubmitted: (_) => _confirm(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(AppStrings.cancel),
        ),
        FilledButton(
          key: const ValueKey('theme-config-rename-confirm'),
          onPressed: _confirm,
          child: Text(AppStrings.confirm),
        ),
      ],
    );
  }
}
