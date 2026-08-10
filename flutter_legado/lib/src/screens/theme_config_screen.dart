// [UI-fix v2.0.5 | 2026-08-08] 主题设置页对齐原版 pref_config_theme.xml +
// ThemeConfigFragment（24 项）：启动图标/欢迎页样式/沉浸式状态栏/沉浸式导航栏/
// 导航栏阴影/字体缩放/封面设置/主题列表/底栏皮肤/壁纸取色 ×2 +
// 白天/夜间 主色调/强调色/背景色/底栏色/背景图片/透明导航栏/保存主题。
// 颜色配置经 ThemeColorsNotifier 接入 MaterialApp ThemeData 即时生效；
// Android 专属项持久化并以灰字"仅 Android 生效"标注；
// 视觉保持 iOS 分组卡片风格（IosGroup/IosListTile） — Qoder
import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;

import '../bridge/ffi.dart';
import '../constants/pref_keys.dart';
import '../providers/providers.dart';
import '../providers/theme/theme_colors_notifier.dart';
import '../providers/theme/theme_notifier.dart';
import '../services/settings_service.dart';
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
  final _settings = SettingsService();

  bool _loading = true;

  // ===== 通用组状态（对齐原版顶部无分组项）=====
  String _launcherIcon = 'iconMain';
  bool _transparentStatusBar = true;
  bool _immNavigationBar = true;
  int _barElevation = 0;
  bool _bottomBarSkin = false;
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
    final bottomBarSkin = await _settings.getBoolPref(
      PrefKeys.bottomBarSkin,
      defaultValue: false,
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
    if (!mounted) return;
    setState(() {
      _launcherIcon = launcherIcon;
      _transparentStatusBar = transparentStatusBar;
      _immNavigationBar = immNavigationBar;
      _barElevation = barElevation;
      _bottomBarSkin = bottomBarSkin;
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

  @override
  Widget build(BuildContext context) {
    final themeState = ref.watch(themeNotifierProvider);
    final themeNotifier = ref.read(themeNotifierProvider.notifier);
    final colors = ref.watch(themeColorsProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('主题设置')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : IosGroupedBody(
              child: ListView(
                padding: const EdgeInsets.only(bottom: 32),
                children: [
                  // === 主题模式（Flutter 侧全局深浅色切换）===
                  const IosSectionHeader('主题模式'),
                  SegmentedButton<ThemeMode>(
                    segments: const [
                      ButtonSegment(
                        value: ThemeMode.system,
                        label: Text('跟随系统'),
                        icon: Icon(Icons.brightness_auto),
                      ),
                      ButtonSegment(
                        value: ThemeMode.light,
                        label: Text('浅色'),
                        icon: Icon(Icons.light_mode),
                      ),
                      ButtonSegment(
                        value: ThemeMode.dark,
                        label: Text('深色'),
                        icon: Icon(Icons.dark_mode),
                      ),
                    ],
                    selected: {themeState.themeMode},
                    onSelectionChanged: (selected) =>
                        themeNotifier.setThemeMode(selected.first),
                  ),

                  // === 全局字体缩放（对齐原版 fontScale）===
                  const IosSectionHeader('全局字体大小'),
                  IosGroup(children: [
                    IosListTile(
                      icon: Icons.format_size,
                      iconBackground: Colors.indigo,
                      title: '字体缩放',
                      subtitle: themeState.fontScaleLabel,
                      showDisclosure: true,
                      onTap: () => _showFontScalePicker(
                          context, themeState, themeNotifier),
                    ),
                  ]),

                  // === 通用（对齐原版顶部未分组项）===
                  const IosSectionHeader('通用'),
                  IosGroup(children: [
                    IosListTile(
                      icon: Icons.apps,
                      iconBackground: Colors.blueGrey,
                      title: '启动图标',
                      subtitle: _androidOnly,
                      value: _launcherIconLabels[
                          _launcherIcons.indexOf(_launcherIcon).clamp(0, 6)],
                      showDisclosure: true,
                      onTap: _showLauncherIconPicker,
                    ),
                    IosListTile(
                      icon: Icons.waving_hand_outlined,
                      iconBackground: Colors.teal,
                      title: '欢迎页样式',
                      subtitle: '启动欢迎页的图标与文字显示',
                      showDisclosure: true,
                      onTap: _showWelcomeStyleDialog,
                    ),
                    SwitchListTile(
                      title: const Text('沉浸式状态栏'),
                      subtitle: const Text(_androidOnly),
                      value: _transparentStatusBar,
                      onChanged: (v) {
                        setState(() => _transparentStatusBar = v);
                        _settings.setBoolPref(PrefKeys.transparentStatusBar, v);
                      },
                    ),
                    SwitchListTile(
                      title: const Text('沉浸式导航栏'),
                      subtitle: const Text(_androidOnly),
                      value: _immNavigationBar,
                      onChanged: (v) {
                        setState(() => _immNavigationBar = v);
                        _settings.setBoolPref(PrefKeys.immNavigationBar, v);
                      },
                    ),
                    IosListTile(
                      icon: Icons.layers_outlined,
                      iconBackground: Colors.brown,
                      title: '导航栏阴影',
                      subtitle: _androidOnly,
                      value: '$_barElevation',
                      showDisclosure: true,
                      onTap: _showBarElevationDialog,
                    ),
                    IosListTile(
                      icon: Icons.image_outlined,
                      iconBackground: Colors.deepOrange,
                      title: '封面设置',
                      subtitle: '书籍默认封面显示方式',
                      showDisclosure: true,
                      onTap: _showCoverConfigDialog,
                    ),
                    IosListTile(
                      icon: Icons.color_lens_outlined,
                      iconBackground: Colors.purple,
                      title: '主题列表',
                      subtitle: '保存/切换自定义主题配置',
                      showDisclosure: true,
                      onTap: _showThemeListDialog,
                    ),
                    SwitchListTile(
                      title: const Text('底部操作栏皮肤'),
                      subtitle: const Text(_androidOnly),
                      value: _bottomBarSkin,
                      onChanged: (v) {
                        setState(() => _bottomBarSkin = v);
                        _settings.setBoolPref(PrefKeys.bottomBarSkin, v);
                      },
                    ),
                    SwitchListTile(
                      title: const Text('壁纸取色'),
                      subtitle: const Text(_androidOnly),
                      value: _wallpaperColorFollow,
                      onChanged: (v) {
                        setState(() => _wallpaperColorFollow = v);
                        _settings.setBoolPref(PrefKeys.wallpaperColorFollow, v);
                      },
                    ),
                    // 对齐原版 dependency="wallpaperColorFollow"：开启后才可见
                    if (_wallpaperColorFollow)
                      SwitchListTile(
                        title: const Text('壁纸变化时自动更新取色'),
                        subtitle: const Text(_androidOnly),
                        value: _wallpaperColorAutoUpdate,
                        onChanged: (v) {
                          setState(() => _wallpaperColorAutoUpdate = v);
                          _settings.setBoolPref(
                              PrefKeys.wallpaperColorAutoUpdate, v);
                        },
                      ),
                  ]),

                  // === 白天主题（对齐原版 day_theme 分组）===
                  const IosSectionHeader('白天主题'),
                  IosGroup(children: [
                    _colorTile(PrefKeys.cPrimary, '主色调', colors),
                    _colorTile(PrefKeys.cAccent, '强调色', colors),
                    _colorTile(PrefKeys.cBackground, '背景色', colors,
                        isBackground: true),
                    _colorTile(PrefKeys.cBBackground, '底部操作栏颜色', colors),
                    IosListTile(
                      icon: Icons.wallpaper,
                      iconBackground: Colors.green,
                      title: '背景图片',
                      subtitle: _bgImage.isEmpty ? '未设置' : _bgImage,
                      showDisclosure: true,
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
                      icon: Icons.save_outlined,
                      iconBackground: Colors.blue,
                      title: '保存白天主题',
                      subtitle: '将当前白天颜色保存到主题列表',
                      showDisclosure: true,
                      onTap: () => _saveTheme(isNight: false),
                    ),
                  ]),

                  // === 夜间主题（对齐原版 night_theme 分组）===
                  const IosSectionHeader('夜间主题'),
                  IosGroup(children: [
                    _colorTile(PrefKeys.cNPrimary, '主色调', colors,
                        isNight: true),
                    _colorTile(PrefKeys.cNAccent, '强调色', colors,
                        isNight: true),
                    _colorTile(PrefKeys.cNBackground, '背景色', colors,
                        isNight: true, isBackground: true),
                    _colorTile(PrefKeys.cNBBackground, '底部操作栏颜色', colors,
                        isNight: true),
                    IosListTile(
                      icon: Icons.wallpaper,
                      iconBackground: Colors.green,
                      title: '背景图片',
                      subtitle: _bgImageNight.isEmpty ? '未设置' : _bgImageNight,
                      showDisclosure: true,
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
                      icon: Icons.save_outlined,
                      iconBackground: Colors.blue,
                      title: '保存夜间主题',
                      subtitle: '将当前夜间颜色保存到主题列表',
                      showDisclosure: true,
                      onTap: () => _saveTheme(isNight: true),
                    ),
                  ]),
                  const IosSectionFooter(
                      '背景图片当前仅持久化保存，Flutter 端全局背景渲染将在后续版本接线'),
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
      icon: Icons.palette_outlined,
      iconBackground: isNight ? Colors.indigo : Colors.orange,
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
                Icon(
                  Icons.chevron_right,
                  size: 20,
                  color: Theme.of(context).colorScheme.outlineVariant,
                ),
              ],
            ),
      showDisclosure: value == null,
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
  }

  /// 欢迎页样式配置（对齐原版 pref_config_welcome：显示时长/图标/文字）
  Future<void> _showWelcomeStyleDialog() async {
    var showTime = await _settings.getIntPref(
      PrefKeys.welcomeShowTime,
      defaultValue: 600,
    );
    var showIcon = await _settings.getBoolPref(
      PrefKeys.welcomeShowIcon,
      defaultValue: true,
    );
    var showText = await _settings.getBoolPref(
      PrefKeys.welcomeShowText,
      defaultValue: true,
    );
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('欢迎页样式'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('显示图标'),
                value: showIcon,
                onChanged: (v) {
                  setDialogState(() => showIcon = v);
                  _settings.setBoolPref(PrefKeys.welcomeShowIcon, v);
                },
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('显示文字'),
                value: showText,
                onChanged: (v) {
                  setDialogState(() => showText = v);
                  _settings.setBoolPref(PrefKeys.welcomeShowText, v);
                },
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('显示时长'),
                subtitle: Text('$showTime 毫秒'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () async {
                  final value = await _showNumberInputDialog(
                    title: '显示时长（毫秒）',
                    current: showTime,
                    min: 0,
                    max: 9999,
                  );
                  if (value != null) {
                    setDialogState(() => showTime = value);
                    _settings.setIntPref(PrefKeys.welcomeShowTime, value);
                  }
                },
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
              // [Task #74 | 2026-08-10] §5.13-10：封面规则子项（契约 §2.4.8
              // searchCoverRules 测试入口；对齐原版 CoverRuleConfigDialog
              // 按书名测试语义；规则数据管理待后续契约） — Qoder
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('封面规则'),
                subtitle: const Text('按书名测试启用规则搜封面（规则管理待后续契约）'),
                trailing: const Icon(Icons.chevron_right),
                onTap: _showCoverRuleTestDialog,
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

  /// 封面规则测试对话框（契约 §2.4.8 searchCoverRules；
  /// 对齐原版 CoverRuleConfigDialog 按书名测试语义）
  ///
  /// 契约能力边界：searchCoverRules 仅支持「按书名执行启用规则搜封面」，
  /// 规则数据管理（增删改/启用开关）无契约 CRUD 接口，本批不做，
  /// UI 诚实标注「规则管理待后续契约」。 — Qoder
  Future<void> _showCoverRuleTestDialog() async {
    await showDialog<void>(
      context: context,
      builder: (_) => _CoverRuleTestDialog(
        onSearch: (name) =>
            ref.read(bookApiProvider).searchCoverRules(name),
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

  /// 主题列表对话框：点击应用、删除按钮移除
  Future<void> _showThemeListDialog() async {
    var list = await _loadThemeList();
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('主题列表'),
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
                          isNight ? Icons.dark_mode : Icons.light_mode,
                        ),
                        title: Text('${item['name'] ?? '未命名'}'),
                        subtitle: Text(isNight ? '夜间主题' : '白天主题'),
                        trailing: IconButton(
                          icon: const Icon(Icons.delete_outline),
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

  /// 背景图片选择/删除（对齐原版 backgroundImage 对话框；当前仅持久化路径）
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
      await _settings.setStringPref(key, path);
    } else if (action == 'delete') {
      setState(() {
        if (isNight) {
          _bgImageNight = '';
        } else {
          _bgImage = '';
        }
      });
      await _settings.removePref(key);
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
              Text(
                '当前字体大小：${(current / 10).toStringAsFixed(1)}',
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

/// 封面规则测试对话框（自持 StatefulWidget，照 _TextPromptDialog 范式）：
/// controller 在 State 内创建、dispose 中随子树卸载统一释放。
/// 输入书名 → onSearch（searchCoverRules）→ 候选封面 URL 列表
/// （可预览/复制）；空结果/失败均有提示。
/// [Task #74 | 2026-08-10] — Qoder
class _CoverRuleTestDialog extends StatefulWidget {
  /// 搜索回调（由调用方注入 BookApi.searchCoverRules）
  final Future<List<String>> Function(String name) onSearch;

  const _CoverRuleTestDialog({required this.onSearch});

  @override
  State<_CoverRuleTestDialog> createState() => _CoverRuleTestDialogState();
}

class _CoverRuleTestDialogState extends State<_CoverRuleTestDialog> {
  late final TextEditingController _nameController = TextEditingController();
  bool _loading = false;
  bool _searched = false;
  String? _error;
  List<String> _results = [];

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  String _errMsg(Object e) => e is BridgeError ? e.message : e.toString();

  Future<void> _search() async {
    final name = _nameController.text.trim();
    if (name.isEmpty) {
      setState(() => _error = '请输入书名');
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final list = await widget.onSearch(name);
      if (!mounted) return;
      setState(() {
        _results = list;
        _searched = true;
        _loading = false;
      });
    } catch (e) {
      debugPrint('ThemeConfigScreen 封面规则测试搜索异常: $e');
      if (!mounted) return;
      setState(() {
        _error = '搜索失败: ${_errMsg(e)}';
        _results = [];
        _searched = true;
        _loading = false;
      });
    }
  }

  /// 候选封面预览（网络图加载失败兑底提示）
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
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '按书名测试启用中的封面规则；'
              '规则数据管理（增删改）待后续契约支持。',
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _nameController,
                    autofocus: true,
                    decoration: const InputDecoration(
                      hintText: '输入书名',
                      border: OutlineInputBorder(),
                    ),
                    onSubmitted: (_) => _search(),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: _loading ? null : _search,
                  child: const Text('测试搜索'),
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (_loading)
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
                constraints: const BoxConstraints(maxHeight: 240),
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
                            icon: const Icon(Icons.image_outlined, size: 18),
                            tooltip: '预览',
                            visualDensity: VisualDensity.compact,
                            onPressed: () => _preview(url),
                          ),
                          IconButton(
                            icon: const Icon(Icons.copy, size: 18),
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
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('关闭'),
        ),
      ],
    );
  }
}
