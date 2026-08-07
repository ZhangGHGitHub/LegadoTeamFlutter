import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:shared_preferences/shared_preferences.dart';

import '../models/flip_mode.dart';
import '../providers/providers.dart';
import '../providers/reader/reader_notifier.dart';
import '../routes.dart';
import '../services/system_brightness.dart';

/// 点击区域可映射的功能
enum TapAction {
  none,
  prevPage,
  nextPage,
  toggleControls,
  openCatalog;

  String get label {
    switch (this) {
      case TapAction.none:
        return '无操作';
      case TapAction.prevPage:
        return '上一页/章';
      case TapAction.nextPage:
        return '下一页/章';
      case TapAction.toggleControls:
        return '切换工具栏';
      case TapAction.openCatalog:
        return '打开目录';
    }
  }
}

/// 阅读器高级配置（持久化到 SharedPreferences）
class ReaderAdvancedConfig {
  static const _prefix = 'reader_adv_';

  // 自动翻页
  bool autoPageTurn;
  double autoPageTurnInterval; // 秒
  bool autoPageTurnForward; // true=下一章 false=上一章

  // 点击区域映射
  TapAction leftAction;
  TapAction centerAction;
  TapAction rightAction;

  // 段落间距
  double paragraphSpacing;

  // [UI-fix v2.0.2 | 2026-08-06] 对标原版 ReadBookConfig：
  // 字距调节/首行缩进/两端对齐（MoreConfig textFullJustify） — Qoder
  double letterSpacing;
  bool paragraphIndent;
  bool textFullJustify;

  // [UI-fix v2.0.3 | 2026-08-06] 页面边距（对标原版 ReadBookConfig
  // paddingTop/paddingBottom/paddingLeft/paddingRight） — Qoder
  double pageMarginTop;
  double pageMarginBottom;
  double pageMarginLeft;
  double pageMarginRight;

  // 状态栏提示栏
  bool showBattery;
  bool showTime;
  bool showProgress;
  bool showChapterName;

  // 翻页模式
  FlipMode flipMode;

  // [UI-fix v2.0.3 | 2026-08-08] MoreConfig 第①批无平台依赖项落地：
  // 键名对齐原版 AppConfig/PreferKey（见 MoreConfigDialog.onSharedPreferenceChanged
  // 事件语义与 pref_config_read.xml），持久化不使用 reader_adv_ 前缀 — Qoder

  /// 屏幕方向（0跟随系统 1竖屏 2横屏 3自动传感器 4反向竖屏 5反向横屏，
  /// 对标原版 screenOrientation/screen_direction_value）
  int screenOrientation;

  /// 保持亮屏时长（秒：0默认 60/300/600 -1常亮，对标原版 keep_light/screen_time_out）
  int keepLight;

  /// 隐藏状态栏（对标原版 hideStatusBar）
  bool hideStatusBar;

  /// 隐藏导航栏（对标原版 hideNavigationBar）
  bool hideNavigationBar;

  /// 进度条行为（'page'=调章内页 'chapter'=调章节，对标原版 progressBarBehavior）
  String progressBarBehavior;

  /// 滚动翻页无动画（对标原版 noAnimScrollPage）
  bool noAnimScrollPage;

  /// 自动换源：章节加载失败自动切换书源（对标原版 autoChangeSource）
  bool autoChangeSource;

  /// 长按选择文本（对标原版 selectText/textSelectAble）
  bool selectText;

  /// 底栏亮度控件显隐（对标原版 showBrightnessView）
  bool showBrightnessView;

  /// 顶栏显示标题附加区（书名后追加章名，对标原版 showReadTitleAddition）
  bool showReadTitleAddition;

  /// 工具栏样式跟随阅读页（背景/文字色跟随页面，对标原版 readBarStyleFollowPage）
  bool readBarStyleFollowPage;

  ReaderAdvancedConfig({
    this.autoPageTurn = false,
    this.autoPageTurnInterval = 10,
    this.autoPageTurnForward = true,
    this.leftAction = TapAction.prevPage,
    this.centerAction = TapAction.toggleControls,
    this.rightAction = TapAction.nextPage,
    this.paragraphSpacing = 12,
    this.letterSpacing = 0,
    this.paragraphIndent = true,
    this.textFullJustify = true,
    this.pageMarginTop = 24,
    this.pageMarginBottom = 24,
    this.pageMarginLeft = 20,
    this.pageMarginRight = 20,
    this.showBattery = true,
    this.showTime = true,
    this.showProgress = true,
    this.showChapterName = true,
    this.flipMode = FlipMode.slide,
    this.screenOrientation = 0,
    this.keepLight = 0,
    this.hideStatusBar = false,
    this.hideNavigationBar = false,
    this.progressBarBehavior = 'page',
    this.noAnimScrollPage = false,
    this.autoChangeSource = true,
    this.selectText = true,
    this.showBrightnessView = true,
    this.showReadTitleAddition = true,
    this.readBarStyleFollowPage = false,
  });

