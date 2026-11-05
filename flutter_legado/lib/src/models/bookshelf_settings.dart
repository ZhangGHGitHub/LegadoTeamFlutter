// 书架布局配置模型（设置批6a-1）
//
// 字段名 / 默认值逐字对齐参考版 `BookshelfSettings.kt:5-57`
// （`legado-with-MD3`），持久化键名对齐 `PreferKey.kt`（真实偏好键，
// 非常量名）。文件夹模式（6a-2）的 8 个字段本期只在模型中保留默认值，
// 配置面板不渲染；组内排序覆盖（`BookGroup.bookSort`）另立项。
//
// 编写：全栈工程师（设置批6a-1） ｜ 2026-11-06
import 'dart:math' as math;

/// 书架布局配置（不可变）
class BookshelfSettings {
  // ===== 持久化键（逐字对齐参考版 PreferKey 的真实字符串值）=====
  static const keyBookGroupStyle = 'bookGroupStyle';
  static const keyHideEmptyGroups = 'hideEmptyGroups';
  static const keyBookshelfSort = 'bookshelfSort';
  static const keyBookshelfSortOrder = 'bookshelfSortOrder';
  static const keyShowUnread = 'showUnread';
  static const keyShowUnreadNew = 'showUnreadNew';
  static const keyShowTip = 'showTip';
  static const keyShowBookCount = 'showBookCount';
  static const keyShowLastUpdateTime = 'showLastUpdateTime';
  static const keyShowBookIntro = 'showBookIntro';
  static const keyBookshelfShowIntro = 'bookshelfShowIntro';
  static const keyBookshelfShowTag = 'bookshelfShowTag';
  static const keyBookshelfShowLatestChapter = 'bookshelfShowLatestChapter';
  static const keyBookshelfIntroMaxLines = 'bookshelfIntroMaxLines';
  static const keyShowWaitUpCount = 'showWaitUpCount';
  static const keyShowBookshelfFastScroller = 'showBookshelfFastScroller';
  static const keyShouldShowExpandButton = 'shouldShowExpandButton';
  static const keyBookshelfRefreshingLimit = 'bookshelfRefreshingLimit';
  // 参考版 portrait 键的真实值不是常量名（`bookshelfLayoutPortrait`）；
  // landscape 键沿用历史 snake 值 `bookshelf_layout_landscape`。
  static const keyBookshelfLayoutModePortrait = 'bookshelfLayoutPortrait';
  static const keyBookshelfLayoutGridPortrait =
      'bookshelfLayoutGridPortrait';
  static const keyBookshelfLayoutModeLandscape =
      'bookshelf_layout_landscape';
  static const keyBookshelfLayoutGridLandscape =
      'bookshelfLayoutGridLandscape';
  static const keyBookshelfLayoutListPortrait = 'bookshelfLayoutListPortrait';
  static const keyBookshelfLayoutListLandscape =
      'bookshelfLayoutListLandscape';
  static const keyBookshelfFolderLayoutModePortrait =
      'bookshelfFolderLayoutModePortrait';
  static const keyBookshelfFolderLayoutGridPortrait =
      'bookshelfFolderLayoutGridPortrait';
  static const keyBookshelfFolderLayoutModeLandscape =
      'bookshelfFolderLayoutModeLandscape';
  static const keyBookshelfFolderLayoutGridLandscape =
      'bookshelfFolderLayoutGridLandscape';
  static const keyBookshelfFolderLayoutListPortrait =
      'bookshelfFolderLayoutListPortrait';
  static const keyBookshelfFolderLayoutListLandscape =
      'bookshelfFolderLayoutListLandscape';
  static const keyBookshelfGridLayout = 'bookshelfGridLayout';
  static const keyBookshelfLayoutCompact = 'bookshelfLayoutCompact';
  static const keyBookshelfListCoverCenter = 'bookshelfListCoverCenter';
  static const keyBookshelfListIntroBelowContent =
      'bookshelfListIntroBelowContent';
  static const keyBookshelfShowDivider = 'bookshelfShowDivider';
  static const keyBookshelfTitleSmallFont = 'bookshelfTitleSmallFont';
  static const keyBookshelfTitleCenter = 'bookshelfTitleCenter';
  static const keyBookshelfTitleMaxLines = 'bookshelfTitleMaxLines';
  static const keyBookshelfCoverShadow = 'bookshelfCoverShadow';
  static const keyBookshelfCardColor = 'bookshelfCardColor';
  static const keyBookshelfCardColorDark = 'bookshelfCardColorDark';
  static const keyBookshelfGroupListStyle = 'bookshelfGroupListStyle';
  static const keyBookshelfGroupCoverCount = 'bookshelfGroupCoverCount';
  static const keyBookshelfListCoverWidth = 'bookshelfListCoverWidth';
  static const keyBookshelfGridCoverWidth = 'bookshelfGridCoverWidth';
  static const keyBookshelfSearchActionDirectToSearch =
      'bookshelfSearchActionDirectToSearch';
  static const keyAutoRefreshBook = 'auto_refresh';
  static const keySaveTabPosition = 'saveTabPosition';

  /// 旧版 Flutter 书架布局布尔键（true=网格 / false=列表）
  ///
  /// 仅用于一次性迁移：新键（portrait/landscape）均不存在时才读取。
  /// 迁移后保留旧键不删除（旧版本回退/第三方备份仍可读取），新代码
  /// 不再把它作为状态源。
  static const legacyLayoutKey = 'bookshelf_layout';

