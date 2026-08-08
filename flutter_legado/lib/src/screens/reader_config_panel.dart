import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
  // [UI-fix v2.0.4 | 2026-08-08] 字距语义升级为 em（-0.5~1.0，对标原版
  // dsbTextLetterSpacing (it-50)/100，渲染时乘以字号转 px）；首行缩进由
  // bool 升级为 int 档位（0-3 字符，对标原版 tvTextIndent 缩进选择），
  // 旧 bool 值兼容读取：true→2、false→0 — Qoder
  double letterSpacing;
  int paragraphIndent;
  bool textFullJustify;

  // [UI-fix v2.0.4 | 2026-08-08] 界面面板（对标原版 ReadStyleDialog）新增：
  // 文字字重（textBold：0中/1粗/2细，对标 TextFontWeightConverter）、
  // 共用布局（shareLayout：原版语义为日间/夜间配置共用布局参数，桌面端
  // 暂无日夜双配置体系，仅持久化）、自定义文字颜色（长按背景圆圈弹出的
  // 自定义配色，ARGB 存储，0=跟随背景自动） — Qoder
  int textBold;
  bool shareLayout;
  int customTextColor;

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

  // [UI-fix v2.0.4 | 2026-08-08] MoreConfig 第②批（键名逐项对齐原版
  // pref_config_read.xml，平台受限项仅持久化并在 UI 中诚实标注）— Qoder

  /// 音量键翻页（对标原版 volumeKeyPage；桌面端无音量键，仅 Android 生效）
  bool volumeKeyPage;

  /// 朗读时音量键翻页（对标原版 volumeKeyPageOnPlay；仅 Android 生效）
  bool volumeKeyPageOnPlay;

  /// 鼠标滚轮翻页（对标原版 mouseWheelPage，桌面端真实生效）
  bool mouseWheelPage;

  /// 双页模式（0全局单页/1全局双页/2横屏双页/3平板或横屏双页，
  /// 对标原版 doubleHorizontalPage；桌面端双页渲染暂未接入，仅持久化）
  int doubleHorizontalPage;

  /// 使用自定义中文分行（对标原版 useZhLayout；本项目排版引擎已内置
  /// ZhLayout 中文分行，此开关仅持久化）
  bool useZhLayout;

  /// 段首标点悬挂（对标原版 hangingPunctuation；排版引擎悬挂规则暂未
  /// 按此开关切换，仅持久化）
  bool hangingPunctuation;

  /// 滑动翻页阈值（px，0=系统默认值，对标原版 pageTouchSlop）
  int pageTouchSlop;

  /// 边缘点击阈值（px，左右边缘多少距离不触发点击，对标原版 pageTouchClick）
  int pageTouchClick;

  /// 扩展到刘海（正文延伸到刘海区域，对标原版 readBodyToLh；仅 Android 生效）
  bool readBodyToLh;

  /// 填充刘海区域（对标原版 paddingDisplayCutouts；仅 Android 生效）
  bool paddingDisplayCutouts;

  ReaderAdvancedConfig({
    this.autoPageTurn = false,
    this.autoPageTurnInterval = 10,
    this.autoPageTurnForward = true,
    this.leftAction = TapAction.prevPage,
    this.centerAction = TapAction.toggleControls,
    this.rightAction = TapAction.nextPage,
    this.paragraphSpacing = 12,
    this.letterSpacing = 0,
    this.paragraphIndent = 2,
    this.textFullJustify = true,
    this.textBold = 0,
    this.shareLayout = false,
    this.customTextColor = 0,
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
    this.volumeKeyPage = true,
    this.volumeKeyPageOnPlay = false,
    this.mouseWheelPage = true,
    this.doubleHorizontalPage = 0,
    this.useZhLayout = false,
    this.hangingPunctuation = false,
    this.pageTouchSlop = 0,
    this.pageTouchClick = 0,
    this.readBodyToLh = true,
    this.paddingDisplayCutouts = false,
  });

  /// 从持久化存储加载
  static Future<ReaderAdvancedConfig> load() async {
    final prefs = await SharedPreferences.getInstance();
    TapAction tap(String key, TapAction def) {
      final i = prefs.getInt('$_prefix$key');
      if (i == null || i < 0 || i >= TapAction.values.length) return def;
      return TapAction.values[i];
    }

    // [UI-fix v2.0.4 | 2026-08-08] 字距旧值一次性迁移：旧版以 px 存储
    // （0~5，UI 25 档），若仅按 raw>1.0 判断会漏掉 0<raw≤1.0 的旧 px
    // 值（如 0.5px 会被当作 0.5em，渲染后放大一个数量级）。首次读取
    // 若无迁移标志，则将存量值一律按 px 语义 ÷18（默认字号）换算为
    // em 并写回 + 置标志；标志存在后直接按 em 读取，重复启动不再
    // 二次缩放（幂等）；save() 同步置标志防止新写入的 em 值被误
    // 迁移 — Qoder
    const migratedKey = '${_prefix}letter_spacing_migrated';
    if (!(prefs.getBool(migratedKey) ?? false)) {
      final legacyPx = prefs.getDouble('${_prefix}letter_spacing');
      if (legacyPx != null) {
        final em = (legacyPx / 18.0).clamp(-0.5, 1.0);
        await prefs.setDouble('${_prefix}letter_spacing', em.toDouble());
      }
      await prefs.setBool(migratedKey, true);
    }
    double letterSpacingEm() {
      final raw = prefs.getDouble('${_prefix}letter_spacing') ?? 0;
      return raw.clamp(-0.5, 1.0);
    }

    // [UI-fix v2.0.4 | 2026-08-08] 缩进档位兼容：新 int 键缺失时读取
    // 旧 bool 键（true→2 字符 / false→0），默认 2 字符 — Qoder
    int indentChars() {
      final v = prefs.getInt('${_prefix}paragraph_indent_chars');
      if (v != null) return v.clamp(0, 3);
      final legacy = prefs.getBool('${_prefix}paragraph_indent');
      if (legacy == null) return 2;
      return legacy ? 2 : 0;
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
      letterSpacing: letterSpacingEm(),
      paragraphIndent: indentChars(),
      textFullJustify: prefs.getBool('${_prefix}text_full_justify') ?? true,
      textBold: (prefs.getInt('textBold') ?? 0).clamp(0, 2),
      shareLayout: prefs.getBool('shareLayout') ?? false,
      customTextColor: prefs.getInt('${_prefix}custom_text_color') ?? 0,
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
      // [UI-fix v2.0.4 | 2026-08-08] 第②批 MoreConfig 项读取（键名=原版键，
      // 默认值对齐 pref_config_read.xml android:defaultValue）— Qoder
      volumeKeyPage: prefs.getBool('volumeKeyPage') ?? true,
      volumeKeyPageOnPlay: prefs.getBool('volumeKeyPageOnPlay') ?? false,
      mouseWheelPage: prefs.getBool('mouseWheelPage') ?? true,
      doubleHorizontalPage:
          (prefs.getInt('doubleHorizontalPage') ?? 0).clamp(0, 3),
      useZhLayout: prefs.getBool('useZhLayout') ?? false,
      hangingPunctuation: prefs.getBool('hangingPunctuation') ?? false,
      pageTouchSlop: (prefs.getInt('pageTouchSlop') ?? 0).clamp(0, 9999),
      pageTouchClick: (prefs.getInt('pageTouchClick') ?? 0).clamp(0, 399),
      readBodyToLh: prefs.getBool('readBodyToLh') ?? true,
      paddingDisplayCutouts: prefs.getBool('paddingDisplayCutouts') ?? false,
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
    // [UI-fix v2.0.4 | 2026-08-08] 写入即为 em 语义，同步置迁移标志，
    // 避免 save 先于 load 时新值被误当旧 px 二次换算 — Qoder
    await prefs.setBool('${_prefix}letter_spacing_migrated', true);
    // [UI-fix v2.0.4 | 2026-08-08] 缩进档位写新 int 键（旧 bool 键保留不再更新）— Qoder
    await prefs.setInt('${_prefix}paragraph_indent_chars', paragraphIndent);
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
    // [UI-fix v2.0.4 | 2026-08-08] 界面面板 + 第②批 MoreConfig 项持久化
    // （textBold/shareLayout 及第②批键名=原版键）— Qoder
    await prefs.setInt('textBold', textBold);
    await prefs.setBool('shareLayout', shareLayout);
    await prefs.setInt('${_prefix}custom_text_color', customTextColor);
    await prefs.setBool('volumeKeyPage', volumeKeyPage);
    await prefs.setBool('volumeKeyPageOnPlay', volumeKeyPageOnPlay);
    await prefs.setBool('mouseWheelPage', mouseWheelPage);
    await prefs.setInt('doubleHorizontalPage', doubleHorizontalPage);
    await prefs.setBool('useZhLayout', useZhLayout);
    await prefs.setBool('hangingPunctuation', hangingPunctuation);
    await prefs.setInt('pageTouchSlop', pageTouchSlop);
    await prefs.setInt('pageTouchClick', pageTouchClick);
    await prefs.setBool('readBodyToLh', readBodyToLh);
    await prefs.setBool('paddingDisplayCutouts', paddingDisplayCutouts);
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
        textBold: textBold,
        shareLayout: shareLayout,
        customTextColor: customTextColor,
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
        volumeKeyPage: volumeKeyPage,
        volumeKeyPageOnPlay: volumeKeyPageOnPlay,
        mouseWheelPage: mouseWheelPage,
        doubleHorizontalPage: doubleHorizontalPage,
        useZhLayout: useZhLayout,
        hangingPunctuation: hangingPunctuation,
        pageTouchSlop: pageTouchSlop,
        pageTouchClick: pageTouchClick,
        readBodyToLh: readBodyToLh,
        paddingDisplayCutouts: paddingDisplayCutouts,
      );
}