  /// 从持久化存储加载
  static Future<ReaderAdvancedConfig> load() async {
    final prefs = await SharedPreferences.getInstance();
    TapAction tap(String key, TapAction def) {
      final i = prefs.getInt('$_prefix$key');
      if (i == null || i < 0 || i >= TapAction.values.length) return def;
      return TapAction.values[i];
    }

    return ReaderAdvancedConfig(
      autoPageTurn: prefs.getBool('${_prefix}auto_page_turn') ?? false,
      autoPageTurnInterval: (prefs.getDouble('${_prefix}auto_interval') ?? 10)
          .clamp(3.0, 120.0),
      autoPageTurnForward: prefs.getBool('${_prefix}auto_forward') ?? true,
      leftAction: tap('left_action', TapAction.prevPage),
      centerAction: tap('center_action', TapAction.toggleControls),
      rightAction: tap('right_action', TapAction.nextPage),
      paragraphSpacing: (prefs.getDouble('${_prefix}paragraph_spacing') ?? 12)
          .clamp(0.0, 48.0),
      letterSpacing: (prefs.getDouble('${_prefix}letter_spacing') ?? 0)
          .clamp(0.0, 10.0),
      paragraphIndent: prefs.getBool('${_prefix}paragraph_indent') ?? true,
      textFullJustify: prefs.getBool('${_prefix}text_full_justify') ?? true,
      pageMarginTop: (prefs.getDouble('${_prefix}margin_top') ?? 24)
          .clamp(0.0, 80.0),
      pageMarginBottom: (prefs.getDouble('${_prefix}margin_bottom') ?? 24)
          .clamp(0.0, 80.0),
      pageMarginLeft: (prefs.getDouble('${_prefix}margin_left') ?? 20)
          .clamp(0.0, 80.0),
      pageMarginRight: (prefs.getDouble('${_prefix}margin_right') ?? 20)
          .clamp(0.0, 80.0),
      showBattery: prefs.getBool('${_prefix}show_battery') ?? true,
      showTime: prefs.getBool('${_prefix}show_time') ?? true,
      showProgress: prefs.getBool('${_prefix}show_progress') ?? true,
      showChapterName: prefs.getBool('${_prefix}show_chapter_name') ?? true,
      flipMode: FlipMode.fromIndex(prefs.getInt('${_prefix}flip_mode') ?? FlipMode.slide.index),
      // [UI-fix v2.0.3 | 2026-08-08] 第①批 MoreConfig 项读取（键名=原版键）— Qoder
      screenOrientation:
          (prefs.getInt('screenOrientation') ?? 0).clamp(0, 5),
      keepLight: prefs.getInt('keep_light') ?? 0,
      hideStatusBar: prefs.getBool('hideStatusBar') ?? false,
      hideNavigationBar: prefs.getBool('hideNavigationBar') ?? false,
      progressBarBehavior: (prefs.getString('progressBarBehavior') == 'chapter')
          ? 'chapter'
          : 'page',
      noAnimScrollPage: prefs.getBool('noAnimScrollPage') ?? false,
      autoChangeSource: prefs.getBool('autoChangeSource') ?? true,
      selectText: prefs.getBool('selectText') ?? true,
      showBrightnessView: prefs.getBool('showBrightnessView') ?? true,
      showReadTitleAddition: prefs.getBool('showReadTitleAddition') ?? true,
      readBarStyleFollowPage: prefs.getBool('readBarStyleFollowPage') ?? false,
    );
  }