  /// 参考版旧 Android 键（`PrefKey.bookshelfLayout`），迁移时一并识别
  static const legacyAndroidLayoutKey = 'bookshelfLayout';

  /// 属于「忽略书架布局」恢复项的全部新键（备份恢复过滤用）
  ///
  /// 参考版 `BackupConfig.bookshelfPrefKeys` 只收录一部分显示配置；
  /// 我方把本模型全部键纳入同一忽略组，语义更一致（勾选「书架布局」
  /// 时不覆盖本机任何书架展示配置）。旧布尔键另由
  /// `RestoreIgnorePrefs` 单独覆盖。
  static const prefKeys = <String>{
    keyBookGroupStyle,
    keyHideEmptyGroups,
    keyBookshelfSort,
    keyBookshelfSortOrder,
    keyShowUnread,
    keyShowUnreadNew,
    keyShowTip,
    keyShowBookCount,
    keyShowLastUpdateTime,
    keyShowBookIntro,
    keyBookshelfShowIntro,
    keyBookshelfShowTag,
    keyBookshelfShowLatestChapter,
    keyBookshelfIntroMaxLines,
    keyShowWaitUpCount,
    keyShowBookshelfFastScroller,
    keyShouldShowExpandButton,
    keyBookshelfRefreshingLimit,
    keyBookshelfLayoutModePortrait,
    keyBookshelfLayoutGridPortrait,
    keyBookshelfLayoutModeLandscape,
    keyBookshelfLayoutGridLandscape,
    keyBookshelfLayoutListPortrait,
    keyBookshelfLayoutListLandscape,
    keyBookshelfFolderLayoutModePortrait,
    keyBookshelfFolderLayoutGridPortrait,
    keyBookshelfFolderLayoutModeLandscape,
    keyBookshelfFolderLayoutGridLandscape,
    keyBookshelfFolderLayoutListPortrait,
    keyBookshelfFolderLayoutListLandscape,
    keyBookshelfGridLayout,
    keyBookshelfLayoutCompact,
    keyBookshelfListCoverCenter,
    keyBookshelfListIntroBelowContent,
    keyBookshelfShowDivider,
    keyBookshelfTitleSmallFont,
    keyBookshelfTitleCenter,
    keyBookshelfTitleMaxLines,
    keyBookshelfCoverShadow,
    keyBookshelfCardColor,
    keyBookshelfCardColorDark,
    keyBookshelfGroupListStyle,
    keyBookshelfGroupCoverCount,
    keyBookshelfListCoverWidth,
    keyBookshelfGridCoverWidth,
    keyBookshelfSearchActionDirectToSearch,
    keyAutoRefreshBook,
    keySaveTabPosition,
  };

  /// 分组样式：0 = 顶部 Tab（默认），1 = 隐藏 Tab + 顶部组标题/组菜单，
  /// 2 = 文件夹（6a-2，暂不可选）
  final int bookGroupStyle;

  /// 隐藏空分组（默认开）
  final bool hideEmptyGroups;

  /// 排序模式：0 阅读时间 / 1 更新时间 / 2 书名 / 3 手动 / 4 综合 / 5 作者
  final int bookshelfSort;

  /// 排序方向：0 升序 / 1 降序（默认降序）
  final int bookshelfSortOrder;

  /// 显示未读角标
  final bool showUnread;

  /// 显示新章节角标（书源有更新）
  final bool showUnreadNew;

  /// 显示书籍类型提示（音频/漫画/本地/文件/小说）
  final bool showTip;

  /// 显示分组书籍数（文件夹模式延后，本期仅存储）
  final bool showBookCount;

  /// 显示上次更新时间（列表）
  final bool showLastUpdateTime;

  /// 列表「更多信息」总开关
  final bool showBookIntro;

  /// 显示简介（依赖「更多信息」）
  final bool bookshelfShowIntro;

  /// 显示标签
  final bool bookshelfShowTag;

  /// 显示最新章节（列表，依赖「更多信息」）
  final bool bookshelfShowLatestChapter;

  /// 简介最大行数（0 = 全部）
  final int bookshelfIntroMaxLines;

  /// 显示等待更新数量（更新全部时顶栏角标）
  final bool showWaitUpCount;

  /// 显示快速滚动条
  final bool showBookshelfFastScroller;

  /// 分组 Tab 行尾「更多分组」按钮
  final bool shouldShowExpandButton;

  /// 更新全部时的数量上限（0 = 不限制）
  final int bookshelfRefreshingLimit;

  /// 竖屏布局：0 列表 / 1 网格（默认网格）
  final int bookshelfLayoutModePortrait;

  /// 竖屏网格列数（1–15，默认 3）
  final int bookshelfLayoutGridPortrait;

  /// 横屏布局：0 列表 / 1 网格（默认网格）
  final int bookshelfLayoutModeLandscape;

  /// 横屏网格列数（1–15，默认 7）
  final int bookshelfLayoutGridLandscape;

  /// 竖屏列表列数（1–5，默认 1）
  final int bookshelfLayoutListPortrait;

  /// 横屏列表列数（1–5，默认 1）
  final int bookshelfLayoutListLandscape;

  // ===== 文件夹模式字段（6a-2 才启用；本期仅持久化默认值）=====
  final int bookshelfFolderLayoutModePortrait;
  final int bookshelfFolderLayoutGridPortrait;
  final int bookshelfFolderLayoutModeLandscape;
  final int bookshelfFolderLayoutGridLandscape;
  final int bookshelfFolderLayoutListPortrait;
  final int bookshelfFolderLayoutListLandscape;