// [UI-fix v2.0.4 | 2026-08-08] 高级配置共享 Provider：界面 Sheet
// （reader_settings_sheet）与本面板的修改统一推送到此，reader_screen
// 经 watch 同步 _advConfig（Sheet 调用点位于 reader_screen 禁改区，
// 无法注入回调，借共享状态打通两条修改路径）— Qoder
class ReaderAdvConfigNotifier extends Notifier<ReaderAdvancedConfig?> {
  @override
  ReaderAdvancedConfig? build() {
    // 异步自加载持久化配置；若 UI 已先行推送则不覆盖
    Future.microtask(() async {
      final cfg = await ReaderAdvancedConfig.load();
      state ??= cfg;
    });
    return null;
  }

  /// 推送最新配置（调用方负责持久化 save()）
  void apply(ReaderAdvancedConfig config) => state = config;
}

/// 阅读器高级配置共享 Provider（null 表示尚未完成首次加载）
final readerAdvConfigProvider =
    NotifierProvider<ReaderAdvConfigNotifier, ReaderAdvancedConfig?>(
  ReaderAdvConfigNotifier.new,
);

/// 面板可单独展示的区块（界面 Sheet 的「边距/信息」按钮对标原版
/// ReadStyleDialog 的 showPaddingConfig / TipConfigDialog 独立弹层）
enum ReaderConfigSection { all, margins, statusBar }

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

  // [UI-fix v2.0.4 | 2026-08-08] 区块过滤：界面 Sheet 的「边距/信息」
  // 按钮仅展示对应区块（对标原版独立弹层）— Qoder
  final ReaderConfigSection section;

  const ReaderConfigPanel({
    super.key,
    required this.config,
    this.onChanged,
    this.section = ReaderConfigSection.all,
  });

  /// 便捷入口：弹出配置面板
  static Future<void> show(
    BuildContext context, {
    required ReaderAdvancedConfig config,
    ValueChanged<ReaderAdvancedConfig>? onChanged,
    ReaderConfigSection section = ReaderConfigSection.all,
  }) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => DraggableScrollableSheet(
        expand: false,
        // 单区块展示时降低初始高度（内容更短）
        initialChildSize: section == ReaderConfigSection.all ? 0.75 : 0.5,
        minChildSize: 0.4,
        maxChildSize: 0.92,
        builder: (_, scrollController) => SingleChildScrollView(
          controller: scrollController,
          child: ReaderConfigPanel(
            config: config,
            onChanged: onChanged,
            section: section,
          ),
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
    // [UI-fix v2.0.4 | 2026-08-08] 同步推送共享 Provider（界面 Sheet /
    // reader_screen 经 watch 实时感知面板修改）— Qoder
    ref.read(readerAdvConfigProvider.notifier).apply(_config.copy());
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    // [UI-fix v2.0.4 | 2026-08-08] 区块过滤模式：仅渲染指定区块 — Qoder
    final List<Widget> children;
    switch (widget.section) {
      case ReaderConfigSection.margins:
        children = [_buildPageMargins()];
        break;
      case ReaderConfigSection.statusBar:
        children = [_buildStatusBar()];
        break;
      case ReaderConfigSection.all:
        children = [
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
        ];
        break;
    }

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
            ...children,
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
        // [UI-fix v2.0.4 | 2026-08-08] 语义升级为 em：-0.5~1.0 步长 0.02
        // （对标原版 dsbTextLetterSpacing (it-50)/100）— Qoder
        Row(
          children: [
            Text('字距', style: Theme.of(context).textTheme.bodyMedium),
            Expanded(
              child: Slider(
                value: _config.letterSpacing.clamp(-0.5, 1.0),
                min: -0.5,
                max: 1.0,
                divisions: 75,
                label: _config.letterSpacing.toStringAsFixed(2),
                onChanged: (v) {
                  _config.letterSpacing = v;
                  _commit();
                },
              ),
            ),
            SizedBox(
              width: 48,
              child: Text(
                _config.letterSpacing.toStringAsFixed(2),
                textAlign: TextAlign.end,
                style: Theme.of(context).textTheme.labelMedium,
              ),
            ),
          ],
        ),
        // 首行缩进（对标原版 tvTextIndent 缩进选择器）
        // [UI-fix v2.0.4 | 2026-08-08] bool 开关升级为 0-3 字符档位 — Qoder
        _moreRow('首行缩进', _indentLabel(_config.paragraphIndent), () {
          _showChoiceDialog<int>(
            title: '首行缩进',
            current: _config.paragraphIndent,
            options: const {
              0: '无缩进',
              1: '一字符',
              2: '二字符',
              3: '三字符',
            },
            onPick: (v) {
              _config.paragraphIndent = v;
              _commit();
            },
          );
        }),
      ],
    );
  }

  /// 缩进档位显示文案
  String _indentLabel(int v) {
    const labels = ['无缩进', '一字符', '二字符', '三字符'];
    if (v < 0 || v >= labels.length) return '二字符';
    return labels[v];
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
        // [UI-fix v2.0.4 | 2026-08-08] MoreConfig 第②批：按原版
        // pref_config_read.xml 项序与文案补齐，平台受限项以副标题
        // 灰字诚实标注（不引入新依赖）— Qoder
        // 扩展到刘海（原版 readBodyToLh；仅 Android 生效）
        SwitchListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          title: const Text('扩展到刘海'),
          subtitle: const Text('正文延伸到刘海区域（仅 Android 生效）'),
          value: _config.readBodyToLh,
          onChanged: (v) {
            _config.readBodyToLh = v;
            _commit();
          },
        ),
        // 填充刘海区域（原版 paddingDisplayCutouts；仅 Android 生效）
        SwitchListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          title: const Text('填充刘海区域'),
          subtitle: const Text('页面边距避开刘海区域（仅 Android 生效）'),
          value: _config.paddingDisplayCutouts,
          onChanged: (v) {
            _config.paddingDisplayCutouts = v;
            _commit();
          },
        ),
        // 平板/横屏双页（原版 doubleHorizontalPage，4 档；桌面端双页
        // 渲染暂未接入，设置仅持久化）
        _moreRow('平板/横屏双页',
            _doublePageLabel(_config.doubleHorizontalPage), () {
          _showChoiceDialog<int>(
            title: '平板/横屏双页',
            current: _config.doubleHorizontalPage,
            options: const {
              0: '全局单页',
              1: '全局双页',
              2: '横屏双页',
              3: '平板/横屏双页',
            },
            onPick: (v) {
              _config.doubleHorizontalPage = v;
              _commit();
            },
          );
        }),
        // 使用自定义中文分行（原版 useZhLayout；本项目排版引擎已内置
        // ZhLayout 中文分行，开关仅持久化）
        SwitchListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          title: const Text('使用自定义中文分行'),
          subtitle: const Text('排版引擎已内置中文分行，开关仅持久化'),
          value: _config.useZhLayout,
          onChanged: (v) {
            _config.useZhLayout = v;
            _commit();
          },
        ),
        // 段首标点悬挂（原版 hangingPunctuation；排版引擎悬挂规则暂未
        // 按此开关切换，仅持久化）
        SwitchListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          title: const Text('段首标点悬挂'),
          subtitle: const Text('段首引号等标点悬挂于缩进内，使正文首字与其他段落对齐'),
          value: _config.hangingPunctuation,
          onChanged: (v) {
            _config.hangingPunctuation = v;
            _commit();
          },
        ),
        // 鼠标滚轮翻页（原版 mouseWheelPage；桌面端真实生效）
        SwitchListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          title: const Text('鼠标滚轮翻页'),
          subtitle: const Text('分页模式下滚轮上下滚动翻页'),
          value: _config.mouseWheelPage,
          onChanged: (v) {
            _config.mouseWheelPage = v;
            _commit();
          },
        ),
        // 音量键翻页（原版 volumeKeyPage；桌面端无音量键事件）
        SwitchListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          title: const Text('音量键翻页'),
          subtitle: const Text('仅 Android 生效'),
          value: _config.volumeKeyPage,
          onChanged: (v) {
            _config.volumeKeyPage = v;
            _commit();
          },
        ),
        // 朗读时音量键翻页（原版 volumeKeyPageOnPlay；仅 Android 生效）
        SwitchListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          title: const Text('朗读时音量键翻页'),
          subtitle: const Text('仅 Android 生效'),
          value: _config.volumeKeyPageOnPlay,
          onChanged: (v) {
            _config.volumeKeyPageOnPlay = v;
            _commit();
          },
        ),
        // 滑动翻页阈值（原版 pageTouchSlop：NumberPicker 0-9999，
        // 0=系统默认值；桌面端手势阈值暂未接入，仅持久化）
        _moreRow('滑动翻页阈值',
            _config.pageTouchSlop == 0 ? '系统默认' : '${_config.pageTouchSlop}px',
            () {
          _showNumberDialog(
            title: '滑动翻页阈值（0 = 系统默认值）',
            current: _config.pageTouchSlop,
            max: 9999,
            onPick: (v) {
              _config.pageTouchSlop = v;
              _commit();
            },
          );
        }),
        // 边缘点击阈值（原版 pageTouchClick：NumberPicker 0-399，
        // 左右边缘多少距离不触发点击；桌面端仅持久化）
        _moreRow('边缘点击阈值', '${_config.pageTouchClick}px', () {
          _showNumberDialog(
            title: '边缘点击阈值',
            current: _config.pageTouchClick,
            max: 399,
            onPick: (v) {
              _config.pageTouchClick = v;
              _commit();
            },
          );
        }),
      ],
    );
  }

  // ===== MoreConfig 第②批辅助构建方法 =====

  /// 双页模式档位显示文案（对齐原版 R.array.double_page_title）
  String _doublePageLabel(int v) {
    const labels = ['全局单页', '全局双页', '横屏双页', '平板/横屏双页'];
    if (v < 0 || v >= labels.length) return '全局单页';
    return labels[v];
  }

  /// 数值输入对话框（对标原版 NumberPickerDialog，桌面端用文本输入）
  void _showNumberDialog({
    required String title,
    required int current,
    required int max,
    required ValueChanged<int> onPick,
  }) {
    final controller = TextEditingController(text: current.toString());
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          decoration: InputDecoration(hintText: '0 ~ $max'),
          autofocus: true,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () {
              final v = int.tryParse(controller.text) ?? current;
              Navigator.pop(dialogContext);
              onPick(v.clamp(0, max));
            },
            child: const Text('确定'),
          ),
        ],
      ),
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

  /// 单选对话框（对标原版 ListPreference 弹层选择交互；
  /// [UI-fix v2.0.4 | 2026-08-08] RadioListTile 改 ListTile+勾选，
  /// 避开 groupValue/onChanged 弃用 API — Qoder）
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
            ListTile(
              title: Text(entry.value),
              trailing: current == entry.key
                  ? Icon(Icons.check,
                      color: Theme.of(dialogContext).colorScheme.primary)
                  : null,
              onTap: () {
                Navigator.pop(dialogContext);
                onPick(entry.key);
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