  /// 持久化当前配置
  Future<void> save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('${_prefix}auto_page_turn', autoPageTurn);
    await prefs.setDouble('${_prefix}auto_interval', autoPageTurnInterval);
    await prefs.setBool('${_prefix}auto_forward', autoPageTurnForward);
    await prefs.setInt('${_prefix}left_action', leftAction.index);
    await prefs.setInt('${_prefix}center_action', centerAction.index);
    await prefs.setInt('${_prefix}right_action', rightAction.index);
    await prefs.setDouble('${_prefix}paragraph_spacing', paragraphSpacing);
    await prefs.setDouble('${_prefix}letter_spacing', letterSpacing);
    await prefs.setBool('${_prefix}paragraph_indent', paragraphIndent);
    await prefs.setBool('${_prefix}text_full_justify', textFullJustify);
    await prefs.setDouble('${_prefix}margin_top', pageMarginTop);
    await prefs.setDouble('${_prefix}margin_bottom', pageMarginBottom);
    await prefs.setDouble('${_prefix}margin_left', pageMarginLeft);
    await prefs.setDouble('${_prefix}margin_right', pageMarginRight);
    await prefs.setBool('${_prefix}show_battery', showBattery);
    await prefs.setBool('${_prefix}show_time', showTime);
    await prefs.setBool('${_prefix}show_progress', showProgress);
    await prefs.setBool('${_prefix}show_chapter_name', showChapterName);
    await prefs.setInt('flip_mode', flipMode.index);
    // [UI-fix v2.0.3 | 2026-08-08] 第①批 MoreConfig 项持久化（键名=原版键）— Qoder
    await prefs.setInt('screenOrientation', screenOrientation);
    await prefs.setInt('keep_light', keepLight);
    await prefs.setBool('hideStatusBar', hideStatusBar);
    await prefs.setBool('hideNavigationBar', hideNavigationBar);
    await prefs.setString('progressBarBehavior', progressBarBehavior);
    await prefs.setBool('noAnimScrollPage', noAnimScrollPage);
    await prefs.setBool('autoChangeSource', autoChangeSource);
    await prefs.setBool('selectText', selectText);
    await prefs.setBool('showBrightnessView', showBrightnessView);
    await prefs.setBool('showReadTitleAddition', showReadTitleAddition);
    await prefs.setBool('readBarStyleFollowPage', readBarStyleFollowPage);
  }

  ReaderAdvancedConfig copy() => ReaderAdvancedConfig(
        autoPageTurn: autoPageTurn,
        autoPageTurnInterval: autoPageTurnInterval,
        autoPageTurnForward: autoPageTurnForward,
        leftAction: leftAction,
        centerAction: centerAction,
        rightAction: rightAction,
        paragraphSpacing: paragraphSpacing,
        letterSpacing: letterSpacing,
        paragraphIndent: paragraphIndent,
        textFullJustify: textFullJustify,
        pageMarginTop: pageMarginTop,
        pageMarginBottom: pageMarginBottom,
        pageMarginLeft: pageMarginLeft,
        pageMarginRight: pageMarginRight,
        showBattery: showBattery,
        showTime: showTime,
        showProgress: showProgress,
        showChapterName: showChapterName,
        flipMode: flipMode,
        screenOrientation: screenOrientation,
        keepLight: keepLight,
        hideStatusBar: hideStatusBar,
        hideNavigationBar: hideNavigationBar,
        progressBarBehavior: progressBarBehavior,
        noAnimScrollPage: noAnimScrollPage,
        autoChangeSource: autoChangeSource,
        selectText: selectText,
        showBrightnessView: showBrightnessView,
        showReadTitleAddition: showReadTitleAddition,
        readBarStyleFollowPage: readBarStyleFollowPage,
      );
}

/// 阅读器高级配置面板
///
/// 以底部弹出面板形式展示，支持：
/// - 自动翻页（开关 / 间隔 / 方向）
/// - 点击区域功能映射（左 / 中 / 右）
/// - 段落间距调节
/// - 状态栏提示栏项配置（电量 / 时间 / 进度 / 章节名）
/// - 翻页模式选择（仿真 / 滑动 / 覆盖 / 无动画）
/// - [UI-fix v2.0.2 | 2026-08-06] 字体选择/字距调节/首行缩进/
///   简繁转换/MoreConfig（两端对齐） — Qoder
class ReaderConfigPanel extends ConsumerStatefulWidget {
  final ReaderAdvancedConfig config;

  /// 配置变更回调（每次修改后触发，便于阅读器实时应用）
  final ValueChanged<ReaderAdvancedConfig>? onChanged;

  const ReaderConfigPanel({
    super.key,
    required this.config,
    this.onChanged,
  });

  /// 便捷入口：弹出配置面板
  static Future<void> show(
    BuildContext context, {
    required ReaderAdvancedConfig config,
    ValueChanged<ReaderAdvancedConfig>? onChanged,
  }) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.75,
        minChildSize: 0.4,
        maxChildSize: 0.92,
        builder: (_, scrollController) => SingleChildScrollView(
          controller: scrollController,
          child: ReaderConfigPanel(config: config, onChanged: onChanged),
        ),
      ),
    );
  }

  @override
  ConsumerState<ReaderConfigPanel> createState() => _ReaderConfigPanelState();
}