  /// 网格样式：0 标准（封面下书名）/ 1 紧凑（书名叠封面）/ 2 仅封面
  final int bookshelfGridLayout;

  /// 列表精简详情（隐藏简介/标签/最新章节，只留书名+作者）
  final bool bookshelfLayoutCompact;

  /// 列表封面垂直居中（false = 顶部对齐）
  final bool bookshelfListCoverCenter;

  /// 简介显示在内容下方（仅列表）
  final bool bookshelfListIntroBelowContent;

  /// 列表分隔线
  final bool bookshelfShowDivider;

  /// 网格书名小字体
  final bool bookshelfTitleSmallFont;

  /// 标题居中（false = 左对齐）
  final bool bookshelfTitleCenter;

  /// 标题最大行数（1–5，默认 2）
  final int bookshelfTitleMaxLines;

  /// 封面阴影（默认关，对齐参考当前口径）
  final bool bookshelfCoverShadow;

  /// 日间卡片背景色（0 = 跟随主题）
  final int bookshelfCardColor;

  /// 夜间卡片背景色（0 = 跟随主题）
  final int bookshelfCardColorDark;

  // ===== 文件夹列表样式字段（6a-2 才启用）=====
  final int bookshelfGroupListStyle;
  final int bookshelfGroupCoverCount;

  /// 列表封面宽（40–120，默认 84）
  final int bookshelfListCoverWidth;

  /// 网格封面宽（40–150，默认 120；仅在列宽大于该值时生效）
  final int bookshelfGridCoverWidth;

  /// 搜索按钮直达搜索页（false = 书架内搜索，本批未实现，面板中禁用）
  final bool bookshelfSearchActionDirectToSearch;

  /// 自动刷新书籍（参考版字段，本批不接入 UI）
  final bool autoRefreshBook;

  /// 上次选中分组（参考版字段；我方仍沿用 `bookshelf_tab_position`）
  final int saveTabPosition;

  const BookshelfSettings({
    this.bookGroupStyle = 0,
    this.hideEmptyGroups = true,
    this.bookshelfSort = 0,
    this.bookshelfSortOrder = 1,
    this.showUnread = true,
    this.showUnreadNew = true,
    this.showTip = false,
    this.showBookCount = true,
    this.showLastUpdateTime = false,
    this.showBookIntro = false,
    this.bookshelfShowIntro = true,
    this.bookshelfShowTag = true,
    this.bookshelfShowLatestChapter = true,
    this.bookshelfIntroMaxLines = 0,
    this.showWaitUpCount = false,
    this.showBookshelfFastScroller = false,
    this.shouldShowExpandButton = false,
    this.bookshelfRefreshingLimit = 0,
    this.bookshelfLayoutModePortrait = 1,
    this.bookshelfLayoutGridPortrait = 3,
    this.bookshelfLayoutModeLandscape = 1,
    this.bookshelfLayoutGridLandscape = 7,
    this.bookshelfLayoutListPortrait = 1,
    this.bookshelfLayoutListLandscape = 1,
    this.bookshelfFolderLayoutModePortrait = 1,
    this.bookshelfFolderLayoutGridPortrait = 3,
    this.bookshelfFolderLayoutModeLandscape = 1,
    this.bookshelfFolderLayoutGridLandscape = 7,
    this.bookshelfFolderLayoutListPortrait = 1,
    this.bookshelfFolderLayoutListLandscape = 1,
    this.bookshelfGridLayout = 0,
    this.bookshelfLayoutCompact = false,
    this.bookshelfListCoverCenter = true,
    this.bookshelfListIntroBelowContent = false,
    this.bookshelfShowDivider = true,
    this.bookshelfTitleSmallFont = false,
    this.bookshelfTitleCenter = true,
    this.bookshelfTitleMaxLines = 2,
    this.bookshelfCoverShadow = false,
    this.bookshelfCardColor = 0,
    this.bookshelfCardColorDark = 0,
    this.bookshelfGroupListStyle = 0,
    this.bookshelfGroupCoverCount = 4,
    this.bookshelfListCoverWidth = 84,
    this.bookshelfGridCoverWidth = 120,
    this.bookshelfSearchActionDirectToSearch = true,
    this.autoRefreshBook = false,
    this.saveTabPosition = -1,
  });

  /// 参考版默认值（字段顺序/取值同 `BookshelfSettings.kt:5-57`）
  static const defaults = BookshelfSettings();

