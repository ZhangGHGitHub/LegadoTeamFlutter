// reader_config_panel.dart 的 part 文件（体检 §三.16 超长文件拆分）。
// ReaderAdvancedConfig 数据模型 + 共享 Notifier/Provider（顶层实体原样搬移）
part of 'reader_config_panel.dart';

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

  // [UI-fix v2.0.57 | 2026-08-14] 页眉/页脚边距（对标 ReadBookConfig
  // headerPadding*/footerPadding*）— Cursor UI
  double headerPaddingTop;
  double headerPaddingBottom;
  double headerPaddingLeft;
  double headerPaddingRight;
  double footerPaddingTop;
  double footerPaddingBottom;
  double footerPaddingLeft;
  double footerPaddingRight;
  bool showHeaderLine;
  bool showFooterLine;

  // [UI-fix v2.0.57 | 2026-08-14] 阅读提示信息（对标 TipConfigDialog /
  // ReadTipConfig）— Cursor UI
  int headerMode;
  int footerMode;
  int tipHeaderLeft;
  int tipHeaderMiddle;
  int tipHeaderRight;
  int tipFooterLeft;
  int tipFooterMiddle;
  int tipFooterRight;
  int titleMode;
  int titleSize;
  int titleTopSpacing;
  int titleBottomSpacing;

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
  /// 对标原版 doubleHorizontalPage；已接入 ReaderPageView 分页/渲染）
  int doubleHorizontalPage;

  /// 使用自定义中文分行（对标原版 useZhLayout；false=朴素按宽断行）
  bool useZhLayout;

  /// 段首标点悬挂（对标原版 hangingPunctuation；已接入排版引擎）
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
    this.headerPaddingTop = 0,
    this.headerPaddingBottom = 0,
    this.headerPaddingLeft = 16,
    this.headerPaddingRight = 16,
    this.footerPaddingTop = 6,
    this.footerPaddingBottom = 6,
    this.footerPaddingLeft = 16,
    this.footerPaddingRight = 16,
    this.showHeaderLine = false,
    this.showFooterLine = true,
    this.headerMode = 0,
    this.footerMode = 0,
    this.tipHeaderLeft = 2,
    this.tipHeaderMiddle = 0,
    this.tipHeaderRight = 3,
    this.tipFooterLeft = 1,
    this.tipFooterMiddle = 0,
    this.tipFooterRight = 6,
    this.titleMode = 0,
    this.titleSize = 0,
    this.titleTopSpacing = 0,
    this.titleBottomSpacing = 0,
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

  /// F6：布局字段前缀（对齐原版 shareConfig / durConfig）
  /// shareLayout=true → 共用；否则按日/夜分桶。
  static String layoutPrefix({required bool shareLayout, required bool isNight}) {
    if (shareLayout) return 'reader_layout_share_';
    return isNight ? 'reader_layout_night_' : 'reader_layout_day_';
  }

  /// 各区域默认边距（对标 ReadBookConfig.Config 默认值）
  static Map<PaddingRegion, Map<String, double>> regionDefaultPaddings() => {
        PaddingRegion.header: {
          'top': 0,
          'bottom': 0,
          'left': 16,
          'right': 16,
        },
        PaddingRegion.body: {
          'top': 6,
          'bottom': 6,
          'left': 16,
          'right': 16,
        },
        PaddingRegion.footer: {
          'top': 6,
          'bottom': 6,
          'left': 16,
          'right': 16,
        },
      };

  static double defaultPaddingFor(PaddingRegion region, String side) =>
      regionDefaultPaddings()[region]![side]!;

  /// 从持久化存储加载
  ///
  /// [isNight]：当前是否夜间阅读样式（决定非共用时的布局桶）；
  /// 会写入 `reader_layout_is_night` 供后续 save 缺省使用。
  static Future<ReaderAdvancedConfig> load({bool? isNight}) async {
    final prefs = await SharedPreferences.getInstance();
    final shareLayout = prefs.getBool('shareLayout') ?? false;
    final night = isNight ?? prefs.getBool('reader_layout_is_night') ?? false;
    if (isNight != null) {
      await prefs.setBool('reader_layout_is_night', isNight);
    }
    final lp = layoutPrefix(shareLayout: shareLayout, isNight: night);

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

    // F6：布局字段优先读日夜/共用桶，缺省回退 reader_adv_ 旧键（迁移）
    double layoutDouble(String key, double def) =>
        (prefs.getDouble('$lp$key') ?? prefs.getDouble('$_prefix$key') ?? def)
            .toDouble();
    int layoutInt(String key, int def) =>
        prefs.getInt('$lp$key') ?? prefs.getInt('$_prefix$key') ?? def;

    double letterSpacingEm() {
      final raw = layoutDouble('letter_spacing', 0);
      return raw.clamp(-0.5, 1.0);
    }

    // [UI-fix v2.0.4 | 2026-08-08] 缩进档位兼容：新 int 键缺失时读取
    // 旧 bool 键（true→2 字符 / false→0），默认 2 字符 — Qoder
    int indentChars() {
      final v = prefs.getInt('${lp}paragraph_indent_chars') ??
          prefs.getInt('${_prefix}paragraph_indent_chars');
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
      paragraphSpacing: layoutDouble('paragraph_spacing', 12).clamp(0.0, 48.0),
      letterSpacing: letterSpacingEm(),
      paragraphIndent: indentChars(),
      textFullJustify: prefs.getBool('${_prefix}text_full_justify') ?? true,
      textBold: (prefs.getInt('${lp}textBold') ??
              prefs.getInt('textBold') ??
              0)
          .clamp(0, 2),
      shareLayout: shareLayout,
      customTextColor: prefs.getInt('${_prefix}custom_text_color') ?? 0,
      pageMarginTop: layoutDouble('margin_top', 24).clamp(0.0, 400.0),
      pageMarginBottom: layoutDouble('margin_bottom', 24).clamp(0.0, 400.0),
      pageMarginLeft: layoutDouble('margin_left', 20).clamp(0.0, 100.0),
      pageMarginRight: layoutDouble('margin_right', 20).clamp(0.0, 100.0),
      headerPaddingTop: layoutDouble('header_padding_top', 0).clamp(0.0, 400.0),
      headerPaddingBottom:
          layoutDouble('header_padding_bottom', 0).clamp(0.0, 400.0),
      headerPaddingLeft: layoutDouble('header_padding_left', 16).clamp(0.0, 100.0),
      headerPaddingRight:
          layoutDouble('header_padding_right', 16).clamp(0.0, 100.0),
      footerPaddingTop: layoutDouble('footer_padding_top', 6).clamp(0.0, 400.0),
      footerPaddingBottom:
          layoutDouble('footer_padding_bottom', 6).clamp(0.0, 400.0),
      footerPaddingLeft: layoutDouble('footer_padding_left', 16).clamp(0.0, 100.0),
      footerPaddingRight:
          layoutDouble('footer_padding_right', 16).clamp(0.0, 100.0),
      showHeaderLine: prefs.getBool('${lp}show_header_line') ??
          prefs.getBool('showHeaderLine') ??
          false,
      showFooterLine: prefs.getBool('${lp}show_footer_line') ??
          prefs.getBool('showFooterLine') ??
          true,
      headerMode: (prefs.getInt('headerMode') ?? 0).clamp(0, 2),
      footerMode: (prefs.getInt('footerMode') ?? 0).clamp(0, 2),
      tipHeaderLeft: prefs.getInt('tipHeaderLeft') ?? 2,
      tipHeaderMiddle: prefs.getInt('tipHeaderMiddle') ?? 0,
      tipHeaderRight: prefs.getInt('tipHeaderRight') ?? 3,
      tipFooterLeft: prefs.getInt('tipFooterLeft') ?? 1,
      tipFooterMiddle: prefs.getInt('tipFooterMiddle') ?? 0,
      tipFooterRight: prefs.getInt('tipFooterRight') ?? 6,
      titleMode: (prefs.getInt('titleMode') ?? 0).clamp(0, 2),
      titleSize: (prefs.getInt('titleSize') ?? 0).clamp(0, 20),
      titleTopSpacing: (prefs.getInt('titleTopSpacing') ?? 0).clamp(0, 100),
      titleBottomSpacing: (prefs.getInt('titleBottomSpacing') ?? 0).clamp(0, 100),
      showBattery: prefs.getBool('${_prefix}show_battery') ?? true,
      showTime: prefs.getBool('${_prefix}show_time') ?? true,
      showProgress: prefs.getBool('${_prefix}show_progress') ?? true,
      showChapterName: prefs.getBool('${_prefix}show_chapter_name') ?? true,
      flipMode: FlipMode.fromIndex(
        layoutInt('flip_mode', FlipMode.slide.index),
      ),
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
  ///
  /// [isNight]：写入哪一套日夜布局桶（shareLayout=true 时忽略，写入共用桶）。
  Future<void> save({bool? isNight}) async {
    final prefs = await SharedPreferences.getInstance();
    final night = isNight ?? prefs.getBool('reader_layout_is_night') ?? false;
    if (isNight != null) {
      await prefs.setBool('reader_layout_is_night', isNight);
    }
    final lp = layoutPrefix(shareLayout: shareLayout, isNight: night);

    await prefs.setBool('${_prefix}auto_page_turn', autoPageTurn);
    await prefs.setDouble('${_prefix}auto_interval', autoPageTurnInterval);
    await prefs.setBool('${_prefix}auto_forward', autoPageTurnForward);
    await prefs.setInt('${_prefix}left_action', leftAction.index);
    await prefs.setInt('${_prefix}center_action', centerAction.index);
    await prefs.setInt('${_prefix}right_action', rightAction.index);
    // F6：布局字段写入日夜/共用桶（并对齐旧 reader_adv_ 键便于未升级路径）
    await prefs.setDouble('${lp}paragraph_spacing', paragraphSpacing);
    await prefs.setDouble('${_prefix}paragraph_spacing', paragraphSpacing);
    await prefs.setDouble('${lp}letter_spacing', letterSpacing);
    await prefs.setDouble('${_prefix}letter_spacing', letterSpacing);
    // [UI-fix v2.0.4 | 2026-08-08] 写入即为 em 语义，同步置迁移标志，
    // 避免 save 先于 load 时新值被误当旧 px 二次换算 — Qoder
    await prefs.setBool('${_prefix}letter_spacing_migrated', true);
    // [UI-fix v2.0.4 | 2026-08-08] 缩进档位写新 int 键（旧 bool 键保留不再更新）— Qoder
    await prefs.setInt('${lp}paragraph_indent_chars', paragraphIndent);
    await prefs.setInt('${_prefix}paragraph_indent_chars', paragraphIndent);
    await prefs.setBool('${_prefix}text_full_justify', textFullJustify);
    await prefs.setDouble('${lp}margin_top', pageMarginTop);
    await prefs.setDouble('${lp}margin_bottom', pageMarginBottom);
    await prefs.setDouble('${lp}margin_left', pageMarginLeft);
    await prefs.setDouble('${lp}margin_right', pageMarginRight);
    await prefs.setDouble('${_prefix}margin_top', pageMarginTop);
    await prefs.setDouble('${_prefix}margin_bottom', pageMarginBottom);
    await prefs.setDouble('${_prefix}margin_left', pageMarginLeft);
    await prefs.setDouble('${_prefix}margin_right', pageMarginRight);
    await prefs.setDouble('${lp}header_padding_top', headerPaddingTop);
    await prefs.setDouble('${lp}header_padding_bottom', headerPaddingBottom);
    await prefs.setDouble('${lp}header_padding_left', headerPaddingLeft);
    await prefs.setDouble('${lp}header_padding_right', headerPaddingRight);
    await prefs.setDouble('${lp}footer_padding_top', footerPaddingTop);
    await prefs.setDouble('${lp}footer_padding_bottom', footerPaddingBottom);
    await prefs.setDouble('${lp}footer_padding_left', footerPaddingLeft);
    await prefs.setDouble('${lp}footer_padding_right', footerPaddingRight);
    await prefs.setBool('${lp}show_header_line', showHeaderLine);
    await prefs.setBool('showHeaderLine', showHeaderLine);
    await prefs.setBool('${lp}show_footer_line', showFooterLine);
    await prefs.setBool('showFooterLine', showFooterLine);
    await prefs.setInt('headerMode', headerMode);
    await prefs.setInt('footerMode', footerMode);
    await prefs.setInt('tipHeaderLeft', tipHeaderLeft);
    await prefs.setInt('tipHeaderMiddle', tipHeaderMiddle);
    await prefs.setInt('tipHeaderRight', tipHeaderRight);
    await prefs.setInt('tipFooterLeft', tipFooterLeft);
    await prefs.setInt('tipFooterMiddle', tipFooterMiddle);
    await prefs.setInt('tipFooterRight', tipFooterRight);
    await prefs.setInt('titleMode', titleMode);
    await prefs.setInt('titleSize', titleSize);
    await prefs.setInt('titleTopSpacing', titleTopSpacing);
    await prefs.setInt('titleBottomSpacing', titleBottomSpacing);
    await prefs.setBool('${_prefix}show_battery', showBattery);
    await prefs.setBool('${_prefix}show_time', showTime);
    await prefs.setBool('${_prefix}show_progress', showProgress);
    await prefs.setBool('${_prefix}show_chapter_name', showChapterName);
    await prefs.setInt('${lp}flip_mode', flipMode.index);
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
    await prefs.setInt('${lp}textBold', textBold);
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
        headerPaddingTop: headerPaddingTop,
        headerPaddingBottom: headerPaddingBottom,
        headerPaddingLeft: headerPaddingLeft,
        headerPaddingRight: headerPaddingRight,
        footerPaddingTop: footerPaddingTop,
        footerPaddingBottom: footerPaddingBottom,
        footerPaddingLeft: footerPaddingLeft,
        footerPaddingRight: footerPaddingRight,
        showHeaderLine: showHeaderLine,
        showFooterLine: showFooterLine,
        headerMode: headerMode,
        footerMode: footerMode,
        tipHeaderLeft: tipHeaderLeft,
        tipHeaderMiddle: tipHeaderMiddle,
        tipHeaderRight: tipHeaderRight,
        tipFooterLeft: tipFooterLeft,
        tipFooterMiddle: tipFooterMiddle,
        tipFooterRight: tipFooterRight,
        titleMode: titleMode,
        titleSize: titleSize,
        titleTopSpacing: titleTopSpacing,
        titleBottomSpacing: titleBottomSpacing,
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
      // 无 BuildContext：用上次保存的日夜标志；阅读器进入时会按主题重载
      final cfg = await ReaderAdvancedConfig.load();
      state ??= cfg;
    });
    return null;
  }

  /// F6：按日夜重载布局（主题切换后调用）
  Future<void> reloadForNight(bool isNight) async {
    state = await ReaderAdvancedConfig.load(isNight: isNight);
  }

  /// 推送最新配置（调用方负责持久化 save()）
  void apply(ReaderAdvancedConfig config) => state = config;
}

/// 阅读器高级配置共享 Provider（null 表示尚未完成首次加载）
final readerAdvConfigProvider =
    NotifierProvider<ReaderAdvConfigNotifier, ReaderAdvancedConfig?>(
  ReaderAdvConfigNotifier.new,
);
