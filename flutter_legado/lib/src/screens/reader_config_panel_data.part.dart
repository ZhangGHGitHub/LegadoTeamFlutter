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

  // 点击区域映射（旧三区；批4a 起仅保留读取做一次性迁移，UI/分发改用
  // 下方九宫格字段。字段保留避免其它引用编译错误。）
  TapAction leftAction;
  TapAction centerAction;
  TapAction rightAction;

  // [批4a] 九宫格点击动作（行优先：TL/TC/TR/ML/MC/MR/BL/BC/BR）
  ReaderTapAction tapTopLeft;
  ReaderTapAction tapTopCenter;
  ReaderTapAction tapTopRight;
  ReaderTapAction tapMiddleLeft;
  ReaderTapAction tapMiddleCenter;
  ReaderTapAction tapMiddleRight;
  ReaderTapAction tapBottomLeft;
  ReaderTapAction tapBottomCenter;
  ReaderTapAction tapBottomRight;

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

  // [C3 斜体 | Qoder UI] 正文斜体（参考版行内字体面板「斜体」开关；原版无此配置，
  // 按双基准口径（原版 + 参考版）补齐）
  bool italic;
  bool shareLayout;
  int customTextColor;

  // [UI-fix v2.0.3 | 2026-08-06] 页面边距（对标原版 ReadBookConfig
  // paddingTop/paddingBottom/paddingLeft/paddingRight） — Qoder
  double pageMarginTop;
  double pageMarginBottom;
  double pageMarginLeft;
  double pageMarginRight;

  // [批33 | 边距上下联动] 正文上下边距联动（对标原版
  // ReadBookConfig.paddingTopBottomLinked，默认 false）：打开后拖动上/下
  // 任一侧，另一侧镜像同值；仅正文 Tab 生效（原版 PaddingConfigDialog
  // 的 swLockTb 仅 Region.BODY 可见）。键名取原版字段名，随 Flutter JSON
  // 备份 appPrefs 透传 — 全栈工程师
  //
  // [批33b | 存储位] 属**全局键** `paddingTopBottomLinked`：不写
  // `layoutPrefix` 的日夜/共用布局桶（边距数值分桶、联动开关不分桶），
  // 切主题不会因桶切换丢失/篡改该开关（对齐原版 AppConfig 全局字段）。
  bool paddingTopBottomLinked;

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

  /// 标题字体（空=跟随正文字体，对齐原版 ReadBookConfig.titleFont）
  String titleFont;

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
  ///
  /// [批1b-1] 已由 [readBrightnessMode] 三档取代：本布尔键 load 迁移后
  /// 不再消费、save 不再写（保留旧值仅作迁移来源），消费点见
  /// reader_bottom_bar / reader_menu_panel。
  bool showBrightnessView;

  /// 亮度条模式三档（0=不显示 / 1=横条（底栏亮度行）/ 2=竖条（贴边），
  /// 键名与档位对齐参考版 PreferKey.readBrightnessMode + ReadSettings
  /// 默认 "0"）— [批1b-1] 全栈工程师
  String readBrightnessMode;

  /// 竖条位置（0=左侧 / 1=右侧，键名对齐参考版
  /// PreferKey.readBrightnessControlPosition，默认 "1"=右；仅模式=2 时生效）
  /// — [批1b-1] 全栈工程师
  String readBrightnessVwPos;

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

  /// 按键长按翻页（对标原版 keyPageOnLongPress，默认 false）
  ///
  /// 语义对齐原版 ReadBookActivity.volumeKeyPage → handleKeyPage：
  /// - true：每个 keydown 都翻页（含长按 repeat），即长按连续翻页；
  /// - false：长按 repeat 直接忽略；普通按键同方向相邻两次翻页至少间隔
  ///   600ms（leading 节流：第一次立即翻，窗口内后续按键不再翻）。
  bool keyPageOnLongPress;

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

  // [批1a 阅读设置页 | 2026-10-31] 新增三项接线偏好（键名对齐参考版
  // PreferKey，默认值对齐参考版 ReadSettingsRepository compatDsValue）—
  // 全栈工程师

  /// 翻页成功振动（对标参考版 sliderVibrator；原版无此键，默认 false）
  bool sliderVibrator;

  /// 选词振动（对标参考版 selectVibrator；原版无此键，默认 false）
  bool selectVibrator;

  /// 禁用返回键（对标原版 disableReturnKey / 参考版 ReadBookRouteScreen：
  /// 开启且阅读菜单未展开时，系统返回键不退出阅读器；菜单展开时先关菜单）
  bool disableReturnKey;

  /// 无目录规则时每章字数（键名对齐参考版 PreferKey.maxLengthWithNoToc，
  /// 默认 3000、范围 3000..100000 对齐参考版 ReadConfigViewModel coerceIn；
  /// Rust 解析侧经 caches `config:maxLengthWithNoToc` 消费——本批 1b-3
  /// 落地「本地 TXT 无目录规则时按长度分章」）— [批1b-3] 全栈工程师
  int maxLengthWithNoToc;

  /// 正文图片点击方式（键名对齐原版 PreferKey.clickImgWay，五档
  /// "0"=默认行为 / "1"=预览 / "2"=兼容旧版 / "3"=关闭 / "4"=双击；
  /// 参考版默认 "2"）。档位常量/决策见 utils/click_img_way.dart —
  /// [批1b-2b] 全栈工程师
  String clickImgWay;

  /// [批4b] 自定义翻页键（逗号分隔 keyCode；空=未设置）
  String prevKeyCodes;
  String nextKeyCodes;

  ReaderAdvancedConfig({
    this.autoPageTurn = false,
    this.autoPageTurnInterval = 10,
    this.autoPageTurnForward = true,
    this.leftAction = TapAction.prevPage,
    this.centerAction = TapAction.toggleControls,
    this.rightAction = TapAction.nextPage,
    this.tapTopLeft = ReaderTapAction.previousPage,
    this.tapTopCenter = ReaderTapAction.previousPage,
    this.tapTopRight = ReaderTapAction.nextPage,
    this.tapMiddleLeft = ReaderTapAction.previousPage,
    this.tapMiddleCenter = ReaderTapAction.menu,
    this.tapMiddleRight = ReaderTapAction.nextPage,
    this.tapBottomLeft = ReaderTapAction.previousPage,
    this.tapBottomCenter = ReaderTapAction.nextPage,
    this.tapBottomRight = ReaderTapAction.nextPage,
    this.paragraphSpacing = 2,
    this.letterSpacing = 0.1,
    this.paragraphIndent = 2,
    this.textFullJustify = true,
    this.textBold = 0,
    this.italic = false,
    this.shareLayout = false,
    this.customTextColor = 0,
    this.pageMarginTop = 24,
    this.pageMarginBottom = 24,
    this.pageMarginLeft = 20,
    this.pageMarginRight = 20,
    this.paddingTopBottomLinked = false,
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
    // [C2 R5] 底栏左侧语义对齐参考：参考底栏左显示书名（斗罗大陆），
    // 我方原为章节名（截断）。tipFooterLeft 由 1(章节名) 改 7(书名)。
    this.tipFooterLeft = 7,
    this.tipFooterMiddle = 0,
    this.tipFooterRight = 6,
    this.titleMode = 0,
    this.titleSize = 0,
    this.titleTopSpacing = 0,
    this.titleBottomSpacing = 0,
    this.titleFont = '',
    // [C2 R4] 顶部「时间+章节名+进度」状态行默认关闭（参考该态无此信息行；
    // 头部信息开关默认关，用户可在「阅读提示信息」面板手动开启）
    this.showBattery = false,
    this.showTime = false,
    this.showProgress = false,
    this.showChapterName = false,
    this.flipMode = FlipMode.slide,
    this.screenOrientation = 0,
    this.keepLight = 0,
    this.hideStatusBar = false,
    this.hideNavigationBar = false,
    this.progressBarBehavior = 'page',
    this.noAnimScrollPage = false,
    this.autoChangeSource = true,
    this.selectText = true,
    // [PARITY C2 M5] 参考阅读器菜单该态未见亮度条：默认关闭菜单内亮度行，
    // 亮度控件改为用户按需开启（设置开关保留），对齐参考紧凑浮层形态。
    this.showBrightnessView = false,
    // [批1b-1] 亮度条模式/位置默认对齐参考版 ReadSettings（"0"=不显示 /
    // "1"=右）；旧布尔键 showBrightnessView 迁移在 load 中一次性完成
    this.readBrightnessMode = '0',
    this.readBrightnessVwPos = '1',
    this.showReadTitleAddition = true,
    this.readBarStyleFollowPage = false,
    this.volumeKeyPage = true,
    this.volumeKeyPageOnPlay = false,
    // 原版 AppConfig.keyPageOnLongPress 默认 false（pref_config_read.xml
    // android:defaultValue=false）
    this.keyPageOnLongPress = false,
    this.mouseWheelPage = true,
    this.doubleHorizontalPage = 0,
    this.useZhLayout = false,
    this.hangingPunctuation = false,
    this.pageTouchSlop = 0,
    this.pageTouchClick = 0,
    this.readBodyToLh = true,
    this.paddingDisplayCutouts = false,
    // [批1a] 参考版默认值（ReadSettingsRepository compatDsValue 均 false）
    this.sliderVibrator = false,
    this.selectVibrator = false,
    this.disableReturnKey = false,
    // [批1b-3] 参考版默认 3000（ReadSettings.maxLengthWithNoToc）
    this.maxLengthWithNoToc = 3000,
    // [批1b-2b] 参考版默认 "2"=兼容旧版（原版 pref default 为 "0"，
    // 按任务裁决取参考版默认）
    this.clickImgWay = kDefaultClickImgWay,
    this.prevKeyCodes = '',
    this.nextKeyCodes = '',
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

    // [批4a] 九宫格读取；键不存在回落参考默认
    ReaderTapAction newTap(String key, ReaderTapAction def) {
      final code = prefs.getInt(key);
      return code == null ? def : ReaderTapAction.fromCode(code);
    }

    final legacyLeft = tap('left_action', TapAction.prevPage);
    final legacyCenter = tap('center_action', TapAction.toggleControls);
    final legacyRight = tap('right_action', TapAction.nextPage);
    const gridKeys = [
      PrefKeys.clickActionTopLeft,
      PrefKeys.clickActionTopCenter,
      PrefKeys.clickActionTopRight,
      PrefKeys.clickActionMiddleLeft,
      PrefKeys.clickActionMiddleCenter,
      PrefKeys.clickActionMiddleRight,
      PrefKeys.clickActionBottomLeft,
      PrefKeys.clickActionBottomCenter,
      PrefKeys.clickActionBottomRight,
    ];
    final hasAnyGridKey = gridKeys.any((k) => prefs.getInt(k) != null);
    final hasAnyLegacyKey = [
      'left_action',
      'center_action',
      'right_action',
    ].any((k) => prefs.getInt('$_prefix$k') != null);
    // 仅当确实存在旧三区持久化值时才迁移；新装（旧键也缺失）走九宫格
    // 默认值，避免旧默认 center=toggleControls 污染新默认 TC/BC=上一页。
    if (!hasAnyGridKey &&
        hasAnyLegacyKey &&
        prefs.getBool(PrefKeys.clickActionMigratedV2) != true) {
      // 旧三区 → 九宫格整列映射（left→*L / center→*C / right→*R），写标记
      // 保证幂等；旧 none/prev/next/toggleControls/openCatalog →
      // -1/2/1/0/10。
      int legacyCode(TapAction action) {
        return switch (action) {
          TapAction.none => -1,
          TapAction.prevPage => 2,
          TapAction.nextPage => 1,
          TapAction.toggleControls => 0,
          TapAction.openCatalog => 10,
        };
      }

      final leftCode = legacyCode(legacyLeft);
      final centerCode = legacyCode(legacyCenter);
      final rightCode = legacyCode(legacyRight);
      await prefs.setInt(PrefKeys.clickActionTopLeft, leftCode);
      await prefs.setInt(PrefKeys.clickActionMiddleLeft, leftCode);
      await prefs.setInt(PrefKeys.clickActionBottomLeft, leftCode);
      await prefs.setInt(PrefKeys.clickActionTopCenter, centerCode);
      await prefs.setInt(PrefKeys.clickActionMiddleCenter, centerCode);
      await prefs.setInt(PrefKeys.clickActionBottomCenter, centerCode);
      await prefs.setInt(PrefKeys.clickActionTopRight, rightCode);
      await prefs.setInt(PrefKeys.clickActionMiddleRight, rightCode);
      await prefs.setInt(PrefKeys.clickActionBottomRight, rightCode);
      await prefs.setBool(PrefKeys.clickActionMigratedV2, true);
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

    // [N4 偏好迁移 | 2.0.271 | 子代理] 一次性默认值迁移（幂等）：
    // C2 批（2.0.262）将两项默认值改新——R4 顶部「时间/章节名/进度」状态行
    // 四开关由默认开改默认关；R5 底栏左侧 tipFooterLeft 由 1(章节名) 改
    // 7(书名)。已安装设备上存有旧值时新默认永不生效（需手动改设置）。
    // 迁移语义：
    //   1. 仅当迁移标记 settingsMigrated_v271 缺失时执行（一次性）；
    //   2. 存量值 == 旧默认 → 改写为新默认（视为"从未手动修改"）：
    //      状态行四键 reader_adv_show_* 存量 true（旧默认开）→ 置 false；
    //      tipFooterLeft 存量 1（旧默认=章节名）→ 置 7（书名）；
    //   3. 存量值 != 旧默认（用户曾手动改过，如状态行已手动关、
    //      tipFooterLeft 已选其他项）→ 不动，尊重显式选择；
    //   4. 键缺失（未存过）→ load 缺省即新默认，无需写入。
    // 迁移完成后置标记，后续启动/读取不再覆盖用户手动修改。
    const c2DefaultsMigratedKey = 'settingsMigrated_v271';
    if (!(prefs.getBool(c2DefaultsMigratedKey) ?? false)) {
      const statusRowKeys = <String>[
        '${_prefix}show_battery',
        '${_prefix}show_time',
        '${_prefix}show_progress',
        '${_prefix}show_chapter_name',
      ];
      for (final key in statusRowKeys) {
        // 旧默认=true（开）；存量 true 视为未手动修改 → 改新默认 false（关）
        if (prefs.getBool(key) == true) {
          await prefs.setBool(key, false);
        }
      }
      // tipFooterLeft 旧默认=1（章节名）；存量 1 视为未手动修改 → 改 7（书名）
      if (prefs.getInt('tipFooterLeft') == 1) {
        await prefs.setInt('tipFooterLeft', 7);
      }
      await prefs.setBool(c2DefaultsMigratedKey, true);
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

    // [批1b-1] 亮度条旧布尔键一次性迁移（幂等，对齐参考版 Backup.kt:266-275
    // 恢复迁移口径：legacy true→"1"（横条）/false→"0"（不显示）；位置键
    // 同法 readMenuBrightnessVwPos left/right → 0/1）。
    // [批1b-1 审查回修 P3-6] 历史派生键 readMenuBrightnessVertical=true
    // （旧竖条开关，参考版 showBrightnessView="2" 变体）优先映射 mode '2'
    // 竖条——该键为参考版三档语义的旧派生表达，优先级高于 showBrightnessView
    // 的两态口径。迁移标志落地后旧键不再读写（可逆：不清旧值，模式往返
    // 经新键表达）— 全栈工程师
    const brightnessModeMigratedKey = 'brightness_mode_migrated_v1b1';
    if (!(prefs.getBool(brightnessModeMigratedKey) ?? false)) {
      final legacyVertical =
          prefs.getBool(PrefKeys.readMenuBrightnessVertical);
      if (legacyVertical == true &&
          prefs.getString('readBrightnessMode') == null) {
        await prefs.setString('readBrightnessMode', '2');
      } else {
        final legacyMode = prefs.getBool('showBrightnessView');
        if (legacyMode != null &&
            prefs.getString('readBrightnessMode') == null) {
          await prefs.setString(
              'readBrightnessMode', legacyMode ? '1' : '0');
        }
      }
      final legacyPos = prefs.getString(PrefKeys.readMenuBrightnessPos);
      if (legacyPos != null && prefs.getString('readBrightnessVwPos') == null) {
        await prefs.setString('readBrightnessVwPos',
            legacyPos == 'left' ? '0' : '1');
      }
      await prefs.setBool(brightnessModeMigratedKey, true);
    }

    return ReaderAdvancedConfig(
      autoPageTurn: prefs.getBool('${_prefix}auto_page_turn') ?? false,
      autoPageTurnInterval: (prefs.getDouble('${_prefix}auto_interval') ?? 10)
          .clamp(3.0, 120.0),
      autoPageTurnForward: prefs.getBool('${_prefix}auto_forward') ?? true,
      leftAction: legacyLeft,
      centerAction: legacyCenter,
      rightAction: legacyRight,
      tapTopLeft: newTap(
        PrefKeys.clickActionTopLeft,
        ReaderTapAction.previousPage,
      ),
      tapTopCenter: newTap(
        PrefKeys.clickActionTopCenter,
        ReaderTapAction.previousPage,
      ),
      tapTopRight: newTap(
        PrefKeys.clickActionTopRight,
        ReaderTapAction.nextPage,
      ),
      tapMiddleLeft: newTap(
        PrefKeys.clickActionMiddleLeft,
        ReaderTapAction.previousPage,
      ),
      tapMiddleCenter: newTap(
        PrefKeys.clickActionMiddleCenter,
        ReaderTapAction.menu,
      ),
      tapMiddleRight: newTap(
        PrefKeys.clickActionMiddleRight,
        ReaderTapAction.nextPage,
      ),
      tapBottomLeft: newTap(
        PrefKeys.clickActionBottomLeft,
        ReaderTapAction.previousPage,
      ),
      tapBottomCenter: newTap(
        PrefKeys.clickActionBottomCenter,
        ReaderTapAction.nextPage,
      ),
      tapBottomRight: newTap(
        PrefKeys.clickActionBottomRight,
        ReaderTapAction.nextPage,
      ),
      paragraphSpacing: layoutDouble('paragraph_spacing', 2).clamp(0.0, 48.0),
      letterSpacing: letterSpacingEm(),
      paragraphIndent: indentChars(),
      textFullJustify: prefs.getBool('${_prefix}text_full_justify') ?? true,
      textBold: (prefs.getInt('${lp}textBold') ??
              prefs.getInt('textBold') ??
              0)
          .clamp(0, 2),
      // [C3 斜体 | Qoder UI] 斜体（参考版行内面板开关；双基准补齐）
      italic: prefs.getBool('${_prefix}italic') ?? false,
      shareLayout: shareLayout,
      customTextColor: prefs.getInt('${_prefix}custom_text_color') ?? 0,
      pageMarginTop: layoutDouble('margin_top', 24).clamp(0.0, 400.0),
      pageMarginBottom: layoutDouble('margin_bottom', 24).clamp(0.0, 400.0),
      pageMarginLeft: layoutDouble('margin_left', 20).clamp(0.0, 100.0),
      pageMarginRight: layoutDouble('margin_right', 20).clamp(0.0, 100.0),
      // [批33 | 边距上下联动] 原版字段名直取（全局开关，不分日夜桶）
      paddingTopBottomLinked:
          prefs.getBool('paddingTopBottomLinked') ?? false,
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
      // [C2 R5] load 缺省对齐构造器默认（7=书名）
      tipFooterLeft: prefs.getInt('tipFooterLeft') ?? 7,
      tipFooterMiddle: prefs.getInt('tipFooterMiddle') ?? 0,
      tipFooterRight: prefs.getInt('tipFooterRight') ?? 6,
      titleMode: (prefs.getInt('titleMode') ?? 0).clamp(0, 2),
      titleSize: (prefs.getInt('titleSize') ?? 0).clamp(0, 20),
      titleTopSpacing: (prefs.getInt('titleTopSpacing') ?? 0).clamp(0, 100),
      titleBottomSpacing: (prefs.getInt('titleBottomSpacing') ?? 0).clamp(0, 100),
      titleFont: prefs.getString('titleFont') ?? '',
      // [C2 R4] 状态行四开关 load 缺省对齐构造器默认（关闭），参考该态无此信息行
      showBattery: prefs.getBool('${_prefix}show_battery') ?? false,
      showTime: prefs.getBool('${_prefix}show_time') ?? false,
      showProgress: prefs.getBool('${_prefix}show_progress') ?? false,
      showChapterName: prefs.getBool('${_prefix}show_chapter_name') ?? false,
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
      // [PARITY C2 M5] load 缺省对齐构造器默认（关闭），参考菜单该态无亮度条。
      // [批1b-1] 旧布尔键停止消费：显隐语义由 readBrightnessMode 三档承载；
      // 本字段保留模型兼容（弹层旧行读取处随本批移除）。
      showBrightnessView: prefs.getBool('showBrightnessView') ?? false,
      readBrightnessMode:
          _clampBrightnessMode(prefs.getString('readBrightnessMode')),
      readBrightnessVwPos:
          _clampBrightnessPos(prefs.getString('readBrightnessVwPos')),
      showReadTitleAddition: prefs.getBool('showReadTitleAddition') ?? true,
      readBarStyleFollowPage: prefs.getBool('readBarStyleFollowPage') ?? false,
      // [UI-fix v2.0.4 | 2026-08-08] 第②批 MoreConfig 项读取（键名=原版键，
      // 默认值对齐 pref_config_read.xml android:defaultValue）— Qoder
      volumeKeyPage: prefs.getBool('volumeKeyPage') ?? true,
      volumeKeyPageOnPlay: prefs.getBool('volumeKeyPageOnPlay') ?? false,
      keyPageOnLongPress: prefs.getBool('keyPageOnLongPress') ?? false,
      mouseWheelPage: prefs.getBool('mouseWheelPage') ?? true,
      doubleHorizontalPage:
          (prefs.getInt('doubleHorizontalPage') ?? 0).clamp(0, 3),
      useZhLayout: prefs.getBool('useZhLayout') ?? false,
      hangingPunctuation: prefs.getBool('hangingPunctuation') ?? false,
      pageTouchSlop: (prefs.getInt('pageTouchSlop') ?? 0).clamp(0, 9999),
      pageTouchClick: (prefs.getInt('pageTouchClick') ?? 0).clamp(0, 399),
      readBodyToLh: prefs.getBool('readBodyToLh') ?? true,
      paddingDisplayCutouts: prefs.getBool('paddingDisplayCutouts') ?? false,
      // [批1a] 新三项读取（键名=参考版 PreferKey，默认对齐参考版）
      sliderVibrator: prefs.getBool('sliderVibrator') ?? false,
      selectVibrator: prefs.getBool('selectVibrator') ?? false,
      disableReturnKey: prefs.getBool('disableReturnKey') ?? false,
      // [批1b-3] 读取并夹逼（越界/非法回落 3000..100000 区间，对齐参考版
      // ReadConfigViewModel coerceIn；缺省 3000）
      maxLengthWithNoToc:
          (prefs.getInt('maxLengthWithNoToc') ?? 3000).clamp(3000, 100000),
      // [批1b-2b] 正文图片点击方式（键名=原版 PreferKey.clickImgWay；
      // 缺省/非法回落参考版默认 "2"=兼容旧版）
      clickImgWay: clampClickImgWay(prefs.getString('clickImgWay')),
      prevKeyCodes: PageKeyCodes.normalize(
        prefs.getString(PrefKeys.prevKeyCodes),
      ),
      nextKeyCodes: PageKeyCodes.normalize(
        prefs.getString(PrefKeys.nextKeyCodes),
      ),
    );
  }

  /// [批1b-1] 亮度条模式档位钳制（合法值 "0"/"1"/"2"，缺省/非法回落
  /// 参考版默认 "0"=不显示）
  static String _clampBrightnessMode(String? raw) =>
      const {'0', '1', '2'}.contains(raw) ? raw! : '0';

  /// [批1b-1] 竖条位置档位钳制（合法值 "0"=左/"1"=右，缺省/非法回落
  /// 参考版默认 "1"=右）
  static String _clampBrightnessPos(String? raw) =>
      const {'0', '1'}.contains(raw) ? raw! : '1';

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
    // [批4a] 九宫格为唯一写入源；旧三区键停止更新（仅迁移读取）
    await prefs.setInt(PrefKeys.clickActionTopLeft, tapTopLeft.code);
    await prefs.setInt(PrefKeys.clickActionTopCenter, tapTopCenter.code);
    await prefs.setInt(PrefKeys.clickActionTopRight, tapTopRight.code);
    await prefs.setInt(PrefKeys.clickActionMiddleLeft, tapMiddleLeft.code);
    await prefs.setInt(PrefKeys.clickActionMiddleCenter, tapMiddleCenter.code);
    await prefs.setInt(PrefKeys.clickActionMiddleRight, tapMiddleRight.code);
    await prefs.setInt(PrefKeys.clickActionBottomLeft, tapBottomLeft.code);
    await prefs.setInt(PrefKeys.clickActionBottomCenter, tapBottomCenter.code);
    await prefs.setInt(PrefKeys.clickActionBottomRight, tapBottomRight.code);
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
    // [批33 | 边距上下联动] 全局开关（原版字段名，不进日夜桶）
    await prefs.setBool('paddingTopBottomLinked', paddingTopBottomLinked);
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
    await prefs.setString('titleFont', titleFont);
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
    // [批1b-1] 旧布尔键 showBrightnessView 停止写入（迁移来源值保留，
    // 迁移标志存在后不再读取）；亮度条显隐由三档键承载
    await prefs.setString('readBrightnessMode', readBrightnessMode);
    await prefs.setString('readBrightnessVwPos', readBrightnessVwPos);
    await prefs.setBool('${_prefix}italic', italic);
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
    await prefs.setBool('keyPageOnLongPress', keyPageOnLongPress);
    await prefs.setBool('mouseWheelPage', mouseWheelPage);
    await prefs.setInt('doubleHorizontalPage', doubleHorizontalPage);
    await prefs.setBool('useZhLayout', useZhLayout);
    await prefs.setBool('hangingPunctuation', hangingPunctuation);
    await prefs.setInt('pageTouchSlop', pageTouchSlop);
    await prefs.setInt('pageTouchClick', pageTouchClick);
    await prefs.setBool('readBodyToLh', readBodyToLh);
    await prefs.setBool('paddingDisplayCutouts', paddingDisplayCutouts);
    // [批1a] 新三项持久化（键名=参考版 PreferKey）
    await prefs.setBool('sliderVibrator', sliderVibrator);
    await prefs.setBool('selectVibrator', selectVibrator);
    await prefs.setBool('disableReturnKey', disableReturnKey);
    // [批1b-3] 无目录规则时每章字数（键名=参考版 PreferKey；
    // SharedPreferences 镜像 + caches `config:` 真源由设置页接线写 Rust）
    await prefs.setInt('maxLengthWithNoToc', maxLengthWithNoToc);
    // [批1b-2b] 正文图片点击方式（键名=原版 PreferKey.clickImgWay，
    // 写入前钳制，避免非法值落盘）
    await prefs.setString('clickImgWay', clampClickImgWay(clickImgWay));
    await prefs.setString(PrefKeys.prevKeyCodes, prevKeyCodes);
    await prefs.setString(PrefKeys.nextKeyCodes, nextKeyCodes);
  }

  /// 应用阅读主题快照中的排版字段（批38）
  ///
  /// 只覆盖主题快照包含的字段（边距/字距/缩进/段距/字重/斜体/文字色/
  /// 标题字体），其余阅读偏好（自动翻页/点击区域/状态栏/翻页模式等）
  /// 保持用户当前设置不动。返回新实例，持久化由调用方 `save()` 负责。
  ReaderAdvancedConfig withThemeStyle(ReaderThemeStyle style) {
    final cfg = copy();
    cfg.letterSpacing = style.letterSpacing;
    cfg.paragraphIndent = style.paragraphIndent;
    cfg.paragraphSpacing = style.paragraphSpacing;
    cfg.textBold = style.textBold;
    cfg.italic = style.italic;
    // 0 = 跟随背景自动，与界面自定义配色对话框的「自动」同一语义
    cfg.customTextColor = style.textColor;
    cfg.pageMarginTop = style.marginTop;
    cfg.pageMarginBottom = style.marginBottom;
    cfg.pageMarginLeft = style.marginLeft;
    cfg.pageMarginRight = style.marginRight;
    cfg.titleFont = style.titleFont;
    return cfg;
  }

  /// 九宫格动作（行优先）
  List<ReaderTapAction> get tapActions => [
    tapTopLeft,
    tapTopCenter,
    tapTopRight,
    tapMiddleLeft,
    tapMiddleCenter,
    tapMiddleRight,
    tapBottomLeft,
    tapBottomCenter,
    tapBottomRight,
  ];

  ReaderTapAction tapActionAt(int index) {
    switch (index) {
      case 0:
        return tapTopLeft;
      case 1:
        return tapTopCenter;
      case 2:
        return tapTopRight;
      case 3:
        return tapMiddleLeft;
      case 4:
        return tapMiddleCenter;
      case 5:
        return tapMiddleRight;
      case 6:
        return tapBottomLeft;
      case 7:
        return tapBottomCenter;
      case 8:
        return tapBottomRight;
      default:
        return ReaderTapAction.none;
    }
  }

  void setTapActionAt(int index, ReaderTapAction action) {
    switch (index) {
      case 0:
        tapTopLeft = action;
      case 1:
        tapTopCenter = action;
      case 2:
        tapTopRight = action;
      case 3:
        tapMiddleLeft = action;
      case 4:
        tapMiddleCenter = action;
      case 5:
        tapMiddleRight = action;
      case 6:
        tapBottomLeft = action;
      case 7:
        tapBottomCenter = action;
      case 8:
        tapBottomRight = action;
    }
  }

  ReaderAdvancedConfig copy() => ReaderAdvancedConfig(
        autoPageTurn: autoPageTurn,
        autoPageTurnInterval: autoPageTurnInterval,
        autoPageTurnForward: autoPageTurnForward,
        leftAction: leftAction,
        centerAction: centerAction,
        rightAction: rightAction,
        tapTopLeft: tapTopLeft,
        tapTopCenter: tapTopCenter,
        tapTopRight: tapTopRight,
        tapMiddleLeft: tapMiddleLeft,
        tapMiddleCenter: tapMiddleCenter,
        tapMiddleRight: tapMiddleRight,
        tapBottomLeft: tapBottomLeft,
        tapBottomCenter: tapBottomCenter,
        tapBottomRight: tapBottomRight,
        paragraphSpacing: paragraphSpacing,
        letterSpacing: letterSpacing,
        paragraphIndent: paragraphIndent,
        textFullJustify: textFullJustify,
        textBold: textBold,
        italic: italic,
        shareLayout: shareLayout,
        customTextColor: customTextColor,
        pageMarginTop: pageMarginTop,
        pageMarginBottom: pageMarginBottom,
        pageMarginLeft: pageMarginLeft,
        pageMarginRight: pageMarginRight,
        paddingTopBottomLinked: paddingTopBottomLinked,
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
        titleFont: titleFont,
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
        readBrightnessMode: readBrightnessMode,
        readBrightnessVwPos: readBrightnessVwPos,
        showReadTitleAddition: showReadTitleAddition,
        readBarStyleFollowPage: readBarStyleFollowPage,
        volumeKeyPage: volumeKeyPage,
        volumeKeyPageOnPlay: volumeKeyPageOnPlay,
        keyPageOnLongPress: keyPageOnLongPress,
        mouseWheelPage: mouseWheelPage,
        doubleHorizontalPage: doubleHorizontalPage,
        useZhLayout: useZhLayout,
        hangingPunctuation: hangingPunctuation,
        pageTouchSlop: pageTouchSlop,
        pageTouchClick: pageTouchClick,
        readBodyToLh: readBodyToLh,
        paddingDisplayCutouts: paddingDisplayCutouts,
        sliderVibrator: sliderVibrator,
        selectVibrator: selectVibrator,
        disableReturnKey: disableReturnKey,
        maxLengthWithNoToc: maxLengthWithNoToc,
        clickImgWay: clickImgWay,
        prevKeyCodes: prevKeyCodes,
        nextKeyCodes: nextKeyCodes,
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