  BookshelfSettings copyWith({
    int? bookGroupStyle,
    bool? hideEmptyGroups,
    int? bookshelfSort,
    int? bookshelfSortOrder,
    bool? showUnread,
    bool? showUnreadNew,
    bool? showTip,
    bool? showBookCount,
    bool? showLastUpdateTime,
    bool? showBookIntro,
    bool? bookshelfShowIntro,
    bool? bookshelfShowTag,
    bool? bookshelfShowLatestChapter,
    int? bookshelfIntroMaxLines,
    bool? showWaitUpCount,
    bool? showBookshelfFastScroller,
    bool? shouldShowExpandButton,
    int? bookshelfRefreshingLimit,
    int? bookshelfLayoutModePortrait,
    int? bookshelfLayoutGridPortrait,
    int? bookshelfLayoutModeLandscape,
    int? bookshelfLayoutGridLandscape,
    int? bookshelfLayoutListPortrait,
    int? bookshelfLayoutListLandscape,
    int? bookshelfFolderLayoutModePortrait,
    int? bookshelfFolderLayoutGridPortrait,
    int? bookshelfFolderLayoutModeLandscape,
    int? bookshelfFolderLayoutGridLandscape,
    int? bookshelfFolderLayoutListPortrait,
    int? bookshelfFolderLayoutListLandscape,
    int? bookshelfGridLayout,
    bool? bookshelfLayoutCompact,
    bool? bookshelfListCoverCenter,
    bool? bookshelfListIntroBelowContent,
    bool? bookshelfShowDivider,
    bool? bookshelfTitleSmallFont,
    bool? bookshelfTitleCenter,
    int? bookshelfTitleMaxLines,
    bool? bookshelfCoverShadow,
    int? bookshelfCardColor,
    int? bookshelfCardColorDark,
    int? bookshelfGroupListStyle,
    int? bookshelfGroupCoverCount,
    int? bookshelfListCoverWidth,
    int? bookshelfGridCoverWidth,
    bool? bookshelfSearchActionDirectToSearch,
    bool? autoRefreshBook,
    int? saveTabPosition,
  }) {
    return BookshelfSettings(
      bookGroupStyle: bookGroupStyle ?? this.bookGroupStyle,
      hideEmptyGroups: hideEmptyGroups ?? this.hideEmptyGroups,
      bookshelfSort: bookshelfSort ?? this.bookshelfSort,
      bookshelfSortOrder: bookshelfSortOrder ?? this.bookshelfSortOrder,
      showUnread: showUnread ?? this.showUnread,
      showUnreadNew: showUnreadNew ?? this.showUnreadNew,
      showTip: showTip ?? this.showTip,
      showBookCount: showBookCount ?? this.showBookCount,
      showLastUpdateTime: showLastUpdateTime ?? this.showLastUpdateTime,
      showBookIntro: showBookIntro ?? this.showBookIntro,
      bookshelfShowIntro: bookshelfShowIntro ?? this.bookshelfShowIntro,
      bookshelfShowTag: bookshelfShowTag ?? this.bookshelfShowTag,
      bookshelfShowLatestChapter:
          bookshelfShowLatestChapter ?? this.bookshelfShowLatestChapter,
      bookshelfIntroMaxLines:
          bookshelfIntroMaxLines ?? this.bookshelfIntroMaxLines,
      showWaitUpCount: showWaitUpCount ?? this.showWaitUpCount,
      showBookshelfFastScroller:
          showBookshelfFastScroller ?? this.showBookshelfFastScroller,
      shouldShowExpandButton:
          shouldShowExpandButton ?? this.shouldShowExpandButton,
      bookshelfRefreshingLimit:
          bookshelfRefreshingLimit ?? this.bookshelfRefreshingLimit,
      bookshelfLayoutModePortrait:
          bookshelfLayoutModePortrait ?? this.bookshelfLayoutModePortrait,
      bookshelfLayoutGridPortrait:
          bookshelfLayoutGridPortrait ?? this.bookshelfLayoutGridPortrait,
      bookshelfLayoutModeLandscape:
          bookshelfLayoutModeLandscape ?? this.bookshelfLayoutModeLandscape,
      bookshelfLayoutGridLandscape:
          bookshelfLayoutGridLandscape ?? this.bookshelfLayoutGridLandscape,
      bookshelfLayoutListPortrait:
          bookshelfLayoutListPortrait ?? this.bookshelfLayoutListPortrait,
      bookshelfLayoutListLandscape:
          bookshelfLayoutListLandscape ?? this.bookshelfLayoutListLandscape,
      bookshelfFolderLayoutModePortrait:
          bookshelfFolderLayoutModePortrait ??
              this.bookshelfFolderLayoutModePortrait,
      bookshelfFolderLayoutGridPortrait:
          bookshelfFolderLayoutGridPortrait ??
              this.bookshelfFolderLayoutGridPortrait,
      bookshelfFolderLayoutModeLandscape:
          bookshelfFolderLayoutModeLandscape ??
              this.bookshelfFolderLayoutModeLandscape,
      bookshelfFolderLayoutGridLandscape:
          bookshelfFolderLayoutGridLandscape ??
              this.bookshelfFolderLayoutGridLandscape,
      bookshelfFolderLayoutListPortrait:
          bookshelfFolderLayoutListPortrait ??
              this.bookshelfFolderLayoutListPortrait,
      bookshelfFolderLayoutListLandscape:
          bookshelfFolderLayoutListLandscape ??
              this.bookshelfFolderLayoutListLandscape,
      bookshelfGridLayout: bookshelfGridLayout ?? this.bookshelfGridLayout,
      bookshelfLayoutCompact:
          bookshelfLayoutCompact ?? this.bookshelfLayoutCompact,
      bookshelfListCoverCenter:
          bookshelfListCoverCenter ?? this.bookshelfListCoverCenter,
      bookshelfListIntroBelowContent:
          bookshelfListIntroBelowContent ?? this.bookshelfListIntroBelowContent,
      bookshelfShowDivider: bookshelfShowDivider ?? this.bookshelfShowDivider,
      bookshelfTitleSmallFont:
          bookshelfTitleSmallFont ?? this.bookshelfTitleSmallFont,
      bookshelfTitleCenter:
          bookshelfTitleCenter ?? this.bookshelfTitleCenter,
      bookshelfTitleMaxLines:
          bookshelfTitleMaxLines ?? this.bookshelfTitleMaxLines,
      bookshelfCoverShadow:
          bookshelfCoverShadow ?? this.bookshelfCoverShadow,
      bookshelfCardColor: bookshelfCardColor ?? this.bookshelfCardColor,
      bookshelfCardColorDark:
          bookshelfCardColorDark ?? this.bookshelfCardColorDark,
      bookshelfGroupListStyle:
          bookshelfGroupListStyle ?? this.bookshelfGroupListStyle,
      bookshelfGroupCoverCount:
          bookshelfGroupCoverCount ?? this.bookshelfGroupCoverCount,
      bookshelfListCoverWidth:
          bookshelfListCoverWidth ?? this.bookshelfListCoverWidth,
      bookshelfGridCoverWidth:
          bookshelfGridCoverWidth ?? this.bookshelfGridCoverWidth,
      bookshelfSearchActionDirectToSearch:
          bookshelfSearchActionDirectToSearch ??
              this.bookshelfSearchActionDirectToSearch,
      autoRefreshBook: autoRefreshBook ?? this.autoRefreshBook,
      saveTabPosition: saveTabPosition ?? this.saveTabPosition,
    );
  }