class _ReaderConfigPanelState extends ConsumerState<ReaderConfigPanel> {
  late final ReaderAdvancedConfig _config = widget.config.copy();

  /// 当前阅读字体显示名（与 FontScreen 持久化键 reader_font_family 同步）
  String _fontLabel = '默认字体';

  /// 简繁转换类型（0=不转换 1=繁转简 2=简转繁，对标原版 chineseConvertType）
  int _convertType = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_loadFontLabel());
    unawaited(_loadConvertType());
  }

  Future<void> _loadFontLabel() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final family = prefs.getString('reader_font_family');
      if (!mounted || family == null) return;
      setState(() => _fontLabel = family.replaceFirst('Custom_', ''));
    } catch (_) {
      // 读取失败保持默认字体标签
    }
  }

  Future<void> _loadConvertType() async {
    try {
      final type = await ref.read(bookApiProvider).getChineseConvertType();
      if (!mounted) return;
      setState(() => _convertType = type.clamp(0, 2));
    } catch (_) {
      // FFI 不可用时保持不转换
    }
  }

  void _commit() {
    unawaited(_config.save());
    widget.onChanged?.call(_config.copy());
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.onSurfaceVariant.withValues(alpha: 0.4),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Text('高级阅读设置', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            _buildFlipMode(),
            const Divider(),
            _buildAutoPageTurn(),
            const Divider(),
            _buildTapZones(),
            const Divider(),
            _buildParagraphSpacing(),
            const Divider(),
            _buildTypography(),
            const Divider(),
            _buildPageMargins(),
            const Divider(),
            _buildMoreConfig(),
            const Divider(),
            _buildBrightnessControl(),
            const Divider(),
            _buildStatusBar(),
          ],
        ),
      ),
    );
  }

  Widget _sectionTitle(String title, IconData icon) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Icon(icon, size: 18, color: Theme.of(context).colorScheme.primary),
          const SizedBox(width: 8),
          Text(title,
              style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }

  // ===== 翻页模式 =====

  Widget _buildFlipMode() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionTitle('翻页模式', Icons.auto_stories_outlined),
        SegmentedButton<FlipMode>(
          segments: [
            for (final mode in FlipMode.values)
              ButtonSegment(
                value: mode,
                label: Text(mode.displayName),
                icon: Text(mode.icon),
              ),
          ],
          selected: {_config.flipMode},
          onSelectionChanged: (sel) {
            _config.flipMode = sel.first;
            _commit();
          },
        ),
      ],
    );
  }

  // ===== 自动翻页 =====

  Widget _buildAutoPageTurn() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionTitle('自动翻页', Icons.timer_outlined),
        SwitchListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          title: const Text('启用自动翻页'),
          value: _config.autoPageTurn,
          onChanged: (v) {
            _config.autoPageTurn = v;
            _commit();
          },
        ),
        if (_config.autoPageTurn) ...[
          Row(
            children: [
              Text('间隔 ${_config.autoPageTurnInterval.toStringAsFixed(0)} 秒',
                  style: Theme.of(context).textTheme.bodyMedium),
              Expanded(
                child: Slider(
                  value: _config.autoPageTurnInterval,
                  min: 3,
                  max: 60,
                  divisions: 57,
                  onChanged: (v) {
                    _config.autoPageTurnInterval = v;
                    _commit();
                  },
                ),
              ),
            ],
          ),
          Row(
            children: [
              Text('翻页方向', style: Theme.of(context).textTheme.bodyMedium),
              const SizedBox(width: 12),
              Expanded(
                child: SegmentedButton<bool>(
                  segments: const [
                    ButtonSegment(value: true, label: Text('下一章')),
                    ButtonSegment(value: false, label: Text('上一章')),
                  ],
                  selected: {_config.autoPageTurnForward},
                  onSelectionChanged: (sel) {
                    _config.autoPageTurnForward = sel.first;
                    _commit();
                  },
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }

  // ===== 点击区域 =====

  Widget _buildTapZones() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionTitle('点击区域', Icons.touch_app_outlined),
        _tapZoneRow('左侧区域', _config.leftAction, (a) {
          _config.leftAction = a;
          _commit();
        }),
        _tapZoneRow('中间区域', _config.centerAction, (a) {
          _config.centerAction = a;
          _commit();
        }),
        _tapZoneRow('右侧区域', _config.rightAction, (a) {
          _config.rightAction = a;
          _commit();
        }),
      ],
    );
  }

  Widget _tapZoneRow(String label, TapAction current, ValueChanged<TapAction> onPick) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          SizedBox(width: 72, child: Text(label, style: Theme.of(context).textTheme.bodyMedium)),
          Expanded(
            child: DropdownButton<TapAction>(
              value: current,
              isExpanded: true,
              onChanged: (a) {
                if (a != null) onPick(a);
              },
              items: [
                for (final a in TapAction.values)
                  DropdownMenuItem(value: a, child: Text(a.label)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ===== 段落间距 =====

  Widget _buildParagraphSpacing() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionTitle('段落间距', Icons.format_line_spacing_outlined),
        Row(
          children: [
            Text('小', style: Theme.of(context).textTheme.bodySmall),
            Expanded(
              child: Slider(
                value: _config.paragraphSpacing,
                min: 0,
                max: 48,
                divisions: 16,
                label: _config.paragraphSpacing.toStringAsFixed(0),
                onChanged: (v) {
                  _config.paragraphSpacing = v;
                  _commit();
                },
              ),
            ),
            Text('大', style: Theme.of(context).textTheme.bodySmall),
            SizedBox(
              width: 48,
              child: Text(
                '${_config.paragraphSpacing.toStringAsFixed(0)}px',
                textAlign: TextAlign.end,
                style: Theme.of(context).textTheme.labelMedium,
              ),
            ),
          ],
        ),
      ],
    );
  }

  // ===== 字体与排版（对标原版 TextFontStyleDialog + ReadBookConfig） =====

  Widget _buildTypography() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionTitle('字体与排版', Icons.text_fields),
        // 字体选择：跳转字体管理页，返回后触发阅读器重新加载字体
        ListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.font_download_outlined, size: 20),
          title: const Text('阅读字体'),
          subtitle: Text(_fontLabel),
          trailing: const Icon(Icons.chevron_right),
          onTap: () async {
            await Navigator.pushNamed(context, AppRoutes.fonts);
            if (!mounted) return;
            await _loadFontLabel();
            // 通知阅读器重建内容区（ReaderPageView.didUpdateWidget 重读字体）
            widget.onChanged?.call(_config.copy());
          },
        ),
        // 字距调节（对标原版 ReadBookConfig.letterSpacing）
        Row(
          children: [
            Text('字距', style: Theme.of(context).textTheme.bodyMedium),
            Expanded(
              child: Slider(
                value: _config.letterSpacing,
                min: 0,
                max: 5,
                divisions: 25,
                label: _config.letterSpacing.toStringAsFixed(1),
                onChanged: (v) {
                  _config.letterSpacing = v;
                  _commit();
                },
              ),
            ),
            SizedBox(
              width: 48,
              child: Text(
                _config.letterSpacing.toStringAsFixed(1),
                textAlign: TextAlign.end,
                style: Theme.of(context).textTheme.labelMedium,
              ),
            ),
          ],
        ),
        // 首行缩进（对标原版 paragraphIndent）
        SwitchListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          title: const Text('首行缩进'),
          subtitle: const Text('段落首行缩进两个字符'),
          value: _config.paragraphIndent,
          onChanged: (v) {
            _config.paragraphIndent = v;
            _commit();
          },
        ),
      ],
    );
  }

  // ===== 页面边距（对标原版 ReadStyleDialog 的四向 padding 调节） =====

  // [UI-fix v2.0.3 | 2026-08-06] 页面边距四向可调，接入分页与渲染 — Qoder
  Widget _buildPageMargins() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionTitle('页面边距', Icons.crop_free),
        _marginSlider('顶部', Icons.arrow_upward,
            _config.pageMarginTop, (v) {
          _config.pageMarginTop = v;
          _commit();
        }),
        _marginSlider('底部', Icons.arrow_downward,
            _config.pageMarginBottom, (v) {
          _config.pageMarginBottom = v;
          _commit();
        }),
        _marginSlider('左侧', Icons.arrow_back,
            _config.pageMarginLeft, (v) {
          _config.pageMarginLeft = v;
          _commit();
        }),
        _marginSlider('右侧', Icons.arrow_forward,
            _config.pageMarginRight, (v) {
          _config.pageMarginRight = v;
          _commit();
        }),
      ],
    );
  }

  Widget _marginSlider(String label, IconData icon, double value,
      ValueChanged<double> onChanged) {
    return Row(
      children: [
        Icon(icon, size: 16,
            color: Theme.of(context).colorScheme.onSurfaceVariant),
        const SizedBox(width: 6),
        SizedBox(
          width: 36,
          child: Text(label, style: Theme.of(context).textTheme.bodyMedium),
        ),
        Expanded(
          child: Slider(
            value: value,
            min: 0,
            max: 80,
            divisions: 40,
            label: value.toStringAsFixed(0),
            onChanged: onChanged,
          ),
        ),
        SizedBox(
          width: 44,
          child: Text(
            '${value.toStringAsFixed(0)}px',
            textAlign: TextAlign.end,
            style: Theme.of(context).textTheme.labelMedium,
          ),
        ),
      ],
    );
  }

  // ===== 更多配置（对标原版 MoreConfigDialog） =====

  Widget _buildMoreConfig() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionTitle('更多配置', Icons.tune_outlined),
        // 简繁转换（接 Rust 繁简转换 FFI，对标原版 chineseConvertType）
        Row(
          children: [
            Text('简繁转换', style: Theme.of(context).textTheme.bodyMedium),
            const SizedBox(width: 12),
            Expanded(
              child: SegmentedButton<int>(
                segments: const [
                  ButtonSegment(value: 0, label: Text('不转换')),
                  ButtonSegment(value: 1, label: Text('繁→简')),
                  ButtonSegment(value: 2, label: Text('简→繁')),
                ],
                selected: {_convertType},
                onSelectionChanged: (sel) async {
                  final type = sel.first;
                  setState(() => _convertType = type);
                  try {
                    await ref.read(bookApiProvider).setChineseConvertType(type);
                    // 转换类型变更后重新加载当前章正文
                    if (mounted) {
                      unawaited(
                        ref
                            .read(readerNotifierProvider.notifier)
                            .reloadChapterContent(),
                      );
                    }
                  } catch (e) {
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('简繁转换设置失败: $e')),
                      );
                    }
                  }
                },
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        // 两端对齐（对标原版 MoreConfig textFullJustify）
        SwitchListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          title: const Text('两端对齐'),
          subtitle: const Text('正文行尾对齐（末行除外）'),
          value: _config.textFullJustify,
          onChanged: (v) {
            _config.textFullJustify = v;
            _commit();
          },
        ),
        // [UI-fix v2.0.3 | 2026-08-08] MoreConfig 第①批无平台依赖项：
        // 按原版 pref_config_read.xml 项序与文案补齐，每项真实生效
        // （对标 MoreConfigDialog.onSharedPreferenceChanged 事件语义）— Qoder
        // 屏幕方向（原版第 1 项 screenOrientation）
        _moreRow('屏幕方向', _orientationLabel(_config.screenOrientation), () {
          _showChoiceDialog<int>(
            title: '屏幕方向',
            current: _config.screenOrientation,
            options: const {
              0: '跟随系统',
              1: '竖屏',
              2: '横屏',
              3: '自动(传感器)',
              4: '反向竖屏',
              5: '反向横屏',
            },
            onPick: (v) {
              _config.screenOrientation = v;
              _commit();
            },
          );
        }),
        // 保持亮屏（原版第 2 项 keep_light；平台限制诚实标注：项目未引入
        // wakelock 依赖（不改 pubspec），设置仅持久化，待平台能力接入后生效，
        // 与 audio_screen 的 audioWakeLock 标注一致）
        _moreRow('保持亮屏', _keepLightLabel(_config.keepLight), () {
          _showChoiceDialog<int>(
            title: '保持亮屏',
            current: _config.keepLight,
            options: const {
              0: '默认',
              60: '1 分钟',
              300: '5 分钟',
              600: '10 分钟',
              -1: '常亮',
            },
            onPick: (v) {
              _config.keepLight = v;
              _commit();
            },
          );
        }),
        // 隐藏状态栏（原版第 3 项：SystemUiMode 移除顶部 overlay）
        SwitchListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          title: const Text('隐藏状态栏'),
          subtitle: const Text('阅读时隐藏系统状态栏'),
          value: _config.hideStatusBar,
          onChanged: (v) {
            _config.hideStatusBar = v;
            _commit();
          },
        ),
        // 隐藏导航栏（原版第 4 项：SystemUiMode 移除底部 overlay）
        SwitchListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          title: const Text('隐藏导航栏'),
          subtitle: const Text('阅读时隐藏系统导航栏'),
          value: _config.hideNavigationBar,
          onChanged: (v) {
            _config.hideNavigationBar = v;
            _commit();
          },
        ),
        // 进度条行为（原版第 8 项 progressBarBehavior：调章内页/调章节）
        _moreRow('进度条行为',
            _config.progressBarBehavior == 'page' ? '调章内页' : '调章节', () {
          _showChoiceDialog<String>(
            title: '进度条行为',
            current: _config.progressBarBehavior,
            options: const {
              'page': '调章内页',
              'chapter': '调章节',
            },
            onPick: (v) {
              _config.progressBarBehavior = v;
              _commit();
            },
          );
        }),
        // 自动换源（原版 autoChangeSource：章节加载失败自动切换书源）
        SwitchListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          title: const Text('自动换源'),
          subtitle: const Text('章节加载失败时自动切换书源'),
          value: _config.autoChangeSource,
          onChanged: (v) {
            _config.autoChangeSource = v;
            _commit();
          },
        ),
        // 长按选择文本（原版 selectText：长按正文选区面板启停）
        SwitchListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          title: const Text('长按选择文本'),
          subtitle: const Text('长按正文段落弹出选择面板'),
          value: _config.selectText,
          onChanged: (v) {
            _config.selectText = v;
            _commit();
          },
        ),
        // 显示亮度控件（原版 showBrightnessView：底栏亮度行显隐）
        SwitchListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          title: const Text('显示亮度控件'),
          subtitle: const Text('底栏显示亮度调节滑条'),
          value: _config.showBrightnessView,
          onChanged: (v) {
            _config.showBrightnessView = v;
            _commit();
          },
        ),
        // 滚动翻页无动画（原版 noAnimScrollPage：程序化翻页去除动画）
        SwitchListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          title: const Text('滚动翻页无动画'),
          subtitle: const Text('点击/自动翻页直接切换不带动画'),
          value: _config.noAnimScrollPage,
          onChanged: (v) {
            _config.noAnimScrollPage = v;
            _commit();
          },
        ),
        // 显示标题附加区（原版 showReadTitleAddition：顶栏书名后追加章名）
        SwitchListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          title: const Text('显示标题附加区'),
          subtitle: const Text('顶栏书名后显示当前章名'),
          value: _config.showReadTitleAddition,
          onChanged: (v) {
            _config.showReadTitleAddition = v;
            _commit();
          },
        ),
        // 工具栏跟随页面（原版 readBarStyleFollowPage：顶/底栏背景与文字色
        // 跟随当前阅读页配色，对标 ReadMenu immersiveMenu）
        SwitchListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          title: const Text('工具栏跟随页面'),
          subtitle: const Text('顶/底栏配色跟随阅读页背景'),
          value: _config.readBarStyleFollowPage,
          onChanged: (v) {
            _config.readBarStyleFollowPage = v;
            _commit();
          },
        ),
        // TODO(留批次): 音量键翻页/鼠标滚轮翻页（平台按键事件，第②批）、
        // 双页横向/中文排版/避头尾等排版引擎增强项 — Qoder
      ],
    );
  }

  // ===== MoreConfig 第①批辅助构建方法 =====

  String _orientationLabel(int v) {
    const labels = ['跟随系统', '竖屏', '横屏', '自动(传感器)', '反向竖屏', '反向横屏'];
    if (v < 0 || v >= labels.length) return '跟随系统';
    return labels[v];
  }

  String _keepLightLabel(int v) {
    switch (v) {
      case 60:
        return '1 分钟';
      case 300:
        return '5 分钟';
      case 600:
        return '10 分钟';
      case -1:
        return '常亮';
      default:
        return '默认';
    }
  }

  /// 列表选择行（当前值 + 点击弹出单选对话框）
  Widget _moreRow(String title, String current, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(
          children: [
            Expanded(
              child: Text(title, style: Theme.of(context).textTheme.bodyMedium),
            ),
            Text(current,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: Theme.of(context).colorScheme.primary,
                    )),
            const SizedBox(width: 4),
            Icon(Icons.arrow_drop_down,
                size: 20,
                color: Theme.of(context).colorScheme.onSurfaceVariant),
          ],
        ),
      ),
    );
  }

  /// 单选对话框（对标原版 ListPreference 弹层选择交互）
  void _showChoiceDialog<T>({
    required String title,
    required T current,
    required Map<T, String> options,
    required ValueChanged<T> onPick,
  }) {
    showDialog<void>(
      context: context,
      builder: (dialogContext) => SimpleDialog(
        title: Text(title),
        children: [
          for (final entry in options.entries)
            RadioListTile<T>(
              title: Text(entry.value),
              value: entry.key,
              groupValue: current,
              onChanged: (v) {
                Navigator.pop(dialogContext);
                if (v != null) onPick(v);
              },
            ),
        ],
      ),
    );
  }

  // ===== 亮度控制 =====

  Widget _buildBrightnessControl() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionTitle('亮度控制', Icons.brightness_6_outlined),
        FutureBuilder<bool>(
          future: SystemBrightness.isSupported(),
          builder: (context, snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return const Center(child: CircularProgressIndicator());
            }
            
            final supported = snapshot.data ?? false;
            if (!supported) {
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text('此设备不支持亮度调节',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant)),
              );
            }

            return FutureBuilder<bool>(
              future: SystemBrightness.isAutoBrightness(),
              builder: (context, autoSnapshot) {
                if (autoSnapshot.connectionState != ConnectionState.done) {
                  return const Center(child: CircularProgressIndicator());
                }

                final isAuto = autoSnapshot.data ?? false;

                return Column(
                  children: [
                    SwitchListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      title: const Text('自动亮度'),
                      subtitle: const Text('根据环境光自动调节'),
                      value: isAuto,
                      onChanged: (v) async {
                        await SystemBrightness.setAutoBrightness(v);
                        setState(() {});
                      },
                    ),
                    if (!isAuto) ...[
                      const SizedBox(height: 8),
                      FutureBuilder<double>(
                        future: SystemBrightness.getBrightness(),
                        builder: (context, brightnessSnapshot) {
                          if (brightnessSnapshot.connectionState != ConnectionState.done) {
                            return const Center(child: CircularProgressIndicator());
                          }

                          final brightness = brightnessSnapshot.data ?? 0.5;

                          return Row(
                            children: [
                              Icon(Icons.brightness_low, size: 20,
                                  color: Theme.of(context).colorScheme.onSurfaceVariant),
                              Expanded(
                                child: Slider(
                                  value: brightness,
                                  min: 0.0,
                                  max: 1.0,
                                  divisions: 20,
                                  label: '${(brightness * 100).round()}%',
                                  onChanged: (v) async {
                                    await SystemBrightness.setBrightness(v);
                                    setState(() {});
                                  },
                                ),
                              ),
                              Icon(Icons.brightness_high, size: 20,
                                  color: Theme.of(context).colorScheme.onSurfaceVariant),
                              SizedBox(
                                width: 48,
                                child: Text(
                                  '${(brightness * 100).round()}%',
                                  textAlign: TextAlign.end,
                                  style: Theme.of(context).textTheme.labelMedium,
                                ),
                              ),
                            ],
                          );
                        },
                      ),
                    ],
                  ],
                );
              },
            );
          },
        ),
      ],
    );
  }

  // ===== 状态栏提示栏 =====

  Widget _buildStatusBar() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionTitle('状态栏提示栏', Icons.info_outline),
        // 实时预览
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.6),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            children: [
              if (_config.showBattery) ...[
                const Icon(Icons.battery_std, size: 14),
                const SizedBox(width: 4),
              ],
              if (_config.showTime) ...[
                Text(_nowText(), style: Theme.of(context).textTheme.labelSmall),
                const SizedBox(width: 8),
              ],
              const Spacer(),
              if (_config.showChapterName)
                Flexible(
                  child: Text('第一章 · 起始',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.labelSmall),
                ),
              if (_config.showProgress) ...[
                const SizedBox(width: 8),
                Text('42.0%', style: Theme.of(context).textTheme.labelSmall),
              ],
            ],
          ),
        ),
        const SizedBox(height: 4),
        _statusToggle('显示电量', Icons.battery_std, _config.showBattery, (v) {
          _config.showBattery = v;
          _commit();
        }),
        _statusToggle('显示时间', Icons.access_time, _config.showTime, (v) {
          _config.showTime = v;
          _commit();
        }),
        _statusToggle('显示进度', Icons.pie_chart_outline, _config.showProgress, (v) {
          _config.showProgress = v;
          _commit();
        }),
        _statusToggle('显示章节名', Icons.bookmark_outline, _config.showChapterName, (v) {
          _config.showChapterName = v;
          _commit();
        }),
      ],
    );
  }

  Widget _statusToggle(String label, IconData icon, bool value, ValueChanged<bool> onChanged) {
    return CheckboxListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      secondary: Icon(icon, size: 20),
      title: Text(label),
      value: value,
      onChanged: (v) => onChanged(v ?? false),
    );
  }

  String _nowText() {
    final now = DateTime.now();
    final h = now.hour.toString().padLeft(2, '0');
    final m = now.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }
}