  /// 读取持久化映射（缺失键用默认值，越界值收敛到合法范围）
  factory BookshelfSettings.fromPrefMap(Map<String, Object?> map) {
    final d = defaults;
    int readInt(String key, int fallback) {
      final value = map[key];
      if (value is int) return value;
      if (value is num) return value.round();
      if (value is String) return int.tryParse(value) ?? fallback;
      return fallback;
    }

    bool readBool(String key, bool fallback) {
      final value = map[key];
      if (value is bool) return value;
      if (value is String) return value.toLowerCase() == 'true';
      return fallback;
    }

    return BookshelfSettings(
      bookGroupStyle: readInt(keyBookGroupStyle, d.bookGroupStyle),
      hideEmptyGroups: readBool(keyHideEmptyGroups, d.hideEmptyGroups),
      bookshelfSort: readInt(keyBookshelfSort, d.bookshelfSort),
      bookshelfSortOrder:
          readInt(keyBookshelfSortOrder, d.bookshelfSortOrder),
      showUnread: readBool(keyShowUnread, d.showUnread),
      showUnreadNew: readBool(keyShowUnreadNew, d.showUnreadNew),
      showTip: readBool(keyShowTip, d.showTip),
      showBookCount: readBool(keyShowBookCount, d.showBookCount),
      showLastUpdateTime:
          readBool(keyShowLastUpdateTime, d.showLastUpdateTime),
      showBookIntro: readBool(keyShowBookIntro, d.showBookIntro),
      bookshelfShowIntro:
          readBool(keyBookshelfShowIntro, d.bookshelfShowIntro),
      bookshelfShowTag: readBool(keyBookshelfShowTag, d.bookshelfShowTag),
      bookshelfShowLatestChapter: readBool(
          keyBookshelfShowLatestChapter, d.bookshelfShowLatestChapter),
      bookshelfIntroMaxLines:
          readInt(keyBookshelfIntroMaxLines, d.bookshelfIntroMaxLines),
      showWaitUpCount: readBool(keyShowWaitUpCount, d.showWaitUpCount),
      showBookshelfFastScroller: readBool(
          keyShowBookshelfFastScroller, d.showBookshelfFastScroller),
      shouldShowExpandButton:
          readBool(keyShouldShowExpandButton, d.shouldShowExpandButton),
      bookshelfRefreshingLimit:
          readInt(keyBookshelfRefreshingLimit, d.bookshelfRefreshingLimit),
      bookshelfLayoutModePortrait: readInt(
          keyBookshelfLayoutModePortrait, d.bookshelfLayoutModePortrait),
      bookshelfLayoutGridPortrait: readInt(
          keyBookshelfLayoutGridPortrait, d.bookshelfLayoutGridPortrait),
      bookshelfLayoutModeLandscape: readInt(
          keyBookshelfLayoutModeLandscape, d.bookshelfLayoutModeLandscape),
      bookshelfLayoutGridLandscape: readInt(
          keyBookshelfLayoutGridLandscape, d.bookshelfLayoutGridLandscape),
      bookshelfLayoutListPortrait: readInt(
          keyBookshelfLayoutListPortrait, d.bookshelfLayoutListPortrait),
      bookshelfLayoutListLandscape: readInt(
          keyBookshelfLayoutListLandscape, d.bookshelfLayoutListLandscape),
      bookshelfFolderLayoutModePortrait: readInt(
          keyBookshelfFolderLayoutModePortrait,
          d.bookshelfFolderLayoutModePortrait),
      bookshelfFolderLayoutGridPortrait: readInt(
          keyBookshelfFolderLayoutGridPortrait,
          d.bookshelfFolderLayoutGridPortrait),
      bookshelfFolderLayoutModeLandscape: readInt(
          keyBookshelfFolderLayoutModeLandscape,
          d.bookshelfFolderLayoutModeLandscape),
      bookshelfFolderLayoutGridLandscape: readInt(
          keyBookshelfFolderLayoutGridLandscape,
          d.bookshelfFolderLayoutGridLandscape),
      bookshelfFolderLayoutListPortrait: readInt(
          keyBookshelfFolderLayoutListPortrait,
          d.bookshelfFolderLayoutListPortrait),
      bookshelfFolderLayoutListLandscape: readInt(
          keyBookshelfFolderLayoutListLandscape,
          d.bookshelfFolderLayoutListLandscape),
      bookshelfGridLayout:
          readInt(keyBookshelfGridLayout, d.bookshelfGridLayout),
      bookshelfLayoutCompact:
          readBool(keyBookshelfLayoutCompact, d.bookshelfLayoutCompact),
      bookshelfListCoverCenter:
          readBool(keyBookshelfListCoverCenter, d.bookshelfListCoverCenter),
      bookshelfListIntroBelowContent: readBool(
          keyBookshelfListIntroBelowContent,
          d.bookshelfListIntroBelowContent),
      bookshelfShowDivider:
          readBool(keyBookshelfShowDivider, d.bookshelfShowDivider),
      bookshelfTitleSmallFont:
          readBool(keyBookshelfTitleSmallFont, d.bookshelfTitleSmallFont),
      bookshelfTitleCenter:
          readBool(keyBookshelfTitleCenter, d.bookshelfTitleCenter),
      bookshelfTitleMaxLines:
          readInt(keyBookshelfTitleMaxLines, d.bookshelfTitleMaxLines),
      bookshelfCoverShadow:
          readBool(keyBookshelfCoverShadow, d.bookshelfCoverShadow),
      bookshelfCardColor:
          readInt(keyBookshelfCardColor, d.bookshelfCardColor),
      bookshelfCardColorDark:
          readInt(keyBookshelfCardColorDark, d.bookshelfCardColorDark),
      bookshelfGroupListStyle:
          readInt(keyBookshelfGroupListStyle, d.bookshelfGroupListStyle),
      bookshelfGroupCoverCount:
          readInt(keyBookshelfGroupCoverCount, d.bookshelfGroupCoverCount),
      bookshelfListCoverWidth:
          readInt(keyBookshelfListCoverWidth, d.bookshelfListCoverWidth),
      bookshelfGridCoverWidth:
          readInt(keyBookshelfGridCoverWidth, d.bookshelfGridCoverWidth),
      bookshelfSearchActionDirectToSearch: readBool(
          keyBookshelfSearchActionDirectToSearch,
          d.bookshelfSearchActionDirectToSearch),
      autoRefreshBook: readBool(keyAutoRefreshBook, d.autoRefreshBook),
      saveTabPosition: readInt(keySaveTabPosition, d.saveTabPosition),
    ).normalized();
  }

  /// 持久化映射（键名逐字对齐参考版 PreferKey 真实值）
  Map<String, Object?> toPrefMap() => {
        keyBookGroupStyle: bookGroupStyle,
        keyHideEmptyGroups: hideEmptyGroups,
        keyBookshelfSort: bookshelfSort,
        keyBookshelfSortOrder: bookshelfSortOrder,
        keyShowUnread: showUnread,
        keyShowUnreadNew: showUnreadNew,
        keyShowTip: showTip,
        keyShowBookCount: showBookCount,
        keyShowLastUpdateTime: showLastUpdateTime,
        keyShowBookIntro: showBookIntro,
        keyBookshelfShowIntro: bookshelfShowIntro,
        keyBookshelfShowTag: bookshelfShowTag,
        keyBookshelfShowLatestChapter: bookshelfShowLatestChapter,
        keyBookshelfIntroMaxLines: bookshelfIntroMaxLines,
        keyShowWaitUpCount: showWaitUpCount,
        keyShowBookshelfFastScroller: showBookshelfFastScroller,
        keyShouldShowExpandButton: shouldShowExpandButton,
        keyBookshelfRefreshingLimit: bookshelfRefreshingLimit,
        keyBookshelfLayoutModePortrait: bookshelfLayoutModePortrait,
        keyBookshelfLayoutGridPortrait: bookshelfLayoutGridPortrait,
        keyBookshelfLayoutModeLandscape: bookshelfLayoutModeLandscape,
        keyBookshelfLayoutGridLandscape: bookshelfLayoutGridLandscape,
        keyBookshelfLayoutListPortrait: bookshelfLayoutListPortrait,
        keyBookshelfLayoutListLandscape: bookshelfLayoutListLandscape,
        keyBookshelfFolderLayoutModePortrait:
            bookshelfFolderLayoutModePortrait,
        keyBookshelfFolderLayoutGridPortrait:
            bookshelfFolderLayoutGridPortrait,
        keyBookshelfFolderLayoutModeLandscape:
            bookshelfFolderLayoutModeLandscape,
        keyBookshelfFolderLayoutGridLandscape:
            bookshelfFolderLayoutGridLandscape,
        keyBookshelfFolderLayoutListPortrait:
            bookshelfFolderLayoutListPortrait,
        keyBookshelfFolderLayoutListLandscape:
            bookshelfFolderLayoutListLandscape,
        keyBookshelfGridLayout: bookshelfGridLayout,
        keyBookshelfLayoutCompact: bookshelfLayoutCompact,
        keyBookshelfListCoverCenter: bookshelfListCoverCenter,
        keyBookshelfListIntroBelowContent: bookshelfListIntroBelowContent,
        keyBookshelfShowDivider: bookshelfShowDivider,
        keyBookshelfTitleSmallFont: bookshelfTitleSmallFont,
        keyBookshelfTitleCenter: bookshelfTitleCenter,
        keyBookshelfTitleMaxLines: bookshelfTitleMaxLines,
        keyBookshelfCoverShadow: bookshelfCoverShadow,
        keyBookshelfCardColor: bookshelfCardColor,
        keyBookshelfCardColorDark: bookshelfCardColorDark,
        keyBookshelfGroupListStyle: bookshelfGroupListStyle,
        keyBookshelfGroupCoverCount: bookshelfGroupCoverCount,
        keyBookshelfListCoverWidth: bookshelfListCoverWidth,
        keyBookshelfGridCoverWidth: bookshelfGridCoverWidth,
        keyBookshelfSearchActionDirectToSearch:
            bookshelfSearchActionDirectToSearch,
        keyAutoRefreshBook: autoRefreshBook,
        keySaveTabPosition: saveTabPosition,
      };

  /// 越界值收敛（备份/手改/旧版本写入同一入口）
  BookshelfSettings normalized() {
    int clamp(int value, int min, int max) =>
        math.min(math.max(value, min), max);
    return copyWith(
      bookGroupStyle: clamp(bookGroupStyle, 0, 2),
      bookshelfSort: clamp(bookshelfSort, 0, 5),
      bookshelfSortOrder: clamp(bookshelfSortOrder, 0, 1),
      bookshelfRefreshingLimit: clamp(bookshelfRefreshingLimit, 0, 100),
      bookshelfLayoutModePortrait:
          clamp(bookshelfLayoutModePortrait, 0, 1),
      bookshelfLayoutGridPortrait:
          clamp(bookshelfLayoutGridPortrait, 1, 15),
      bookshelfLayoutModeLandscape:
          clamp(bookshelfLayoutModeLandscape, 0, 1),
      bookshelfLayoutGridLandscape:
          clamp(bookshelfLayoutGridLandscape, 1, 15),
      bookshelfLayoutListPortrait:
          clamp(bookshelfLayoutListPortrait, 1, 5),
      bookshelfLayoutListLandscape:
          clamp(bookshelfLayoutListLandscape, 1, 5),
      bookshelfFolderLayoutModePortrait:
          clamp(bookshelfFolderLayoutModePortrait, 0, 1),
      bookshelfFolderLayoutGridPortrait:
          clamp(bookshelfFolderLayoutGridPortrait, 1, 15),
      bookshelfFolderLayoutModeLandscape:
          clamp(bookshelfFolderLayoutModeLandscape, 0, 1),
      bookshelfFolderLayoutGridLandscape:
          clamp(bookshelfFolderLayoutGridLandscape, 1, 15),
      bookshelfFolderLayoutListPortrait:
          clamp(bookshelfFolderLayoutListPortrait, 1, 5),
      bookshelfFolderLayoutListLandscape:
          clamp(bookshelfFolderLayoutListLandscape, 1, 5),
      bookshelfGridLayout: clamp(bookshelfGridLayout, 0, 2),
      bookshelfTitleMaxLines: clamp(bookshelfTitleMaxLines, 1, 5),
      bookshelfIntroMaxLines: clamp(bookshelfIntroMaxLines, 0, 10),
      bookshelfGroupListStyle: clamp(bookshelfGroupListStyle, 0, 2),
      bookshelfGroupCoverCount: clamp(bookshelfGroupCoverCount, 1, 10),
      bookshelfListCoverWidth: clamp(bookshelfListCoverWidth, 40, 120),
      bookshelfGridCoverWidth: clamp(bookshelfGridCoverWidth, 40, 150),
    );
  }

  /// 当前方向布局模式：0 列表 / 1 网格
  int layoutModeFor({required bool isLandscape}) =>
      isLandscape ? bookshelfLayoutModeLandscape : bookshelfLayoutModePortrait;

  /// 当前方向网格列数
  int gridColumnsFor({required bool isLandscape}) => isLandscape
      ? bookshelfLayoutGridLandscape
      : bookshelfLayoutGridPortrait;

  /// 当前方向列表列数
  int listColumnsFor({required bool isLandscape}) => isLandscape
      ? bookshelfLayoutListLandscape
      : bookshelfLayoutListPortrait;

  /// 列表多列时的最小可读单元格宽（低于该宽度会横向挤压文字/角标）
  static const double minReadableListCellWidth = 150;

  /// 当前视口最多可用的列表列数（入口按此夹取配置列数）
  ///
  /// 列表多列由 SliverGrid 承载，单元格过窄会导致未读角标/摘要行溢出；
  /// 360dp 屏最多 2 列、400dp 屏最多 2 列、约 482dp 起才允许 3 列。
  static int maxReadableListColumns(
    double viewportWidth, {
    double horizontalPadding = 8,
    double spacing = 8,
  }) {
    final available = math.max(0.0, viewportWidth - horizontalPadding * 2);
    final count =
        ((available + spacing) / (minReadableListCellWidth + spacing))
            .floor();
    return math.max(1, count);
  }

  /// 当前明暗卡片色（0 = 跟随主题）
  int cardColorFor({required bool isDark}) =>
      isDark ? bookshelfCardColorDark : bookshelfCardColor;

  /// 网格普通书名字号（小字体 = 11，常规 = 12，对齐参考 labelSmall/Medium）
  double get gridTitleFontSize => bookshelfTitleSmallFont ? 11 : 12;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is BookshelfSettings &&
          other.bookGroupStyle == bookGroupStyle &&
          other.hideEmptyGroups == hideEmptyGroups &&
          other.bookshelfSort == bookshelfSort &&
          other.bookshelfSortOrder == bookshelfSortOrder &&
          other.showUnread == showUnread &&
          other.showUnreadNew == showUnreadNew &&
          other.showTip == showTip &&
          other.showBookCount == showBookCount &&
          other.showLastUpdateTime == showLastUpdateTime &&
          other.showBookIntro == showBookIntro &&
          other.bookshelfShowIntro == bookshelfShowIntro &&
          other.bookshelfShowTag == bookshelfShowTag &&
          other.bookshelfShowLatestChapter == bookshelfShowLatestChapter &&
          other.bookshelfIntroMaxLines == bookshelfIntroMaxLines &&
          other.showWaitUpCount == showWaitUpCount &&
          other.showBookshelfFastScroller == showBookshelfFastScroller &&
          other.shouldShowExpandButton == shouldShowExpandButton &&
          other.bookshelfRefreshingLimit == bookshelfRefreshingLimit &&
          other.bookshelfLayoutModePortrait ==
              bookshelfLayoutModePortrait &&
          other.bookshelfLayoutGridPortrait == bookshelfLayoutGridPortrait &&
          other.bookshelfLayoutModeLandscape ==
              bookshelfLayoutModeLandscape &&
          other.bookshelfLayoutGridLandscape ==
              bookshelfLayoutGridLandscape &&
          other.bookshelfLayoutListPortrait ==
              bookshelfLayoutListPortrait &&
          other.bookshelfLayoutListLandscape ==
              bookshelfLayoutListLandscape &&
          other.bookshelfFolderLayoutModePortrait ==
              bookshelfFolderLayoutModePortrait &&
          other.bookshelfFolderLayoutGridPortrait ==
              bookshelfFolderLayoutGridPortrait &&
          other.bookshelfFolderLayoutModeLandscape ==
              bookshelfFolderLayoutModeLandscape &&
          other.bookshelfFolderLayoutGridLandscape ==
              bookshelfFolderLayoutGridLandscape &&
          other.bookshelfFolderLayoutListPortrait ==
              bookshelfFolderLayoutListPortrait &&
          other.bookshelfFolderLayoutListLandscape ==
              bookshelfFolderLayoutListLandscape &&
          other.bookshelfGridLayout == bookshelfGridLayout &&
          other.bookshelfLayoutCompact == bookshelfLayoutCompact &&
          other.bookshelfListCoverCenter == bookshelfListCoverCenter &&
          other.bookshelfListIntroBelowContent ==
              bookshelfListIntroBelowContent &&
          other.bookshelfShowDivider == bookshelfShowDivider &&
          other.bookshelfTitleSmallFont == bookshelfTitleSmallFont &&
          other.bookshelfTitleCenter == bookshelfTitleCenter &&
          other.bookshelfTitleMaxLines == bookshelfTitleMaxLines &&
          other.bookshelfCoverShadow == bookshelfCoverShadow &&
          other.bookshelfCardColor == bookshelfCardColor &&
          other.bookshelfCardColorDark == bookshelfCardColorDark &&
          other.bookshelfGroupListStyle == bookshelfGroupListStyle &&
          other.bookshelfGroupCoverCount == bookshelfGroupCoverCount &&
          other.bookshelfListCoverWidth == bookshelfListCoverWidth &&
          other.bookshelfGridCoverWidth == bookshelfGridCoverWidth &&
          other.bookshelfSearchActionDirectToSearch ==
              bookshelfSearchActionDirectToSearch &&
          other.autoRefreshBook == autoRefreshBook &&
          other.saveTabPosition == saveTabPosition;

  @override
  int get hashCode => Object.hashAll([
        bookGroupStyle,
        hideEmptyGroups,
        bookshelfSort,
        bookshelfSortOrder,
        showUnread,
        showUnreadNew,
        showTip,
        showBookCount,
        showLastUpdateTime,
        showBookIntro,
        bookshelfShowIntro,
        bookshelfShowTag,
        bookshelfShowLatestChapter,
        bookshelfIntroMaxLines,
        showWaitUpCount,
        showBookshelfFastScroller,
        shouldShowExpandButton,
        bookshelfRefreshingLimit,
        bookshelfLayoutModePortrait,
        bookshelfLayoutGridPortrait,
        bookshelfLayoutModeLandscape,
        bookshelfLayoutGridLandscape,
        bookshelfLayoutListPortrait,
        bookshelfLayoutListLandscape,
        bookshelfFolderLayoutModePortrait,
        bookshelfFolderLayoutGridPortrait,
        bookshelfFolderLayoutModeLandscape,
        bookshelfFolderLayoutGridLandscape,
        bookshelfFolderLayoutListPortrait,
        bookshelfFolderLayoutListLandscape,
        bookshelfGridLayout,
        bookshelfLayoutCompact,
        bookshelfListCoverCenter,
        bookshelfListIntroBelowContent,
        bookshelfShowDivider,
        bookshelfTitleSmallFont,
        bookshelfTitleCenter,
        bookshelfTitleMaxLines,
        bookshelfCoverShadow,
        bookshelfCardColor,
        bookshelfCardColorDark,
        bookshelfGroupListStyle,
        bookshelfGroupCoverCount,
        bookshelfListCoverWidth,
        bookshelfGridCoverWidth,
        bookshelfSearchActionDirectToSearch,
        autoRefreshBook,
        saveTabPosition,
      ]);
}
