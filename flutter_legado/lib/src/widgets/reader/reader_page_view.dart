import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../../l10n/app_strings.dart';
import '../../models/models.dart';
import '../../providers/bookmark/bookmark_notifier.dart';
import '../../providers/providers.dart';
import '../../providers/reader/reader_notifier.dart';
import '../../routes.dart';
import '../../screens/reader_config_panel.dart';
import '../../screens/rss_articles_screen.dart' show showRssPhotoViewer;
import '../../services/book_marking_render.dart';
import '../../services/bookmark_badge_image_store.dart';
import '../../services/highlight_match_sync.dart';
import '../../services/image_action_outcome.dart';
import '../../services/local_book_store.dart' show LocalBookStore;
import '../../services/saved_highlight_render.dart';
import '../../utils/click_img_way.dart' show clickImgToastHint;
import '../../utils/comic_image_utils.dart';
import '../../utils/image_action_replay.dart';
import '../../utils/reader_inline_image.dart';
import '../../widgets/error_view.dart';
import '../../widgets/loading_indicator.dart';
import '../../widgets/paragraph_layout_engine.dart';
import 'reader_bookmark_policy.dart';
import 'reader_inline_image_widget.dart';
import 'reader_page_chrome.dart';
import 'turn/page_direction.dart';
import 'turn/reader_turn_view.dart';
import 'reader_text_content.dart';
import '../../utils/error_message.dart';

/// 正文图片字节加载失败类别（批16 三审 P3-7）
enum _ReaderImageFailureKind {
  none,

  /// 网络/超时/HTTP 状态：允许跨章重试（同章由 attempted 集合去重）
  network,

  /// 路径拒绝/格式错误/解码失败：永久失败
  permanent,
}

class _ReaderImageFetchResult {
  final Uint8List? bytes;
  final _ReaderImageFailureKind failure;

  const _ReaderImageFetchResult(this.bytes, this.failure);

  const _ReaderImageFetchResult.ok(Uint8List this.bytes)
    : failure = _ReaderImageFailureKind.none;

  const _ReaderImageFetchResult.failed(this.failure) : bytes = null;
}

/// 阅读器内容区（分页 + 5 种翻页模式）
///
/// 对齐安卓原版 ReadView + 5 种 PageDelegate（覆盖/滑动/仿真/滚动/无动画）。
/// 拥有排版分页状态与 PageController，通过 [ReaderPageViewState] 对外暴露
/// 翻页导航方法（供自动翻页/点击区域调用）。
class ReaderPageView extends ConsumerStatefulWidget {
  /// [批1b-1 审查回修 P1-2] 翻页成功回调注入点（保持亮屏交互重挂接线）：
  /// ReaderScreen 在挂载时注入 `_reprioritizeKeepLight`（keepLight>0 时
  /// 重置超时计时，对齐参考版用户交互后 screenOffTimerStart 重挂语义）；
  /// 默认空实现（组件独立可用），dispose 时由 ReaderScreen 还原。
  static void Function() onPageTurnInteraction = () {};

  /// 段落间距（来自高级配置）
  final double paragraphSpacing;

  // [UI-fix v2.0.2 | 2026-08-06] 阅读配置面板新增参数接入排版：
  // 字距调节/首行缩进/两端对齐（MoreConfig） — Qoder

  /// 字距（em 语义，对标原版 ReadBookConfig.letterSpacing；渲染/测量时
  /// 乘以字号换算为 px，[UI-fix v2.0.4 | 2026-08-08] — Qoder）
  final double letterSpacing;

  /// 首行缩进字符数（0-3，对标原版 paragraphIndent 缩进档位；
  /// [UI-fix v2.0.4 | 2026-08-08] 由 bool 升级为 int 档位）
  final int paragraphIndent;

  /// 两端对齐开关（对标 MoreConfig textFullJustify）
  final bool textFullJustify;

  // [UI-fix v2.0.3 | 2026-08-06] 页面边距四向可调（对标原版
  // ReadBookConfig paddingTop/Bottom/Left/Right） — Qoder
  final double marginTop;
  final double marginBottom;
  final double marginLeft;
  final double marginRight;

  /// 页眉/页脚提示与标题样式（对标 ReadView PageView）
  final ReaderPageChromeConfig pageChrome;

  /// 正文延伸至状态栏（readBodyToLh；对标原版 readBodyToLh）
  final bool readBodyToLh;

  // [UI-fix v2.0.3 | 2026-08-08] MoreConfig 第①批消费点 — Qoder

  /// 长按选择文本开关（对标原版 selectText，关闭后长按不弹选区面板）
  final bool selectText;

  /// 滚动翻页无动画（对标原版 noAnimScrollPage：程序化翻页去除动画）
  final bool noAnimScroll;

  // [UI-fix v2.0.4 | 2026-08-08] 界面面板/MoreConfig 第②批消费点 — Qoder

  /// 文字字重（0中/1粗/2细，对标原版 textBold）
  final int textBold;

  /// [C3 斜体 | Qoder UI] 正文斜体（参考版行内字体面板「斜体」开关；
  /// 与 textBold 同链路：参与分页测量与渲染，保持同源同参）
  final bool italic;

  /// 自定义文字颜色（ARGB，0=跟随背景自动，对标原版自定义配色）
  final int customTextColor;

  /// 鼠标滚轮翻页（对标原版 mouseWheelPage；分页模式下滚轮上下滚动翻页，
  /// 滚动模式不拦截交给内层 Scrollable）
  final bool mouseWheelPage;

  // [UI-fix v2.0.5 | 2026-08-10] 双页模式接入（对标原版 doubleHorizontalPage
  // 0-3 档：0=单页、1=双页、2=横屏双页、3=平板或横屏双页；滚动模式强制单页）
  /// 双页模式档位（0-3）
  final int doubleHorizontalPage;

  // [UI-fix v2.0.5 | 2026-08-10] 自定义中文分行开关（对标原版 useZhLayout：
  // true=ZhLayout 避头尾断行；false=朴素按宽断行）— Reasonix
  /// 自定义中文分行开关
  final bool useZhLayout;

  // [UI-fix v2.0.5 | 2026-08-10] 段首标点悬挂（对标原版 hangingPunctuation）— Reasonix
  /// 段首标点悬挂开关
  final bool hangingPunctuation;

  /// 段评摘要 counts（P2-9）
  final Map<int, int>? reviewCounts;

  /// 段评角标点击
  final ReviewTapCallback? onReviewTap;

  /// [批16] 正文图片样式（书级 `ReadConfig.imageStyle`：
  /// FULL/TEXT/SINGLE/DEFAULT；空=默认）
  final String? imageStyle;

  /// [批16] 正文图片点击方式（clickImgWay 五档，默认 "2"=兼容旧版）
  final String clickImgWay;

  /// [批16 回修] 图片尺寸测量器（测试注入 Fake；生产 null 走字节解码）
  final ReaderImageSizeMeasurer? imageMeasurer;

  const ReaderPageView({
    super.key,
    required this.paragraphSpacing,
    this.letterSpacing = 0.1,
    this.paragraphIndent = 2,
    this.textFullJustify = true,
    this.marginTop = 24,
    this.marginBottom = 24,
    this.marginLeft = 20,
    this.marginRight = 20,
    this.pageChrome = const ReaderPageChromeConfig(),
    this.readBodyToLh = true,
    this.selectText = true,
    this.noAnimScroll = false,
    this.textBold = 0,
    this.italic = false,
    this.customTextColor = 0,
    this.mouseWheelPage = true,
    this.doubleHorizontalPage = 0,
    this.useZhLayout = true,
    this.hangingPunctuation = false,
    this.reviewCounts,
    this.onReviewTap,
    this.imageStyle,
    this.clickImgWay = '2',
    this.imageMeasurer,
  });

  @override
  ConsumerState<ReaderPageView> createState() => ReaderPageViewState();
}

class ReaderPageViewState extends ConsumerState<ReaderPageView> {
  /// [批4d] 翻页成功观测点（测试注入；生产为 null）。
  ///
  /// sliderVibrator 改接进度条拖动后，既有「翻页成功」用例改用本观测点
  /// 计数，避免把振动语义与翻页语义耦合。
  @visibleForTesting
  static void Function()? debugOnPageTurn;

  /// 相邻章预载预览页（章边界动画与承接显示；[UI_SYNC_REFACTOR S6 修]）
  Widget? _nextChapterPreview;
  Widget? _prevChapterPreview;
  bool _preloadingNext = false;
  bool _preloadingPrev = false;

  /// 最近一次分页参数（相邻章预载复用同参；翻页回调触发预载时也需读取）
  ParagraphConfig? _pagedConfig;
  // ignore: prefer_final_fields
  double _pagedWidth = 0;
  // ignore: prefer_final_fields
  double _pagedHeight = 0;

  /// 重构版翻页视图状态（程序化动画翻页入口）
  final GlobalKey<ReaderTurnViewState> _turnViewKey =
      GlobalKey<ReaderTurnViewState>();

  /// [UI-fix v2.0.3 | 2026-08-08] 滚动模式控制器（支撑滚动模式下的
  //  程序化翻页：点击区域/自动翻页/无动画翻页均按屏滚动）— Qoder
  final ScrollController _scrollController = ScrollController();

  // ===== 排版引擎分页状态 =====

  /// 当前章节的排版分页结果
  List<PageInfo> _paginatedPages = [];

  /// 分页对应的章节索引（用于检测章节切换后重新分页）
  int _paginatedChapterIndex = -1;

  /// 分页对应的字号（设置变化时重新分页）
  double _paginatedFontSize = -1;

  /// 分页对应的行高
  double _paginatedLineHeight = -1;

  /// 分页对应的段距
  double _paginatedParagraphSpacing = -1;

  // [UI-fix v2.0.2 | 2026-08-06] 分页缓存键新增字距/缩进/对齐/字体 — Qoder
  double _paginatedLetterSpacing = double.nan;
  // [UI-fix v2.0.4 | 2026-08-08] 缩进改 int 档位；新增字重缓存键 — Qoder
  int _paginatedIndent = -1;
  int _paginatedTextBold = -1;
  bool _paginatedItalic = false;
  bool _paginatedJustify = true;
  String? _paginatedFontFamily;

  /// 分页对应的 DefaultTextStyle（含主题字体等环境样式）
  ///
  /// [应用字体入口回修 2026-11-11] 应用字体只作用于界面文字；阅读正文
  /// 虽显式覆盖 fontFamily，但 baseStyle 仍决定 fallback/度量等环境样式。
  /// 将其纳入分页键：应用字体/主题 typography 迟到变化时重新测量，避免
  /// 沿用旧分页尺寸导致行溢出。
  TextStyle? _paginatedBaseStyle;

  // [UI-fix v2.0.3 | 2026-08-06] 分页缓存键新增页面边距 — Qoder
  String _paginatedMargins = '';
  String _paginatedPageChrome = '';

  // [UI-fix v2.0.5 | 2026-08-10] 双页模式分页状态：当前分页是否双栏
  // （档位/宽高比/翻页模式变化时重新分页）— Reasonix
  bool _paginatedDoublePage = false;

  /// 当前分页是否为双页模式（单页时恒 false；翻页步进/屏换算消费）
  bool get _isDoublePage => _paginatedDoublePage;

  // [UI-fix v2.0.5 | 2026-08-10] 中文分行开关分页缓存键（useZhLayout
  // 变化时重新分页）— Reasonix
  bool _paginatedUseZhLayout = true;

  // [UI-fix v2.0.5 | 2026-08-10] 段首标点悬挂分页缓存键 — Reasonix
  bool _paginatedHangingPunctuation = false;

  // [UI-fix v2.0.3 | 2026-08-08] 分页缓存键新增系统栏 padding（隐藏
  // 状态栏/导航栏后可用高度变化需重新分页）— Qoder
  String _paginatedSysPadding = '';

  // [UI-fix v2.0.3 | 2026-08-08] 分页缓存键纳入正文内容：编辑内容/反转
  // 内容保存后同章重载（reloadChapterContent）时正文变化但章节索引不变，
  // 不比对内容会命中旧分页缓存导致页面仍显示旧正文 — Qoder
  String _paginatedContent = '';

  /// 分页对应的书籍 URL（换源后旧正文仍显示时，高亮匹配须跟旧书/旧内容）
  String _paginatedBookUrl = '';

  /// 分页对应的书名/书源名（高亮规则 scope 过滤，与 URL 同快照）
  String _paginatedBookName = '';
  String _paginatedBookOrigin = '';

  // ===== [批34] 正文高亮匹配状态 =====

  /// 命中同步器（缓存/在途去重/失败退避，逻辑见 highlight_match_sync.dart）
  ///
  /// [批34b P2-1] 从 State 抽出为可注入 helper（单测覆盖换章清空/滚动不调
  /// FFI/修订号失效/失败重试预算）— full-stack-engineer
  final HighlightMatchSync _highlightSync = HighlightMatchSync();

  /// 当前章节命中区间（渲染直接读取；异步到达后 setState 重建）
  List<HighlightMatch> _highlightMatches = const [];

  // ===== [批7b-2b] 书签标记正文渲染状态 =====

  /// 当前章用户笔记（book_marks）转换后的命中区间
  List<HighlightMatch> _markingMatches = const [];

  /// 规则命中 + 笔记命中的合并结果（传给正文渲染）
  List<HighlightMatch> _combinedHighlightMatches = const [];

  /// 当前笔记命中对应的键（书 + 章 + 正文 + 修订号）
  String _markingKey = '';

  /// 在途笔记加载键（去重）
  String _markingLoadingKey = '';

  /// 各 key 已发起的加载次数（单 key 最多 2 次，参考 HighlightMatchSync）
  final Map<String, int> _markingAttempts = {};
  static const int _maxMarkingAttempts = 2;

  /// 重试预算所属的「书+章+正文」身份键（不含修订号）
  ///
  /// 切章/换书/正文变化时清空尝试次数与失败退避，避免 A→B→A 回到
  /// 同一章时被上一轮迟到失败耗尽预算（修订号变化按新 key 独立计数）。
  String _markingIdentityKey = '';

  // ===== 手动高亮（highlights 表）正文渲染状态 =====
  //
  // 设备验收缺陷：保存侧写入 highlights 表后正文永不显示（渲染链只读
  // highlight_rules 规则表，highlightListByChapter 零调用方）。以下状态
  // 按章加载已存高亮并并入渲染，机制与笔记标记一致（同型轻量缓存 +
  // 在途去重 + 单 key 重试预算 + 切章先清空）。

  /// 当前章已存手动高亮转换后的命中区间
  List<HighlightMatch> _savedHighlightMatches = const [];

  /// 当前手动高亮命中对应的键（书 + 章 + 正文 + 修订号）
  String _savedHighlightKey = '';

  /// 在途手动高亮加载键（去重）
  String _savedHighlightLoadingKey = '';

  /// 各 key 已发起的加载次数（单 key 最多 2 次）
  final Map<String, int> _savedHighlightAttempts = {};
  static const int _maxSavedHighlightAttempts = 2;

  /// 重试预算所属的「书+章+正文」身份键（不含修订号）
  String _savedHighlightIdentityKey = '';

  /// 当前阅读字体 family（与 FontScreen 持久化键 reader_font_family 同步）
  String? _fontFamily;

  /// 当前页索引（屏级分页）
  int _currentPageIndex = 0;

  /// 当前分页数据对应的章节标题（与 _paginatedChapterIndex 同帧写入，
  /// 章节切换加载中冻结渲染时标题与正文保持同章，避免新标题配旧正文）
  String? _paginatedChapterTitle;

  // ===== [批16] 正文行内图片混排状态 =====

  /// 分页对应的图片尺寸缓存修订号（异步预测量完成后触发一次重排）
  int _paginatedImageRevision = -1;

  /// 分页对应的书级 imageStyle（设置变化时重排）
  String? _paginatedImageStyle;

  /// 首屏标题图布局（与首页容量同参；仅首屏渲染）
  ReaderImageLayout? _paginatedTitleImageLayout;

  /// 已加载书源缓存（原图下载/imageDecode 用）
  BookSource? _readerImageSource;
  String? _readerImageSourceOrigin;
  Future<void>? _readerImageSourceLoading;

  /// 图片字节加载在途去重（结果含失败分类，供测量回填重试语义）
  final Map<String, Future<_ReaderImageFetchResult>> _imageLoads = {};

  /// 图片测量代际（换书/切章时自增，旧会话结果作废）
  int _imageMeasureSession = 0;

  /// 本会话已 beginMeasure 的 key → 会话号（取消时逐个回滚在途标记）
  final Map<String, int> _imageMeasureKeys = {};

  /// 本会话已尝试过的 key（网络失败同章内不重试；换章清空）
  final Set<String> _imageMeasureAttempted = {};

  /// 测量协程互斥：全章同一时刻只允许 1 个协程（重排不得重启测量）
  bool _imageMeasureRunning = false;

  /// 测量归属的书/章（build 阶段检测切章，含 loading 冻结期）
  String _imageMeasureBookUrl = '\u0000';
  int _imageMeasureChapterIndex = -1;

  /// 合并重排定时器（逐图完成时 16ms 内合并为一次 setState）
  Timer? _imageReflowTimer;

  /// 分页次数（测试观测重排次数；生产不读取）
  @visibleForTesting
  static int debugRepaginationCount = 0;

  /// 当前页索引
  int get currentPageIndex => _currentPageIndex;

  // [UI-fix v2.0.4 | 2026-08-08] 鼠标滚轮翻页节流时间戳（300ms 防连翻，
  // 对标原版 ReadView 滚轮事件单次翻页语义）— Qoder
  DateTime _lastWheelTurn = DateTime.fromMillisecondsSinceEpoch(0);

  /// 翻页成功统一收敛点：重挂保持亮屏。
  ///
  /// [批4d] sliderVibrator 已改接底部进度条拖动，翻页不再振动；
  /// 本方法只保留既有 keepLight 交互语义。
  void _notifyPageTurn() {
    ReaderPageView.onPageTurnInteraction();
    ReaderPageViewState.debugOnPageTurn?.call();
  }

  /// 当前章分页总数（进度条「调章内页」行为消费）
  int get pageCount => _paginatedPages.length;

  // ===== [批4d] 页范围 → 书签判定 =====

  /// 下滑书签增删在途互斥：防连点/动画重入造成重复添加
  bool _bookmarkToggleInFlight = false;

  /// 当前屏首页索引（双页固定对齐屏首左页；奇数索引来自历史进度/恢复）
  int get _screenStartPageIndex =>
      _isDoublePage ? (_currentPageIndex ~/ 2) * 2 : _currentPageIndex;

  /// 当前屏字符区间（双页为左右并集；无段落 0）
  ReaderBookmarkRange get currentPageRange => readerBookmarkRangeForScreen(
    _paginatedPages,
    _screenStartPageIndex,
    doublePage: _isDoublePage,
  );

  /// 顶栏添加书签使用的章内页首偏移
  int get currentPageStartPos => currentPageRange.start;

  /// [批4d] 顶栏书签使用的页上下文章节（与 pos/text 同源，避免章切换
  /// 窗口出现「新章号 + 旧页偏移」）
  int get currentPageChapterIndex => _displayChapterIndex;

  /// [批4d] 顶栏书签使用的页上下文章节名
  String get currentPageChapterTitle =>
      _paginatedChapterTitle ??
      ref.read(readerNotifierProvider).currentChapter?.title ??
      '';

  /// 当前屏首页首段正文（书签摘要/内容）
  String get currentPageStartText {
    if (_paginatedPages.isEmpty) return '';
    final index = _screenStartPageIndex.clamp(0, _paginatedPages.length - 1);
    final content = _paginatedContent.isNotEmpty
        ? _paginatedContent
        : ref.read(readerNotifierProvider).chapterContent;
    return readerBookmarkPageStartText(
      page: _paginatedPages[index],
      chapterContent: content,
    );
  }

  /// 当前章各页页首字符偏移（按页划分朗读用，设置批5b）
  ///
  /// 复用 [readerBookmarkRangeForPage] 的行级可见区间：页首 = 首行
  /// `chapterStartIndex`，跨页长段落不会被退化为整段偏移。返回值为当前
  /// 分页快照对应的章节（调用方用 [currentPageChapterIndex] 校验章号），
  /// 始终含 0；章末由切分函数补齐。无分页/空正文返回空列表。
  List<int> get currentChapterPageStarts {
    if (_paginatedPages.isEmpty) return const [];
    // [审查回修 P3] 滚动模式没有稳定页边界：返回空，朗读按页回退整段
    if (ref.read(readerNotifierProvider).pageTurnMode == PageTurnMode.scroll) {
      return const [];
    }
    final content = _paginatedContent.isNotEmpty
        ? _paginatedContent
        : ref.read(readerNotifierProvider).chapterContent;
    return readerPageStartsForPages(_paginatedPages, content.length);
  }

  int get _displayChapterIndex {
    if (_paginatedChapterIndex >= 0) return _paginatedChapterIndex;
    return ref.read(readerNotifierProvider).currentChapterIndex;
  }

  Bookmark? _bookmarkOnPage(
    ReaderState state,
    List<Bookmark> bookmarks,
    int pageIndex,
  ) {
    final book = state.currentBook;
    if (book == null || pageIndex < 0 || pageIndex >= _paginatedPages.length) {
      return null;
    }
    return readerBookmarkInRange(
      bookmarks,
      bookName: book.name,
      bookAuthor: book.author,
      chapterIndex: _displayChapterIndex,
      range: readerBookmarkRangeForPage(_paginatedPages[pageIndex]),
    );
  }

  Bookmark? _bookmarkOnCurrentScreen(
    ReaderState state,
    List<Bookmark> bookmarks,
  ) {
    final book = state.currentBook;
    if (book == null || _paginatedPages.isEmpty) return null;
    final range = currentPageRange;
    return readerBookmarkInRange(
      bookmarks,
      bookName: book.name,
      bookAuthor: book.author,
      chapterIndex: _displayChapterIndex,
      range: range,
      referencePos: range.start,
    );
  }

  /// 下滑手势触发：本屏已有书签 → 删除；否则按页首添加
  Future<void> _toggleBookmarkOnCurrentPage() async {
    if (_bookmarkToggleInFlight) return;
    final state = ref.read(readerNotifierProvider);
    final book = state.currentBook;
    if (book == null) return;
    // 分页未就绪时页范围为 0：不得把书签误加到章首
    final range = currentPageRange;
    if (range.isEmpty) return;
    _bookmarkToggleInFlight = true;
    final messenger = ScaffoldMessenger.maybeOf(context);
    try {
      final notifier = ref.read(bookmarkNotifierProvider.notifier);
      final bookmarks = ref.read(bookmarkNotifierProvider).bookmarks;
      final existing = _bookmarkOnCurrentScreen(state, bookmarks);
      if (existing != null) {
        await notifier.deleteBookmark(existing.id);
        return;
      }
      final chapterIndex = _displayChapterIndex;
      final chapterName =
          _paginatedChapterTitle ?? state.currentChapter?.title ?? '';
      final content = _paginatedContent.isNotEmpty
          ? _paginatedContent
          : state.chapterContent;
      final page = _paginatedPages.isEmpty
          ? null
          : _paginatedPages[_screenStartPageIndex.clamp(
              0,
              _paginatedPages.length - 1,
            )];
      final text = readerBookmarkPageStartText(
        page: page,
        chapterContent: content,
      );
      await notifier.addBookmark(
        bookName: book.name,
        bookAuthor: book.author,
        chapterIndex: chapterIndex,
        chapterPos: range.start,
        chapterName: chapterName,
        bookText: text,
      );
    } catch (e) {
      messenger?.showSnackBar(SnackBar(content: Text('书签操作失败：${errorMessage(e)}')));
    } finally {
      _bookmarkToggleInFlight = false;
    }
  }

  /// 程序化跳页（进度条拖动/目录跳转等；直设索引=瞬时切换，
  /// 相邻步进翻页走 _turnViewKey.turnByAnim 保持动画）
  void _navigateToPage(int index) {
    setState(() => _currentPageIndex = index);
    ref.read(readerNotifierProvider.notifier).updatePosition(index);
    // [批4d] 翻页成功只重挂 keepLight，不再振动（sliderVibrator 改进度条）
    _notifyPageTurn();
    // 跳页同样驱动相邻章预载
    _maybePreloadAdjacent(ref.read(readerNotifierProvider));
  }

  /// 滚动模式：按一屏高度滚动（前进/后退，动画随 noAnimScrollPage）
  void _scrollByViewport(bool forward) {
    if (!_scrollController.hasClients) return;
    final pos = _scrollController.position;
    if (!pos.hasViewportDimension) return;
    final delta = forward ? pos.viewportDimension : -pos.viewportDimension;
    final target = (pos.pixels + delta).clamp(
      pos.minScrollExtent,
      pos.maxScrollExtent,
    );
    // [批4d] 滚动翻页成功重挂 keepLight（sliderVibrator 改进度条）
    if (target != pos.pixels) {
      _notifyPageTurn();
    }
    if (widget.noAnimScroll) {
      _scrollController.jumpTo(target);
    } else {
      _scrollController.animateTo(
        target,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
      );
    }
  }

  /// 跳转到章内指定页（进度条「调章内页」行为，对标原版
  //  progressBarBehavior=page 时 seek_read_page 调页语义）— Qoder
  void goToPage(int index) {
    if (_paginatedPages.isEmpty) return;
    final target = index.clamp(0, _paginatedPages.length - 1);
    _navigateToPage(target);
  }

  /// 前进（下一页或下一章）
  ///
  /// 跨章节无缝翻页：到达本章最后一页时自动进入下一章第一页。
  void nextPageOrChapter() {
    final notifier = ref.read(readerNotifierProvider.notifier);
    // [UI-fix v2.0.3 | 2026-08-08] 滚动模式下程序化翻页按屏滚动 — Qoder
    if (ref.read(readerNotifierProvider).pageTurnMode == PageTurnMode.scroll) {
      if (_scrollController.hasClients) {
        final pos = _scrollController.position;
        if (pos.hasViewportDimension && pos.pixels >= pos.maxScrollExtent - 1) {
          // [批4d] 滚动模式跨章重挂 keepLight
          _notifyPageTurn();
          notifier.nextChapter();
        } else {
          _scrollByViewport(true);
        }
      } else {
        _notifyPageTurn();
        notifier.nextChapter();
      }
      return;
    }
    // [UI_SYNC_REFACTOR S6 重构] 动画翻页统一走重构版翻页视图：
    // turnByAnim 内部按方向处理页内/跨章（章边界无邻页快照时瞬时填充）
    final turn = _turnViewKey.currentState;
    if (turn != null) {
      unawaited(turn.turnByAnim(PageTurnDirection.next));
      return;
    }
    // 视图未挂载兜底：直设索引/跨章
    final step = _isDoublePage ? 2 : 1;
    if (_currentPageIndex + step < _paginatedPages.length) {
      _navigateToPage(_currentPageIndex + step);
    } else {
      _notifyPageTurn();
      notifier.nextChapter();
    }
  }

  /// 后退（上一页或上一章）
  ///
  /// 跨章节无缝翻页：到达本章第一页时自动进入上一章最后一页。
  void prevPageOrChapter() {
    final notifier = ref.read(readerNotifierProvider.notifier);
    // [UI-fix v2.0.3 | 2026-08-08] 滚动模式下程序化翻页按屏滚动 — Qoder
    if (ref.read(readerNotifierProvider).pageTurnMode == PageTurnMode.scroll) {
      if (_scrollController.hasClients) {
        final pos = _scrollController.position;
        if (pos.hasViewportDimension && pos.pixels <= pos.minScrollExtent + 1) {
          // [批4d] 滚动模式跨章重挂 keepLight
          _notifyPageTurn();
          notifier.prevChapter();
        } else {
          _scrollByViewport(false);
        }
      } else {
        _notifyPageTurn();
        notifier.prevChapter();
      }
      return;
    }
    // [UI_SYNC_REFACTOR S6 重构] 同 next：动画翻页统一走重构版翻页视图
    final turn = _turnViewKey.currentState;
    if (turn != null) {
      unawaited(turn.turnByAnim(PageTurnDirection.prev));
      return;
    }
    final step = _isDoublePage ? 2 : 1;
    if (_currentPageIndex - step >= 0) {
      _navigateToPage(_currentPageIndex - step);
    } else {
      _notifyPageTurn();
      notifier.prevChapter();
    }
  }

  @override
  void initState() {
    super.initState();
    unawaited(_refreshFontFamily());
    // [批4d] 预热 Support 目录，供角标自定义图同步解析；失败回落默认
    unawaited(
      BookmarkBadgeImageStore.ensureWarm().then((_) {
        if (mounted) setState(() {});
      }),
    );
  }

  @override
  void didUpdateWidget(covariant ReaderPageView oldWidget) {
    super.didUpdateWidget(oldWidget);
    // [UI-fix v2.0.2 | 2026-08-06] 从字体选择页返回时重建 widget，
    // 重新读取字体配置（自定义字体会经 FontLoader 重新注册） — Qoder
    unawaited(_refreshFontFamily());
  }

  /// 阅读正文实际字体族（绝不返回 null）
  ///
  /// [应用字体入口回修 2026-11-11] `TextStyle(fontFamily: null)` 会并入
  /// 上层 DefaultTextStyle——MaterialApp 的 ThemeData 已注入应用字体
  /// （界面字体），若正文不显式覆盖，未设置阅读字体时正文会误用应用字体。
  /// 因此读者未配置字体时取平台 typography 的默认族名（Roboto /
  /// CupertinoSystemText / Segoe UI），保证应用字体绝不泄漏进正文。
  String _resolveReaderFontFamily(BuildContext context) {
    final configured = _fontFamily;
    if (configured != null && configured.isNotEmpty) return configured;
    final typography = Theme.of(context).typography;
    final baseTheme = Theme.of(context).brightness == Brightness.dark
        ? typography.white
        : typography.black;
    final family = baseTheme.bodyMedium?.fontFamily;
    return (family == null || family.isEmpty) ? 'Roboto' : family;
  }

  /// 从 SharedPreferences 读取当前阅读字体，自定义字体需先经 FontLoader 注册
  Future<void> _refreshFontFamily() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final family = prefs.getString('reader_font_family');
      // [C3 标题字体] 标题字体（空=跟随正文）：非空且不同于正文时，其
      // Custom_ 字体文件也需注册，否则标题回退默认字体 — full-stack-engineer
      final titleFamily = prefs.getString('titleFont') ?? '';
      final customFamilies = <String>{
        if (family != null && family.startsWith('Custom_')) family,
        if (titleFamily.isNotEmpty &&
            titleFamily.startsWith('Custom_') &&
            titleFamily != family)
          titleFamily,
      };
      // 自定义字体（Custom_* 前缀）应用重启后需重新加载字体文件
      if (customFamilies.isNotEmpty) {
        final customRaw = prefs.getStringList('reader_custom_fonts') ?? [];
        for (final entry in customRaw) {
          final parts = entry.split('|');
          if (parts.length != 2) continue;
          final name = parts[0];
          if (!customFamilies.contains(name)) continue;
          final file = File(parts[1]);
          if (await file.exists()) {
            final loader = FontLoader(name)
              ..addFont(file.readAsBytes().then((b) => b.buffer.asByteData()));
            await loader.load();
          }
        }
      }
      if (!mounted) return;
      if (family != _fontFamily) {
        setState(() {
          _fontFamily = family;
          _paginatedFontFamily = null; // 强制重新分页
        });
      }
    } catch (e) {
      // 字体配置不可用时回退默认字体，不阻断阅读
      debugPrint('阅读字体加载失败，回退默认字体: $e');
    }
  }

  @override
  void dispose() {
    _imageMeasureSession++;
    _cancelImageMeasurements();
    _imageReflowTimer?.cancel();
    _scrollController.dispose();
    super.dispose();
  }

  /// 取消本次图片测量（换书/切章/销毁）：回滚在途标记，允许新章重测
  void _cancelImageMeasurements() {
    for (final key in _imageMeasureKeys.keys) {
      ReaderImageSizeCache.cancelMeasure(key);
    }
    _imageMeasureKeys.clear();
    _imageMeasureAttempted.clear();
    _endImageMeasureBatch();
  }

  void _endImageMeasureBatch() {
    if (!_imageMeasureRunning) return;
    _imageMeasureRunning = false;
    ReaderImageSizeCache.endMeasureBatch();
  }

  /// 检测书/章身份变化（含 loading 冻结期：build 阶段即取消旧章测量）
  void _syncImageMeasureIdentity(ReaderState state) {
    final bookUrl = state.currentBook?.bookUrl ?? '';
    final chapterIndex = state.currentChapterIndex;
    if (bookUrl == _imageMeasureBookUrl &&
        chapterIndex == _imageMeasureChapterIndex) {
      return;
    }
    _imageMeasureBookUrl = bookUrl;
    _imageMeasureChapterIndex = chapterIndex;
    _imageMeasureSession++;
    _cancelImageMeasurements();
  }

  /// 合并重排：逐图完成时只安排一次 setState（16ms 内合并）
  void _scheduleImageReflow() {
    if (!mounted) return;
    if (_imageReflowTimer?.isActive ?? false) return;
    _imageReflowTimer = Timer(const Duration(milliseconds: 16), () {
      _imageReflowTimer = null;
      if (!mounted) return;
      setState(() {});
    });
  }

  /// 检查是否需要重新分页（章节/字号/行高/段距变化时触发）
  ///
  /// 移植自安卓端 TextChapterLayout 的排版触发时机：
  /// 章节加载完成、字体设置变更、屏幕尺寸变化
  void _paginateIfNeeded(BuildContext context, ReaderState state) {
    final content = state.chapterContent;
    final fontSize = state.fontSize;
    final lineHeight = state.lineHeight;
    final spacing = widget.paragraphSpacing;
    final chapterIndex = state.currentChapterIndex;
    // [UI-fix v2.0.2 | 2026-08-06] 字距/首行缩进/两端对齐/字体变化同样触发重新分页 — Qoder
    // [UI-fix v2.0.4 | 2026-08-08] 字距 em → px（×字号）；缩进改档位；
    // 字重变化同样触发重新分页（测量与渲染同参保证分页一致）— Qoder
    final letterSpacing = widget.letterSpacing * fontSize;
    final indent = widget.paragraphIndent;
    final textBold = widget.textBold;
    final italic = widget.italic;
    final justify = widget.textFullJustify;
    // [应用字体入口回修 2026-11-11] 未配置阅读字体时取平台默认族名，
    // 显式覆盖 ThemeData 注入的应用字体（测量与渲染同参）
    final fontFamily = _resolveReaderFontFamily(context);
    // 实测样式合并 DefaultTextStyle（与渲染侧 Text 的主题字体一致，
    // 避免字体度量差异引入像素级偏差）；纳入分页键，见下方
    final baseStyle = DefaultTextStyle.of(context).style;
    // [UI-fix v2.0.3 | 2026-08-06] 页面边距变化同样触发重新分页 — Qoder
    final margins =
        '${widget.marginTop}_${widget.marginBottom}_${widget.marginLeft}_${widget.marginRight}';
    // [UI-fix v2.0.3 | 2026-08-08] 系统栏显隐改变可用高度时重新分页 — Qoder
    final sysPadding = MediaQuery.of(context).padding;
    final statusBarTop = readerContentStatusBarInset(
      context,
      hideStatusBar: widget.pageChrome.hideStatusBar,
      readBodyToLh: widget.readBodyToLh,
    );
    final sysPaddingKey =
        '${statusBarTop}_${sysPadding.bottom}_${sysPadding.left}_${sysPadding.right}';

    // [UI-fix v2.0.5 | 2026-08-10] 双页档位判定（对齐原版
    // ChapterProvider.upLayout：0=单页、1=双页、2=横屏双页、3=平板或
    // 横屏双页；滚动模式 pageAnim==3 强制单页；桌面端以窗口宽 >=700
    // 作为平板语义）— Reasonix
    final screenSize = MediaQuery.of(context).size;
    final doublePage = switch (widget.doubleHorizontalPage) {
      1 => state.pageTurnMode != PageTurnMode.scroll,
      2 =>
        screenSize.width > screenSize.height &&
            state.pageTurnMode != PageTurnMode.scroll,
      3 =>
        (screenSize.width > screenSize.height || screenSize.width >= 700) &&
            state.pageTurnMode != PageTurnMode.scroll,
      _ => false,
    };

    final needRepaginate =
        content.isNotEmpty &&
        (content != _paginatedContent ||
            chapterIndex != _paginatedChapterIndex ||
            fontSize != _paginatedFontSize ||
            lineHeight != _paginatedLineHeight ||
            spacing != _paginatedParagraphSpacing ||
            letterSpacing != _paginatedLetterSpacing ||
            indent != _paginatedIndent ||
            textBold != _paginatedTextBold ||
            italic != _paginatedItalic ||
            justify != _paginatedJustify ||
            fontFamily != _paginatedFontFamily ||
            baseStyle != _paginatedBaseStyle ||
            margins != _paginatedMargins ||
            widget.pageChrome.layoutKey != _paginatedPageChrome ||
            sysPaddingKey != _paginatedSysPadding ||
            doublePage != _paginatedDoublePage ||
            widget.useZhLayout != _paginatedUseZhLayout ||
            widget.hangingPunctuation != _paginatedHangingPunctuation ||
            // [批16] 图片尺寸预测量完成/失败后触发一次重排；书级图片样式
            // 变化同样重排（纯文本章节两者不变 → 维持既有分页）
            ReaderImageSizeCache.revision != _paginatedImageRevision ||
            widget.imageStyle != _paginatedImageStyle);

    if (!needRepaginate) return;

    // [批16] 图片尺寸修订号变化且无其它排版变化时，保留当前阅读页
    // （避免异步测量完成后跳回章首）；其它重排仍沿用既有 currentChapterPos
    // 定位逻辑，保证纯文本行为零回归。
    final bool imageOnlyChange =
        ReaderImageSizeCache.revision != _paginatedImageRevision &&
        content == _paginatedContent &&
        chapterIndex == _paginatedChapterIndex &&
        fontSize == _paginatedFontSize &&
        lineHeight == _paginatedLineHeight &&
        spacing == _paginatedParagraphSpacing &&
        letterSpacing == _paginatedLetterSpacing &&
        indent == _paginatedIndent &&
        textBold == _paginatedTextBold &&
        italic == _paginatedItalic &&
        justify == _paginatedJustify &&
        fontFamily == _paginatedFontFamily &&
        baseStyle == _paginatedBaseStyle &&
        margins == _paginatedMargins &&
        widget.pageChrome.layoutKey == _paginatedPageChrome &&
        sysPaddingKey == _paginatedSysPadding &&
        doublePage == _paginatedDoublePage &&
        widget.useZhLayout == _paginatedUseZhLayout &&
        widget.hangingPunctuation == _paginatedHangingPunctuation &&
        widget.imageStyle == _paginatedImageStyle;

    // 计算可用尺寸（减去配置的页面边距）
    // [UI_SYNC_REFACTOR S4 修 | 2026-09-06] 去掉 ×0.95 缩减：测量已与渲染
    // 同源同参（整段 TextPainter 盒宽 + DefaultTextStyle + textScaler），
    // 且 _breakLines 末端有行宽安全网兜底，此前 5% 缩减只白白损失行宽。
    // 双页模式：每栏可用宽 =（屏宽 - 左右边距 - 16 栏间隙）/ 2，取两栏
    // 较小值——渲染侧左栏扣 marginLeft+8、右栏扣 marginRight+8，左右
    // 边距不对称时取小者才保证两栏都不越界 — Qoder
    final availableWidth = doublePage
        ? math.min(
            screenSize.width / 2 - widget.marginLeft - 8,
            screenSize.width / 2 - widget.marginRight - 8,
          )
        : screenSize.width - widget.marginLeft - widget.marginRight;
    // [UI-fix v2.0.4 | 2026-08-08] 分页可用高度与渲染容器严格一致：
    // 渲染侧（ReaderTypographicPage）Column = 首页标题块 +
    // Expanded(正文) + 页码指示（top 8 + 11 号文字）；此前用固定
    // 40 估算页脚且未扣首页标题块高度，满页正文首页底部
    // RenderFlex 溢出 ~16-27px（随字号增大）。改为 TextPainter 按
    // 渲染同参实测页脚与标题块高度，首页容量单独下发排版引擎 — Qoder
    final textScaler = MediaQuery.textScalerOf(context);
    final chrome = widget.pageChrome;
    final headerBlock = ReaderPageLayoutMetrics.headerBlockHeight(
      context,
      chrome,
    );
    final footerBlock = ReaderPageLayoutMetrics.footerBlockHeight(
      context,
      chrome,
    );
    // 预留 4px 保险余量：TextPainter 测量与 Text 实际渲染存在亚像素差
    //（基线/字距舍入），满页正文底部 RenderFlex 溢出 3px（书山等长正文
    // 复现）— 2026-08-17
    final availableHeight =
        screenSize.height -
        statusBarTop -
        sysPadding.bottom -
        headerBlock -
        footerBlock -
        widget.marginTop -
        widget.marginBottom -
        4.0;

    // 首页标题块高度（与渲染侧 pageIndex==0 分支同参）
    // [UI_SYNC_REFACTOR S6 修] 抽为 _computeFirstPageHeight：相邻章预载需按
    // 「目标章标题」计算首页容量（与落地实际分页一致，防切换重排闪动）— Qoder
    final chapterTitle = state.currentChapter?.title;
    // [批16] 章节基址：图片相对地址绝对化（chapter.baseUrl → url → bookUrl）
    final chapter = state.currentChapter;
    final imageBaseUrl = _chapterImageBaseUrl(state, chapter);
    final firstPage = _computeFirstPageHeight(
      state,
      availableHeight,
      availableWidth,
      chapterTitle,
      titleImageUrl: chapter?.imgUrl,
      titleImageBaseUrl: imageBaseUrl,
    );
    final firstPageHeight = firstPage.height;

    final config = ParagraphConfig(
      fontSize: fontSize,
      lineHeight: lineHeight,
      paragraphSpacing: spacing,
      // [UI-fix v2.0.4 | 2026-08-08] 缩进档位（0-3 字符）接入排版引擎；
      // 字重接入测量（与渲染同参）— Qoder
      indent: indent > 0 ? fontSize * indent : 0,
      indentCount: indent,
      fontWeight: _fontWeightFor(textBold),
      fontStyle: _fontStyleFor(italic),
      justify: justify,
      textColor: _resolveTextColor(state),
      backgroundColor: state.backgroundColor,
      letterSpacing: letterSpacing,
      fontFamily: fontFamily,
      // [UI-fix v2.0.5 | 2026-08-10] 中文分行开关接入排版引擎 — Reasonix
      useZhLayout: widget.useZhLayout,
      // [UI-fix v2.0.5 | 2026-08-10] 段首标点悬挂接入排版引擎 — Reasonix
      hangingPunctuation: widget.hangingPunctuation,
      // [UI_SYNC_REFACTOR S4 修 | 2026-09-06] 测量与渲染同参：渲染侧 Text
      // 继承 DefaultTextStyle 并应用系统文字缩放，测量侧同参注入 — Qoder
      baseStyle: baseStyle,
      textScaler: textScaler,
      // [批16] 正文行内图片：书级样式与章节基址传入排版引擎
      imageStyle: widget.imageStyle,
      imageBaseUrl: imageBaseUrl,
    );

    // [UI_SYNC_REFACTOR S6 修 | 2026-09-08] 记录分页参数（相邻章预载复用
    // 同参）并在章变更时清相邻章预览（防旧章预览/位图残留）— Qoder
    // [换源预览修复 | 2026-09-26] 换源后同章号内容被整章替换（index 不变），
    // 仅按章号判变会让章边界承接页残留旧源文本——内容变化同样清相邻章
    // 预览与在途标记，eager 预载随后以新源 bookUrl 重建 — Qoder
    final chapterChanged =
        _paginatedChapterIndex != chapterIndex || content != _paginatedContent;
    // [批16 三审] 书/章切换已在 build 的 _syncImageMeasureIdentity 处理；
    // 此处仅处理同章正文替换（刷新/换源内容变化），避免旧的测量会话写回。
    if (content != _paginatedContent) {
      _imageMeasureSession++;
      _cancelImageMeasurements();
    }
    _pagedConfig = config;
    _pagedWidth = availableWidth;
    _pagedHeight = availableHeight;
    if (chapterChanged) {
      _nextChapterPreview = null;
      _prevChapterPreview = null;
      _preloadingNext = false;
      _preloadingPrev = false;
    }

    final engine = ParagraphLayoutEngine(config: config, context: context);
    // [UI-fix v2.0.4 | 2026-08-08] 首页容量单独下发（扣标题块）— Qoder
    final pages = engine.paginateChapter(
      content,
      availableWidth,
      availableHeight,
      firstPageHeight: firstPageHeight,
    );

    _paginatedPages = pages;
    debugRepaginationCount++;
    _paginatedContent = content;
    _paginatedChapterIndex = chapterIndex;
    _paginatedBookUrl = state.currentBook?.bookUrl ?? '';
    _paginatedBookName = state.currentBook?.name ?? '';
    _paginatedBookOrigin = state.currentBook?.origin ?? '';
    _paginatedChapterTitle = state.currentChapter?.title;
    _paginatedFontSize = fontSize;
    _paginatedLineHeight = lineHeight;
    _paginatedParagraphSpacing = spacing;
    _paginatedLetterSpacing = letterSpacing;
    _paginatedIndent = indent;
    _paginatedTextBold = textBold;
    _paginatedItalic = italic;
    _paginatedJustify = justify;
    _paginatedFontFamily = fontFamily;
    _paginatedBaseStyle = baseStyle;
    _paginatedMargins = margins;
    _paginatedPageChrome = widget.pageChrome.layoutKey;
    _paginatedSysPadding = sysPaddingKey;
    _paginatedDoublePage = doublePage;
    _paginatedUseZhLayout = widget.useZhLayout;
    _paginatedHangingPunctuation = widget.hangingPunctuation;
    // [批16] 记录图片尺寸修订号/图片样式/首屏标题图布局（渲染与首页容量
    // 同源；纯文本章节 titleImage=null、不产生额外占位）
    _paginatedImageRevision = ReaderImageSizeCache.revision;
    _paginatedImageStyle = widget.imageStyle;
    // 首屏标题图布局直接复用首页容量计算的结果（同源，避免两处 maxHeight
    // 口径不一致导致溢出）
    _paginatedTitleImageLayout = firstPage.titleImageLayout;
    // [UI_SYNC_REFACTOR T3 修] 分页后按 currentChapterPos 定位：
    // -1 = 哨兵跳末页（prevChapter 场景）；其他值 = 跳到对应页
    final notifier = ref.read(readerNotifierProvider.notifier);
    final chapterPos = ref.read(readerNotifierProvider).currentChapterPos;
    if (imageOnlyChange && _paginatedPages.isNotEmpty) {
      // 图片尺寸异步就绪：保留当前页（clamp 到新页数）
      _currentPageIndex = _currentPageIndex.clamp(
        0,
        _paginatedPages.length - 1,
      );
    } else if (chapterPos == -1 && _paginatedPages.isNotEmpty) {
      // 哨兵：跳到本章最后一页
      _currentPageIndex = _paginatedPages.length - 1;
      Future(() => notifier.resetChapterPos());
    } else if (chapterPos > 0 && chapterPos < _paginatedPages.length) {
      _currentPageIndex = chapterPos;
    } else {
      _currentPageIndex = 0;
    }

    // 跨章节分页：注册本章页数到全局分页器
    // 注：本方法在 build 阶段调用，不可同步修改 provider（会触发
    // "modify a provider while the widget tree was building" 断言），延迟到下一帧
    Future(() => notifier.updateChapterPageCount(chapterIndex, pages.length));

    // [批16] 图片尺寸异步预测量：未命中尺寸缓存时发起下载/解码，完成后
    // revision 变化触发一次重排（测量失败写占位标记，不重试）。
    _measureReaderImages(content, chapter, imageBaseUrl, state.currentBook);

    // 章边界预载（页末预载下一章首屏 / 页首预载上一章末屏）
    _maybePreloadAdjacent(state, eager: true);
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(readerNotifierProvider);
    final notifier = ref.read(readerNotifierProvider.notifier);
    // [批34] 订阅高亮规则修订号：规则页保存/删除后重建，并让文本匹配缓存失效
    ref.watch(highlightRulesRevisionProvider);
    // [批16 三审 P2-4] 切章即取消旧章测量（loading 冻结期 build 仍会执行，
    // 不能等 repaginate 时才处理，否则旧章迟到结果会继续写回/下载）
    _syncImageMeasureIdentity(state);

    // [UI_SYNC_REFACTOR S4 修 | 2026-09-06] 章节切换加载中：保留上一章
    // 既有分页渲染（跳过重分页）——此前直接整树换成 LoadingIndicator，
    // cover 模式 AnimatedSwitcher 子树被卸载，加载完重新挂载时已无旧
    // child，过渡动画永不触发（章节切换翻页动画失效根因）。冻结期间
    // 键以 _paginatedChapterIndex 为章标识保持不变，加载完成重分页后
    // 键变化恰好触发一次"旧页 → 新页"过渡。首次打开（无既有分页）
    // 仍显示加载指示。
    if (state.isLoading && _paginatedPages.isEmpty) {
      return LoadingIndicator(message: AppStrings.loadingChapter);
    }
    if (state.isLoading && state.error == null) {
      // 冻结帧：不重分页、不响应排版参数变化（加载完成后统一重算）
      return _buildContent(context, state, repaginate: false);
    }

    // [F1-hunt F4 | 2026-09-24] 全屏 ErrorView 仅在「正文为空」时生效：
    // 章节加载失败（_loadChapterContent 失败路径已清空正文）→ 全屏错误
    // 页（重试/换源）；「刷新正文失败 / 换源重载失败」保留旧正文（不清
    // 空）并置 error → 此处不降级，仍渲染旧正文，失败由调用方 SnackBar
    // （「刷新正文失败：…」「更换书源后重载失败：…」）提示，避免刷新
    // 失败把整屏可读正文换成错误页（F4 缺陷②「刷新失败全屏降级」）
    if (state.error != null && state.chapterContent.isEmpty) {
      final book = state.currentBook;
      // [fix Task#24 | 2026-08-08] 正文/章节加载失败（如「正文为空」，多由换源
      // 匹配错书导致）时，除「重试」外引导用户「换源」逃离坏书源（对齐原版）— Qoder
      final isOnline = book != null && !BookType.isLocalOrigin(book.origin);
      return ErrorView(
        message: state.error!,
        onRetry: () {
          if (book != null) {
            notifier.openBook(book);
          }
        },
        onSecondaryAction: isOnline
            ? () => Navigator.pushNamed(
                context,
                AppRoutes.changeSource,
                arguments: book,
              )
            : null,
        secondaryActionLabel: '换源',
        secondaryActionIcon: Icons.swap_horiz,
      );
    }

    // [C4-hunt | 2026-09-24] 成功但正文为空（章节无正文 / 源返回空）：
    // 旧版渲染纯空白页且无任何提示（C4 缺陷）。现居中显示可见提示。
    // 不影响前置分支：加载中（LoadingIndicator）、冻结帧（isLoading &&
    // error == null）、F4 全屏 ErrorView（error != null && 正文为空）。
    if (state.error == null &&
        !state.isLoading &&
        state.currentBook != null &&
        state.chapters.isNotEmpty &&
        state.chapterContent.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text(
            '本章无正文',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: state.fontSize,
              color: _resolveTextColor(state),
            ),
          ),
        ),
      );
    }

    return _buildContent(context, state, repaginate: true);
  }

  /// 组装正文内容（ [_paginateIfNeeded] 的触发时机集中在此）
  Widget _buildContent(
    BuildContext context,
    ReaderState state, {
    required bool repaginate,
  }) {
    if (repaginate) {
      // 排版引擎：检测是否需要重新分页
      _paginateIfNeeded(context, state);
    }
    // [批34] 高亮匹配：与分页解耦，命中到达后仅重建渲染层
    _syncHighlightMatches(state);
    // [批4d] 书签增删/加载完成后重建页内角标与手势状态
    ref.watch(bookmarkNotifierProvider.select((s) => s.bookmarks));

    final Widget content;
    // [UI_SYNC_REFACTOR S6 重构 | 2026-09-08] 翻页动画层整体替换为重构版
    // 系统（移植自 legado_flutter/features/reader/turn：快照缓存+拖拽控制器
    // +覆盖/滑动/仿真三画笔，数学对齐 Jingshiro/原版五委托）；滚动模式保留
    // 纵向滚动实现 — Qoder
    if (state.pageTurnMode == PageTurnMode.scroll) {
      content = _buildScrollContent(state);
    } else {
      content = _buildTurnContent(state);
    }

    // [UI-fix v2.0.4 | 2026-08-08] 鼠标滚轮翻页（对标原版 mouseWheelPage）：
    // 分页模式下用顶层覆盖 Listener 拦截滚轮事件（内层 PageView 的
    // Scrollable 在命中测试中先注册 pointerSignalResolver 会胜出，
    // 覆盖层居顶保证先注册；translucent 不影响下层点击/拖拽）；
    // 滚动模式不拦截，滚轮交给正文 Scrollable 自然滚动 — Qoder
    final Widget result;
    if (state.pageTurnMode == PageTurnMode.scroll || !widget.mouseWheelPage) {
      result = content;
    } else {
      result = Stack(
        children: [
          content,
          Positioned.fill(
            child: Listener(
              behavior: HitTestBehavior.translucent,
              onPointerSignal: _handlePointerSignal,
              child: const SizedBox.expand(),
            ),
          ),
        ],
      );
    }

    // [fix Task#41 | 2026-08-09] pageTouchSlop 消费点（对标原版
    // ReadView.upPageSlopSquare：0=系统默认值，非 0 用自定义阈值）：
    // 经 MediaQuery.gestureSettings 覆写内层 PageView/Scrollable 拖拽
    // 识别器的 touchSlop；面板修改经 readerAdvConfigProvider watch 触发
    // 重建即时生效（Scrollable.didChangeDependencies 重读 gestureSettings），
    // 无需重启阅读页
    // [fix Task#45 | 2026-08-09] 滚动模式不包裹（M3）：原版该阈值仅
    // 作用于横向翻页手势，滚动模式正文纵向起拖不应被放大阈值，
    // 强制取 0 走系统默认；其余模式保持现实现 — Qoder
    final advCfg = ref.watch(readerAdvConfigProvider);
    final slop = state.pageTurnMode == PageTurnMode.scroll
        ? 0
        : (advCfg?.pageTouchSlop ?? 0);
    return _applyPageTouchSlop(context, result, slop);
  }

  // ===== [批34] 正文高亮匹配 =====

  /// 同步当前章节命中（缓存命中直接换值；未命中发起一次异步匹配）
  ///
  /// 在 build 内调用：缓存命中时只更新字段，不触发 setState（值本帧即用）；
  /// 异步结果到达后 setState 一次。键计算/命中/未命中/换章清空/旧结果丢弃
  /// 与失败退避全部收敛在 [HighlightMatchSync]（批34b P2-1）。
  ///
  /// 以**已分页内容**为准（加载冻结帧仍显示旧章正文，若用 state 的新章
  /// 文本/章号会让旧页短暂失去高亮或套错区间）；未分页时回退 state。
  void _syncHighlightMatches(ReaderState state) {
    final book = state.currentBook;
    final usePaginated = _paginatedContent.isNotEmpty;
    final content = usePaginated ? _paginatedContent : state.chapterContent;
    final chapterIndex = usePaginated
        ? _paginatedChapterIndex
        : state.currentChapterIndex;
    final bookUrl = usePaginated && _paginatedBookUrl.isNotEmpty
        ? _paginatedBookUrl
        : (book?.bookUrl ?? '');
    final bookName = usePaginated && _paginatedBookName.isNotEmpty
        ? _paginatedBookName
        : (book?.name ?? '');
    final bookOrigin = usePaginated && _paginatedBookOrigin.isNotEmpty
        ? _paginatedBookOrigin
        : (book?.origin ?? '');

    _highlightMatches = _highlightSync.sync(
      HighlightMatchRequest(
        // 滚动模式同样加载并渲染高亮（分页/滚动共用章节全局坐标）
        enabled: book != null,
        bookUrl: bookUrl,
        bookName: bookName,
        origin: bookOrigin,
        chapterIndex: chapterIndex,
        content: content,
        rulesRevision: ref.read(highlightRulesRevisionProvider),
      ),
      load: _loadHighlightMatches,
      onLoaded: _onHighlightLoaded,
    );
    // [批7b-2b] 用户笔记：watch 修订号，保存/启停/删除后即时重算
    _syncMarkingMatches(
      enabled: book != null,
      content: content,
      bookUrl: bookUrl,
      chapterIndex: chapterIndex,
      revision: ref.watch(bookMarkingsRevisionProvider),
    );
    // 手动高亮（highlights 表）：按章加载已存记录并并入正文渲染。
    // watch 修订号——阅读器保存高亮成功后自增，立即重拉当前章（缺陷修复）。
    _syncSavedHighlightMatches(
      enabled: book != null,
      content: content,
      bookUrl: bookUrl,
      chapterIndex: chapterIndex,
      revision: ref.watch(bookHighlightsRevisionProvider),
    );
    _combinedHighlightMatches = mergeHighlightMarkingAndSavedMatches(
      rules: _highlightMatches,
      marks: _markingMatches,
      saved: _savedHighlightMatches,
    );
  }

  /// 同步当前章笔记命中（批7b-2b）
  ///
  /// 键 = 书 + 章 + 已分页正文（长度/hash）+ 笔记修订号；键变化先清空旧
  /// 命中再异步加载，避免新章/换书短暂套用上一章区间。失败清空，下一次
  /// build 重试（单 key 最多 2 次）。滚动模式同样加载并渲染（正文坐标与
  /// 分页同源，均为章节全局 UTF-16 偏移）。
  void _syncMarkingMatches({
    required bool enabled,
    required String content,
    required String bookUrl,
    required int chapterIndex,
    required int revision,
  }) {
    if (!enabled || content.isEmpty || bookUrl.isEmpty) {
      _markingMatches = const [];
      _markingKey = '';
      _markingLoadingKey = '';
      _markingIdentityKey = '';
      return;
    }
    final identityKey =
        '$bookUrl\u0000$chapterIndex\u0000${content.length}'
        '\u0000${content.hashCode}';
    if (identityKey != _markingIdentityKey) {
      // 切章/换书/正文变化：重置重试预算与失败退避
      _markingIdentityKey = identityKey;
      _markingAttempts.clear();
    }
    final key = '$identityKey\u0000$revision';
    if (key == _markingKey) return;

    // 换章/换书/正文或修订号变化：先清旧命中
    _markingMatches = const [];
    if (_markingLoadingKey == key) {
      _markingKey = key;
      return;
    }
    final attempts = _markingAttempts[key] ?? 0;
    if (attempts >= _maxMarkingAttempts) {
      // 重试预算耗尽：记为当前 key，后续 build 不再重复请求
      _markingKey = key;
      return;
    }
    _markingAttempts[key] = attempts + 1;
    _markingKey = key;
    _markingLoadingKey = key;
    unawaited(_loadMarkingMatches(key, content, bookUrl, chapterIndex));
  }

  /// 异步加载当前章笔记并解析为命中区间
  Future<void> _loadMarkingMatches(
    String key,
    String content,
    String bookUrl,
    int chapterIndex,
  ) async {
    try {
      final markings = await ref
          .read(bookApiProvider)
          .getBookMarkingsForChapter(bookUrl, chapterIndex);
      if (!mounted || _markingKey != key) return;
      final matches = buildMarkingMatches(content: content, markings: markings);
      _markingAttempts.remove(key);
      setState(() {
        _markingMatches = matches;
        _combinedHighlightMatches = mergeHighlightMarkingAndSavedMatches(
          rules: _highlightMatches,
          marks: _markingMatches,
          saved: _savedHighlightMatches,
        );
      });
    } catch (e) {
      // 旧请求失败不得清空新章已采纳的标记（P2-1）
      if (!mounted || _markingKey != key) return;
      // 笔记是增益能力：失败降级为无标记；下一次 build 重试，
      // 单 key 最多 2 次（attempts 在成功/换章/换书/正文变化时重置）
      _markingKey = '';
      setState(() {
        _markingMatches = const [];
        _combinedHighlightMatches = mergeHighlightMarkingAndSavedMatches(
          rules: _highlightMatches,
          marks: _markingMatches,
          saved: _savedHighlightMatches,
        );
      });
      debugPrint(
        '[book-marking] 笔记正文匹配失败（已降级为无标记；'
        '单 key 最多 $_maxMarkingAttempts 次，下一次 build 重试）: $e',
      );
    } finally {
      if (_markingLoadingKey == key) _markingLoadingKey = '';
    }
  }

  /// 同步当前章已存手动高亮（highlights 表）
  ///
  /// 缺陷修复：以往正文渲染只消费 `highlight_rules` 规则命中，
  /// `highlightListByChapter` 无调用方——用户保存的高亮只能出现在目录
  /// 「标注」列表，正文内联永不渲染。
  ///
  /// 键 = 书 + 章 + 已分页正文（长度/hash）+ 手动高亮修订号；键变化先
  /// 清空旧命中再异步加载，避免新章/换书短暂套用上一章区间。失败清空，
  /// 下一次 build 重试（单 key 最多 2 次）。滚动模式同样加载并渲染
  /// （正文坐标与分页同源，均为章节全局 UTF-16 偏移）。
  void _syncSavedHighlightMatches({
    required bool enabled,
    required String content,
    required String bookUrl,
    required int chapterIndex,
    required int revision,
  }) {
    if (!enabled || content.isEmpty || bookUrl.isEmpty) {
      _savedHighlightMatches = const [];
      _savedHighlightKey = '';
      _savedHighlightLoadingKey = '';
      _savedHighlightIdentityKey = '';
      return;
    }
    final identityKey =
        '$bookUrl\u0000$chapterIndex\u0000${content.length}'
        '\u0000${content.hashCode}';
    if (identityKey != _savedHighlightIdentityKey) {
      // 切章/换书/正文变化：重置重试预算与失败退避
      _savedHighlightIdentityKey = identityKey;
      _savedHighlightAttempts.clear();
    }
    final key = '$identityKey\u0000$revision';
    if (key == _savedHighlightKey) return;

    // 换章/换书/正文或修订号变化：先清旧命中（切章不得残留旧章高亮）
    _savedHighlightMatches = const [];
    if (_savedHighlightLoadingKey == key) {
      _savedHighlightKey = key;
      return;
    }
    final attempts = _savedHighlightAttempts[key] ?? 0;
    if (attempts >= _maxSavedHighlightAttempts) {
      // 重试预算耗尽：记为当前 key，后续 build 不再重复请求
      _savedHighlightKey = key;
      return;
    }
    _savedHighlightAttempts[key] = attempts + 1;
    _savedHighlightKey = key;
    _savedHighlightLoadingKey = key;
    unawaited(_loadSavedHighlightMatches(key, content, bookUrl, chapterIndex));
  }

  /// 异步加载当前章手动高亮并解析为命中区间
  ///
  /// 坐标：`highlights.chapterPos/chapterPosEnd` 已是章节正文 UTF-16 偏移
  /// （保存侧 `chapterOffsetOfSelection` 已扣除首行缩进），解析见
  /// [buildSavedHighlightMatches]；不得在此再叠加/扣除缩进列。
  Future<void> _loadSavedHighlightMatches(
    String key,
    String content,
    String bookUrl,
    int chapterIndex,
  ) async {
    try {
      final raw = await ref
          .read(bookApiProvider)
          .highlightListByChapter(bookUrl: bookUrl, chapterIndex: chapterIndex);
      if (!mounted || _savedHighlightKey != key) return;
      final matches = buildSavedHighlightMatches(
        content: content,
        rawJson: raw,
      );
      _savedHighlightAttempts.remove(key);
      setState(() {
        _savedHighlightMatches = matches;
        _combinedHighlightMatches = mergeHighlightMarkingAndSavedMatches(
          rules: _highlightMatches,
          marks: _markingMatches,
          saved: _savedHighlightMatches,
        );
      });
    } catch (e) {
      // 旧请求失败不得清空新章已采纳的高亮
      if (!mounted || _savedHighlightKey != key) return;
      // 高亮是增益能力：失败降级为无高亮，不影响正文阅读
      _savedHighlightKey = '';
      setState(() {
        _savedHighlightMatches = const [];
        _combinedHighlightMatches = mergeHighlightMarkingAndSavedMatches(
          rules: _highlightMatches,
          marks: _markingMatches,
          saved: _savedHighlightMatches,
        );
      });
      debugPrint(
        '[highlight] 手动高亮加载失败（已降级为无高亮；'
        '单 key 最多 $_maxSavedHighlightAttempts 次，下一次 build 重试）: $e',
      );
    } finally {
      if (_savedHighlightLoadingKey == key) _savedHighlightLoadingKey = '';
    }
  }

  /// 跨 FFI 匹配正文（失败由 [HighlightMatchSync] 降级为无高亮，不影响阅读）
  Future<String> _loadHighlightMatches({
    required String text,
    required String bookName,
    required String origin,
  }) {
    return ref
        .read(bookApiProvider)
        .highlightRuleMatch(text: text, bookName: bookName, origin: origin);
  }

  /// 异步命中被采纳：仅重建渲染层，不触发重分页
  void _onHighlightLoaded() {
    if (!mounted) return;
    setState(() {
      _highlightMatches = _highlightSync.matches;
      // 规则先/后到都重算合并（笔记/手动高亮先到时不丢）
      _combinedHighlightMatches = mergeHighlightMarkingAndSavedMatches(
        rules: _highlightMatches,
        marks: _markingMatches,
        saved: _savedHighlightMatches,
      );
    });
  }

  /// 按 pageTouchSlop 包裹自定义滑动阈值（0=系统默认值，不包裹）
  Widget _applyPageTouchSlop(BuildContext context, Widget child, int slop) {
    if (slop <= 0) return child;
    return MediaQuery(
      data: MediaQuery.of(context).copyWith(
        gestureSettings: DeviceGestureSettings(touchSlop: slop.toDouble()),
      ),
      child: child,
    );
  }

  /// 滚轮事件处理：下滚下一页 / 上滚上一页（300ms 节流）
  void _handlePointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent) return;
    GestureBinding.instance.pointerSignalResolver.register(event, (e) {
      final scroll = e as PointerScrollEvent;
      final now = DateTime.now();
      if (now.difference(_lastWheelTurn).inMilliseconds < 300) return;
      _lastWheelTurn = now;
      if (scroll.scrollDelta.dy > 0) {
        nextPageOrChapter();
      } else if (scroll.scrollDelta.dy < 0) {
        prevPageOrChapter();
      }
    });
  }

  /// textBold 档位 → FontWeight（0中/1粗/2细，对标原版
  /// TextFontWeightConverter 的 normal/bold/light）
  /// [C3 斜体 | Qoder UI] 斜体样式映射（测量/渲染同源调用）
  FontStyle? _fontStyleFor(bool italic) => italic ? FontStyle.italic : null;

  FontWeight? _fontWeightFor(int bold) {
    switch (bold) {
      case 1:
        return FontWeight.w700;
      case 2:
        return FontWeight.w300;
      default:
        return null;
    }
  }

  /// 解析正文文字颜色：自定义色优先；自定义背景（非预设）按亮度
  /// 自适应深/浅文字色；否则沿用预设派生色（state.textColor）
  Color _resolveTextColor(ReaderState state) {
    if (widget.customTextColor != 0) return Color(widget.customTextColor);
    if (!ReaderBackground.presets.contains(state.backgroundColor)) {
      return state.backgroundColor.computeLuminance() < 0.5
          ? const Color(0xFFCCCCCC)
          : const Color(0xFF333333);
    }
    return state.textColor;
  }

  /// 正文 viewport：工具栏为 Stack overlay，显隐不得改变正文布局约束
  /// （对标原版 ReadView 全屏 + ReadMenu 浮层；此前 showControls 联动
  /// SafeArea 导致切换工具栏时正文上跳并重算分页）— Cursor UI
  ///
  /// 未隐藏状态栏时恒定预留 viewPadding.top（与分页扣减一致），避免
  /// 章节标题/页眉绘制到系统状态栏区域；hideStatusBar 时不预留，以免
  /// 切换 ReadMenu 时正文位移。
  Widget _contentViewport(BuildContext context, Widget child) {
    final top = readerContentStatusBarInset(
      context,
      hideStatusBar: widget.pageChrome.hideStatusBar,
      readBodyToLh: widget.readBodyToLh,
    );
    if (top <= 0) return child;
    return Padding(
      padding: EdgeInsets.only(top: top),
      child: child,
    );
  }

  /// 首页可用高度与标题图布局（扣标题块；与渲染侧 pageIndex==0 同参）
  ///
  /// [批16 回修 P2-7] 标题图的 maxHeight 扣除标题文本与上下间距，避免
  /// 竖长标题图 + 标题块超出首页可用高；返回值中的布局直接用于渲染，
  /// 保证「容量计算 / 实际绘制」同源。
  ({double height, ReaderImageLayout? titleImageLayout})
  _computeFirstPageHeight(
    ReaderState state,
    double availableHeight,
    double availableWidth,
    String? chapterTitle, {
    String? titleImageUrl,
    String titleImageBaseUrl = '',
  }) {
    var firstPageHeight = availableHeight;
    if (chapterTitle == null) {
      return (height: firstPageHeight, titleImageLayout: null);
    }
    final chrome = widget.pageChrome;
    final showTitle = chrome.titleMode.clamp(0, 2) != 2;
    if (!showTitle) {
      // 标题隐藏：保持既有「至少一行正文」兜底
      final minHeight = state.fontSize * state.lineHeight;
      if (firstPageHeight < minHeight) firstPageHeight = minHeight;
      return (height: firstPageHeight, titleImageLayout: null);
    }
    final textScaler = MediaQuery.textScalerOf(context);
    final baseStyle = DefaultTextStyle.of(context).style;
    // [C3 标题字体] 标题 fontFamily 与渲染侧同参（effectiveTitleFontFamily
    // 单源，空=跟随正文），不同参会首页标题行分页错位 — full-stack-engineer
    final titlePainter = TextPainter(
      text: TextSpan(
        text: chapterTitle,
        style: baseStyle.merge(
          TextStyle(
            fontSize: state.fontSize + chrome.titleSize,
            fontWeight: FontWeight.bold,
            fontFamily: effectiveTitleFontFamily(
              chrome,
              _resolveReaderFontFamily(context),
            ),
          ),
        ),
      ),
      textDirection: TextDirection.ltr,
      textScaler: textScaler,
    )..layout(maxWidth: availableWidth);
    final titleBlockHeight =
        titlePainter.height +
        chrome.titleTopSpacing +
        chrome.titleBottomSpacing;
    titlePainter.dispose();

    // 标题图可用高 = 首页总高 - 标题文本块 - 图片与标题间距（6）
    final titleImageMaxHeight = math.max(
      0.0,
      availableHeight - titleBlockHeight - 6,
    );
    final titleImageLayout = titleImageMaxHeight <= 0
        ? null
        : _buildTitleImageLayout(
            imgUrl: titleImageUrl,
            baseUrl: titleImageBaseUrl,
            availableWidth: availableWidth,
            maxHeight: titleImageMaxHeight,
            fontSize: state.fontSize,
            lineHeight: state.lineHeight,
          );
    firstPageHeight = availableHeight - titleBlockHeight;
    if (titleImageLayout != null) {
      firstPageHeight -= titleImageLayout.height + 6;
    } else {
      // 无标题图：极端小窗口兼底，首页至少容纳一行正文
      final minHeight = state.fontSize * state.lineHeight;
      if (firstPageHeight < minHeight) firstPageHeight = minHeight;
    }
    if (firstPageHeight < 0) firstPageHeight = 0;
    return (height: firstPageHeight, titleImageLayout: titleImageLayout);
  }

  /// [批16] 章节图片绝对化基址：chapter.baseUrl → chapter.url → bookUrl
  ///
  /// [批16 三审 P3-8] iOS 本地书 bookUrl/chapter.url 可能是相对
  /// Documents 的可迁移标识（`books/x.epub`），先经
  /// [LocalBookStore.resolveSync] 解析为真实路径；在线 URL 原样返回。
  String _chapterImageBaseUrl(ReaderState state, BookChapter? chapter) {
    String resolve(String value) {
      final raw = value.trim();
      return raw.isEmpty ? '' : LocalBookStore.resolveSync(raw);
    }

    final base = resolve(chapter?.baseUrl ?? '');
    if (base.isNotEmpty) return base;
    final url = resolve(chapter?.url ?? '');
    if (url.isNotEmpty) return url;
    return resolve(state.currentBook?.bookUrl ?? '');
  }

  /// [批16] 章节标题图布局（首屏容量计算与渲染共用，尺寸未知用占位高度）
  ReaderImageLayout? _buildTitleImageLayout({
    required String? imgUrl,
    required String baseUrl,
    required double availableWidth,
    required double maxHeight,
    required double fontSize,
    required double lineHeight,
  }) {
    final image = readerChapterTitleImage(
      imgUrl: imgUrl,
      chapterBaseUrl: baseUrl,
      bookUrl: ref.read(readerNotifierProvider).currentBook?.bookUrl ?? '',
    );
    if (image == null) return null;
    return resolveReaderImageLayout(
      image: image,
      availableWidth: availableWidth,
      maxHeight: maxHeight,
      textLineHeight: fontSize * lineHeight,
      inlineSlotWidth: fontSize * 0.5,
      bookImageStyle: widget.imageStyle,
      // 标题图始终按独立块渲染（标题行不做行内 WidgetSpan 混排）
      forceStandalone: true,
    );
  }

  /// [批16] 正文图片渲染配置（字节加载/点击档位/预览与动作回调）
  ReaderImageRenderConfig _imageRenderConfig(ReaderState state) {
    final book = state.currentBook;
    final onlineText =
        book != null &&
        !BookType.isLocalBook(book) &&
        (book.bookType & BookType.text) != 0;
    return ReaderImageRenderConfig(
      loader: _loadReaderImageBytes,
      clickImgWay: widget.clickImgWay,
      onlineText: onlineText,
      onPreview: _previewReaderImage,
      // [批20-A] 图片 click/js 动作执行（契约 §2.21）
      onRunAction: _runReaderImageAction,
      cacheOrigin: book?.origin ?? '',
      // 渲染成功回填尺寸后触发一次合并重排（P2-8）
      onSizeResolved: _scheduleImageReflow,
    );
  }

  /// [批20-A] 执行正文图片的书源 `click`/`js` 动作（契约 §2.21）
  ///
  /// 对齐参考版 `ReadBookController.clickImg` 的 onError：执行失败只记录
  /// 日志、不打断阅读（Rust 侧对动作抛错/超时已降级为空串，无 quickjs
  /// 构建在此吞掉明确错误）。
  ///
  /// [批21-A] 按 Rust 返回的 UI action 信封回放副作用：toast/longToast →
  /// SnackBar（含动态拼接消息），showBrowser/startBrowser/openUrl → 复用
  /// `PlatformBridgeService` 既有桥接策略（拦截设置/二次确认/深链分流）；
  /// 旧 Rust 纯字符串返回值仍保留静态字面量 toast 降级提示。
  Future<void> _runReaderImageAction(String action, String imgSrc) async {
    if (!mounted) return;
    final bookUrl = _paginatedBookUrl.isNotEmpty
        ? _paginatedBookUrl
        : (ref.read(readerNotifierProvider).currentBook?.bookUrl ?? '');
    if (bookUrl.isEmpty) return;
    final hint = clickImgToastHint(action);
    try {
      final outcome = await ref
          .read(bookApiProvider)
          .evalImageActionOutcome(
            bookUrl,
            _displayChapterIndex,
            action,
            imgSrc,
          );
      if (!mounted) return;
      if (outcome.actions.isNotEmpty) {
        await replayImageActionSideEffects(
          outcome.actions,
          onToast: (message, {required bool isLong}) {
            if (!mounted) return;
            ScaffoldMessenger.maybeOf(context)?.showSnackBar(
              SnackBar(
                content: Text(message),
                duration: Duration(seconds: isLong ? 5 : 2),
              ),
            );
          },
        );
      } else if (hint != null) {
        // 兼容旧 Rust 返回值（无 actions 信封）：静态字面 toast 降级提示
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          SnackBar(
            content: Text(hint.message),
            duration: Duration(seconds: hint.isLong ? 5 : 2),
          ),
        );
      }
    } catch (e) {
      // 动作执行失败不打断阅读（无 quickjs 构建等明确错误在此可见）
      debugPrint('[reader] 图片动作执行失败（已忽略）：$e');
    }
  }

  /// [批16] 打开正文图片预览（复用既有全屏查看器，复合 headers 透传）
  void _previewReaderImage(ReaderInlineImage image) {
    if (!mounted) return;
    showRssPhotoViewer(
      context,
      url: stripCompositeImageUrl(image.options.url),
      headers: image.options.headers,
    );
  }

  /// [批16] 下载/解码正文图片字节（书源 imageDecode 走 FFI，本地书读盘，
  /// 其余走 HTTP；结果进 LRU 缓存供渲染与尺寸测量共用）。
  ///
  /// [批16 三审 P2-3/P3-7/P3-8/P3-10/P3-12]
  /// - 本地路径按「书文件真实存在 + 目录围栏」准入，不依赖类型位/来源；
  /// - 所有文件读取做位图魔数校验；
  /// - data URI 本地 base64 解码，不走 HTTP；
  /// - HTTP 兜底仅 http/https，且 10s 超时；
  /// - 失败分类：网络/超时 → [network]（可跨章重试）；路径/格式/解码 →
  ///   [permanent]。
  Future<Uint8List?> _loadReaderImageBytes(ReaderInlineImage image) async =>
      (await _loadReaderImageResult(image)).bytes;

  Future<_ReaderImageFetchResult> _loadReaderImageResult(
    ReaderInlineImage image,
  ) {
    final book = ref.read(readerNotifierProvider).currentBook;
    final origin = book?.origin ?? '';
    final cacheKey = ReaderImageBytesCache.keyOf(origin, image.rawSrc);
    final cacheHit = ReaderImageBytesCache.get(origin, image.rawSrc);
    if (cacheHit != null) {
      return Future.value(_ReaderImageFetchResult.ok(cacheHit));
    }
    final inflight = _imageLoads[cacheKey];
    if (inflight != null) return inflight;
    final future = _fetchReaderImageBytes(image, book);
    _imageLoads[cacheKey] = future;
    return future.whenComplete(() {
      _imageLoads.remove(cacheKey);
    });
  }

  Future<_ReaderImageFetchResult> _fetchReaderImageBytes(
    ReaderInlineImage image,
    Book? book,
  ) async {
    final origin = book?.origin ?? '';
    const permanent = _ReaderImageFetchResult.failed(
      _ReaderImageFailureKind.permanent,
    );
    const network = _ReaderImageFetchResult.failed(
      _ReaderImageFailureKind.network,
    );
    try {
      final url = image.options.url;
      // data: URI 本地解码（对齐 P3-10）
      final dataBytes = decodeReaderDataUriImage(url);
      if (dataBytes != null) {
        if (!looksLikeImageBytes(dataBytes)) return permanent;
        ReaderImageBytesCache.put(origin, image.rawSrc, dataBytes);
        return _ReaderImageFetchResult.ok(dataBytes);
      }
      // 本地文件：bookUrl 解析为真实路径（iOS 相对标识经 resolveSync），
      // 文件不存在 / 目录外 / 非图片一律拒绝（与书籍类型位无关）。
      if (isReaderLocalFilePath(url)) {
        final bookPath = LocalBookStore.resolveSync(book?.bookUrl ?? '');
        if (bookPath.isEmpty || bookPath.contains('://')) return permanent;
        final file = await resolveReaderLocalImageFile(
          url: url,
          bookFilePath: bookPath,
        );
        if (file == null) return permanent;
        final bytes = await file.readAsBytes();
        if (!looksLikeImageBytes(bytes)) return permanent;
        ReaderImageBytesCache.put(origin, image.rawSrc, bytes);
        return _ReaderImageFetchResult.ok(bytes);
      }
      // 非 http/https（content:/cbz:// 等）一律拒绝，收紧 SSRF/协议面
      if (!isReaderHttpImageUrl(url)) return permanent;
      // 在线书：优先书源 FFI（含 imageDecode / Referer / Cookie 链路）
      if (origin.trim().isNotEmpty) {
        await _ensureReaderImageSource(origin);
        final source = _readerImageSource;
        if (source != null) {
          try {
            final json = await ref
                .read(bookApiProvider)
                .fetchImageWithDecode(image.rawSrc, jsonEncode(source.toJson()))
                .timeout(const Duration(seconds: 15));
            final decoded = jsonDecode(json);
            final b64 = decoded is Map
                ? decoded['base64'] as String? ?? ''
                : '';
            if (b64.isEmpty) return permanent;
            final bytes = base64Decode(b64);
            if (!looksLikeImageBytes(bytes)) return permanent;
            ReaderImageBytesCache.put(origin, image.rawSrc, bytes);
            return _ReaderImageFetchResult.ok(bytes);
          } catch (_) {
            // FFI 下载/解密异常：按网络类失败处理，允许跨章重试
            return network;
          }
        }
      }
      // 无书源/本地书兜底：HTTP GET（复合 headers 透传，10s 超时）
      final uri = Uri.tryParse(url);
      if (uri == null) return permanent;
      try {
        final response = await http
            .get(uri, headers: image.options.headers)
            .timeout(const Duration(seconds: 10));
        if (response.statusCode != 200) return network;
        final bytes = response.bodyBytes;
        if (!looksLikeImageBytes(bytes)) return permanent;
        ReaderImageBytesCache.put(origin, image.rawSrc, bytes);
        return _ReaderImageFetchResult.ok(bytes);
      } catch (_) {
        return network;
      }
    } catch (_) {
      return network;
    }
  }

  Future<void> _ensureReaderImageSource(String origin) {
    if (_readerImageSourceOrigin == origin) {
      return _readerImageSourceLoading ?? Future.value();
    }
    _readerImageSourceOrigin = origin;
    _readerImageSource = null;
    final loading = () async {
      try {
        final sources = await ref.read(bookApiProvider).getBookSources();
        for (final source in sources) {
          if (source.bookSourceUrl == origin) {
            _readerImageSource = source;
            return;
          }
        }
      } catch (_) {
        // 书源不可用：回落 HTTP 直连
      }
    }();
    _readerImageSourceLoading = loading;
    return loading;
  }

  /// [批16] 异步预测量本章图片尺寸（含标题图）
  ///
  /// [批16 回修 P1-1]
  /// - 未命中结果才发起；`beginMeasure` 在真正开始下载**前**调用，
  ///   取消（换书/切章/销毁）只回滚在途标记、不写失败，可重新测量；
  /// - 串行逐图测量，但每张完成**立即**写回尺寸并触发一次合并重排；
  /// - 第 N 张挂起不影响前 N-1 张生效。
  void _measureReaderImages(
    String content,
    BookChapter? chapter,
    String baseUrl,
    Book? book,
  ) {
    final images = <ReaderInlineImage>[
      ...collectReaderInlineImages(content, baseUrl: baseUrl),
    ];
    final titleImage = readerChapterTitleImage(
      imgUrl: chapter?.imgUrl,
      chapterBaseUrl: baseUrl,
      bookUrl: book?.bookUrl ?? '',
    );
    if (titleImage != null) images.add(titleImage);

    if (_imageMeasureRunning) return;

    final pending = <ReaderInlineImage>[];
    final seen = <String>{};
    for (final image in images) {
      if (!seen.add(image.rawSrc)) continue;
      final existing = ReaderImageSizeCache.lookup(image.rawSrc);
      if (existing != null) {
        if (existing.isValid) continue;
        // 永久失败（解码/格式/路径）不再重试；网络类失败允许跨章重试
        if (!existing.retryable) continue;
      }
      if (_imageMeasureAttempted.contains(image.rawSrc) ||
          ReaderImageSizeCache.isMeasuring(image.rawSrc)) {
        continue;
      }
      pending.add(image);
    }
    if (pending.isEmpty) return;

    _imageMeasureRunning = true;
    ReaderImageSizeCache.beginMeasureBatch();
    final session = _imageMeasureSession;
    final bookUrl = book?.bookUrl ?? '';
    final origin = book?.origin ?? '';
    unawaited(() async {
      var changed = false;
      try {
        for (final image in pending) {
          if (!mounted || session != _imageMeasureSession) return;
          final live = ref.read(readerNotifierProvider);
          if ((live.currentBook?.bookUrl ?? '') != bookUrl ||
              (live.currentBook?.origin ?? '') != origin) {
            // 换书/换源：取消本次会话剩余在途标记（不写失败）
            _imageMeasureSession++;
            _cancelImageMeasurements();
            return;
          }
          // 标记在真正开始下载前（取消可回滚）
          if (!ReaderImageSizeCache.beginMeasure(image.rawSrc)) continue;
          _imageMeasureKeys[image.rawSrc] = session;
          _imageMeasureAttempted.add(image.rawSrc);
          ReaderImageSize? size;
          var retryable = true;
          try {
            final measurer = widget.imageMeasurer;
            if (measurer != null) {
              size = await measurer(image);
              retryable = true;
            } else {
              final result = await _loadReaderImageResult(image);
              if (result.bytes == null) {
                retryable = result.failure != _ReaderImageFailureKind.permanent;
              } else {
                size = await decodeReaderImageSize(result.bytes!);
                // 字节已取到但解码失败：永久失败
                retryable = false;
              }
            }
          } catch (_) {
            size = null;
            retryable = true;
          }
          if (!mounted || session != _imageMeasureSession) {
            // 会话已失效：仅当该 key 仍归本会话所有时回滚，避免误清新会话
            if (_imageMeasureKeys[image.rawSrc] == session) {
              _imageMeasureKeys.remove(image.rawSrc);
              ReaderImageSizeCache.cancelMeasure(image.rawSrc);
            }
            return;
          }
          final written = ReaderImageSizeCache.completeMeasure(
            image.rawSrc,
            size,
            retryable: retryable,
          );
          _imageMeasureKeys.remove(image.rawSrc);
          if (written) changed = true;
        }
      } finally {
        // [批16 三审 P1-1/P1-2] 只有本会话结束才释放互斥并统一重排一次；
        // 重排触发的分页不会再次启动测量协程。
        if (session == _imageMeasureSession) {
          _endImageMeasureBatch();
          if (changed) _scheduleImageReflow();
        }
      }
    }());
  }

  /// 章边界预载触发：末屏预载下一章首屏、首屏预载上一章末屏
  void _maybePreloadAdjacent(ReaderState state, {bool eager = false}) {
    if (_paginatedPages.isEmpty || state.currentBook == null) return;
    final screenIndex = _isDoublePage
        ? _currentPageIndex ~/ 2
        : _currentPageIndex;
    final screenCount = _isDoublePage
        ? (_paginatedPages.length + 1) ~/ 2
        : _paginatedPages.length;
    // 提前一屏预载（异步加载留出时间窗）；eager=分页即预载两侧邻章
    //（对齐原版三章窗口：章节打开即后台准备相邻章，章末翻页才来得及动画）
    final atLast = eager || screenIndex >= screenCount - 2;
    final atFirst = eager || screenIndex <= 1;
    if (atLast && state.hasNextChapter && _nextChapterPreview == null) {
      unawaited(_preloadAdjacent(state, 1));
    }
    if (atFirst && state.hasPreviousChapter && _prevChapterPreview == null) {
      unawaited(_preloadAdjacent(state, -1));
    }
  }

  /// 预载相邻章边界页（下一章首屏 / 上一章末屏），供章边界动画与承接
  Future<void> _preloadAdjacent(ReaderState state, int delta) async {
    if (delta > 0) {
      if (_preloadingNext) return;
      _preloadingNext = true;
    } else {
      if (_preloadingPrev) return;
      _preloadingPrev = true;
    }
    final book = state.currentBook;
    final baseChapter = state.currentChapterIndex;
    // [换源预览修复 | 2026-09-26] 在途预载须同时校验 bookUrl：换源后章号
    // 往往不变，仅校验章号会让旧源拉取的结果回写、覆盖新源预览 — Qoder
    final baseBookUrl = book?.bookUrl;
    final target = baseChapter + delta;
    final config = _pagedConfig;
    final availableWidth = _pagedWidth;
    final availableHeight = _pagedHeight;
    try {
      if (book == null || config == null) return;
      if (target < 0 || target >= state.chapters.length) return;
      // [UI_SYNC_REFACTOR S6 修] 必须用 getChapterContentFull（缓存+网络合并，
      // 与阅读器章节加载同链路）——getChapterContent 仅读本地缓存不取网，
      // 预载会挂住（真机探针实证：PRELOAD start 后无任何返回）— Qoder
      final content = await ref
          .read(bookApiProvider)
          .getChapterContentFull(book.bookUrl, target);
      if (!mounted) return;
      // 发起后章节已切换或已换源（bookUrl 变）则作废
      final live = ref.read(readerNotifierProvider);
      if (live.currentChapterIndex != baseChapter ||
          live.currentBook?.bookUrl != baseBookUrl) {
        return;
      }
      if (content.trim().isEmpty) {
        return;
      }
      final targetChapter = state.chapters[target];
      final targetBaseUrl = _chapterImageBaseUrl(state, targetChapter);
      final previewFirstPage = _computeFirstPageHeight(
        state,
        availableHeight,
        availableWidth,
        targetChapter.title,
        titleImageUrl: targetChapter.imgUrl,
        titleImageBaseUrl: targetBaseUrl,
      );
      // 邻章正文图片须按目标章基址绝对化（当前章基址可能不同）
      final previewEngine = ParagraphLayoutEngine(
        config: config.copyWith(imageBaseUrl: targetBaseUrl),
        context: context,
      );
      final pages = previewEngine.paginateChapter(
        content,
        availableWidth,
        availableHeight,
        firstPageHeight: previewFirstPage.height,
      );
      if (pages.isEmpty) {
        return;
      }
      final info = delta > 0 ? pages.first : pages.last;
      final pageIndex = delta > 0 ? 0 : pages.length - 1;
      final title = targetChapter.title;
      final page = _buildPreviewPage(
        state,
        info,
        pageIndex,
        pages.length,
        title,
        titleImageLayout: previewFirstPage.titleImageLayout,
      );
      if (!mounted) return;
      setState(() {
        if (delta > 0) {
          _nextChapterPreview = page;
        } else {
          _prevChapterPreview = page;
        }
      });
    } catch (_) {
      // 预载失败静默：章边界退化为瞬时填充
    } finally {
      if (delta > 0) {
        _preloadingNext = false;
      } else {
        _preloadingPrev = false;
      }
    }
  }

  /// 相邻章预览页构建（与 _buildTypographicPage 同参；selectText 关闭）
  ///
  /// [批34b P3-6] 预览**不传** `highlightMatches`：`_combinedHighlightMatches`
  /// 是当前章的命中区间，偏移口径不同（章节全局偏移），套到相邻章正文会
  /// 染错位置。相邻章高亮/笔记需在预载时按目标章单独匹配（登记为后续专项）。
  Widget _buildPreviewPage(
    ReaderState state,
    PageInfo info,
    int pageIndex,
    int totalPages,
    String title, {
    ReaderImageLayout? titleImageLayout,
  }) {
    final page = ReaderTypographicPage(
      pageInfo: info,
      pageIndex: pageIndex,
      totalPages: totalPages,
      chapterTitle: title,
      pageChrome: widget.pageChrome,
      tipContext: _buildTipContext(state, pageIndex, totalPages, null),
      fontSize: state.fontSize,
      lineHeight: state.lineHeight,
      paragraphSpacing: widget.paragraphSpacing,
      backgroundColor: state.backgroundColor,
      textColor: _resolveTextColor(state),
      letterSpacing: widget.letterSpacing * state.fontSize,
      fontFamily: _resolveReaderFontFamily(context),
      justify: widget.textFullJustify,
      fontWeight: _fontWeightFor(widget.textBold),
      fontStyle: _fontStyleFor(widget.italic),
      selectText: false,
      imageConfig: _imageRenderConfig(state),
      titleImageLayout: titleImageLayout,
      contentPadding: EdgeInsets.only(
        left: widget.marginLeft,
        right: widget.marginRight,
        top: widget.marginTop,
        bottom: widget.marginBottom,
      ),
    );
    if (!_isDoublePage) return page;
    // 双页模式：预览按首屏双栏形态
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(child: page),
        const Expanded(child: SizedBox.shrink()),
      ],
    );
  }

  /// 重构版翻页视图（滑动/仿真/覆盖/无动画统一入口）
  Widget _buildTurnContent(ReaderState state) {
    final notifier = ref.read(readerNotifierProvider.notifier);
    final screenIndex = _isDoublePage
        ? _currentPageIndex ~/ 2
        : _currentPageIndex;
    final screenCount = _isDoublePage
        ? (_paginatedPages.length + 1) ~/ 2
        : (_paginatedPages.isNotEmpty ? _paginatedPages.length : 1);
    // [批4d] 下滑书签：仅菜单收起时可触发；选区浮层/底部面板是模态路由，
    // 手势不会到达正文。提示条相对翻页视图顶部（viewport 已 Padding 状态栏
    // inset，故此处只加正文上边距，避免重复叠加）。
    final advCfg = ref.read(readerAdvConfigProvider);
    final bookmarks = ref.read(bookmarkNotifierProvider).bookmarks;
    final currentBookmark = _bookmarkOnCurrentScreen(state, bookmarks);
    final hintTop = widget.marginTop;
    return _contentViewport(
      context,
      ReaderTurnView(
        key: _turnViewKey,
        mode: state.pageTurnMode,
        pageIndex: screenIndex,
        pageCount: screenCount,
        backPageColor: state.backgroundColor,
        pullBookmarkEnabled:
            (advCfg?.swipeToAddBookmark ?? false) && !state.showControls,
        hasBookmarkOnPage: currentBookmark != null,
        onToggleBookmark: () => unawaited(_toggleBookmarkOnCurrentPage()),
        bookmarkHintTop: hintTop,
        buildPage: (i) => _isDoublePage
            ? _buildSpread(state, i)
            : _buildTypographicPage(state, i),
        onPageChanged: (i) {
          final page = _isDoublePage ? i * 2 : i;
          setState(() => _currentPageIndex = page);
          notifier.updatePosition(page);
          // [批4d] 翻页成功重挂 keepLight
          _notifyPageTurn();
          // 翻页不触发重分页 → 此处驱动相邻章预载（原仅分页触发导致章末无预载）
          _maybePreloadAdjacent(ref.read(readerNotifierProvider));
        },
        chapterPrevPage: _prevChapterPreview,
        chapterNextPage: _nextChapterPreview,
        onTurnChapterPrev: () {
          // [批4d] 跨章翻页重挂 keepLight
          _notifyPageTurn();
          notifier.prevChapter();
        },
        onTurnChapterNext: () {
          // [批4d] 跨章翻页重挂 keepLight
          _notifyPageTurn();
          notifier.nextChapter();
        },
        hasChapterPrev: state.hasPreviousChapter,
        hasChapterNext: state.hasNextChapter,
      ),
    );
  }

  Widget _buildScrollContent(ReaderState state) {
    // [UI-fix v2.0.4 | 2026-08-08] 文字色经自定义配色解析 — Qoder
    final textColor = _resolveTextColor(state);
    final imageConfig = _imageRenderConfig(state);
    // [批16] 滚动模式标题图：按正文可用宽解析（无分页容量约束）
    final scrollBodyWidth =
        MediaQuery.of(context).size.width -
        widget.marginLeft -
        widget.marginRight;
    final scrollTitleImageLayout = _buildTitleImageLayout(
      imgUrl: state.currentChapter?.imgUrl,
      baseUrl: _chapterImageBaseUrl(state, state.currentChapter),
      availableWidth: scrollBodyWidth,
      maxHeight: MediaQuery.of(context).size.height,
      fontSize: state.fontSize,
      lineHeight: state.lineHeight,
    );

    return _contentViewport(
      context,
      SingleChildScrollView(
        controller: _scrollController,
        // [UI-fix v2.0.3 | 2026-08-06] 滚动模式边距接页面边距配置 — Qoder
        padding: EdgeInsets.only(
          left: widget.marginLeft,
          right: widget.marginRight,
          top: widget.marginTop,
          bottom: widget.marginBottom,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (state.currentChapter != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      state.currentChapter!.title,
                      style: TextStyle(
                        fontSize: state.fontSize + 4,
                        fontWeight: FontWeight.bold,
                        color: textColor,
                        // [A4 滚动模式标题字体 | full-stack-engineer] 标题
                        // fontFamily 接 effectiveTitleFontFamily 单源（与
                        // 分页模式渲染侧同参；空=跟随正文字体）。滚动模式
                        // 不分页、无测量侧，故仅渲染侧取值。
                        fontFamily: effectiveTitleFontFamily(
                          widget.pageChrome,
                          _resolveReaderFontFamily(context),
                        ),
                      ),
                    ),
                    if (scrollTitleImageLayout != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: ReaderImageLineWidget(
                          layout: scrollTitleImageLayout,
                          config: imageConfig,
                        ),
                      ),
                  ],
                ),
              ),
            // 滚动模式：渲染所有分页内容（使用排版引擎的分行结果）
            if (_paginatedPages.isNotEmpty)
              for (final pageInfo in _paginatedPages)
                ReaderTextContent(
                  pageInfo: pageInfo,
                  chapterIndex: _paginatedChapterIndex >= 0
                      ? _paginatedChapterIndex
                      : state.currentChapterIndex,
                  chapterTitle:
                      _paginatedChapterTitle ?? state.currentChapter?.title,
                  fontSize: state.fontSize,
                  lineHeight: state.lineHeight,
                  paragraphSpacing: widget.paragraphSpacing,
                  textColor: textColor,
                  // [UI-fix v2.0.2 | 2026-08-06] 字距/字体/两端对齐透传到正文渲染 — Qoder
                  // [UI-fix v2.0.4 | 2026-08-08] 字距 em→px；字重接线 — Qoder
                  letterSpacing: widget.letterSpacing * state.fontSize,
                  fontFamily: _resolveReaderFontFamily(context),
                  fontWeight: _fontWeightFor(widget.textBold),
                  fontStyle: _fontStyleFor(widget.italic),
                  justify: widget.textFullJustify,
                  // [UI-fix v2.0.3 | 2026-08-08] selectText 开关接入长按选择 — Qoder
                  selectText: widget.selectText,
                  reviewCounts: widget.reviewCounts,
                  onReviewTap: widget.onReviewTap,
                  // 滚动模式正文高亮：与分页同源（_combinedHighlightMatches
                  // 为章节全局 UTF-16 区间，按行 chapterStartIndex 映射）
                  highlightMatches: _combinedHighlightMatches,
                  imageConfig: imageConfig,
                )
            else if (state.chapterContent.isNotEmpty)
              ReaderParagraphs(
                content: state.chapterContent,
                chapterIndex: _paginatedChapterIndex >= 0
                    ? _paginatedChapterIndex
                    : state.currentChapterIndex,
                chapterTitle:
                    _paginatedChapterTitle ?? state.currentChapter?.title,
                fontSize: state.fontSize,
                lineHeight: state.lineHeight,
                paragraphSpacing: widget.paragraphSpacing,
                textColor: textColor,
                // [UI-fix v2.0.4 | 2026-08-08] 字距 em→px；字重接线 — Qoder
                letterSpacing: widget.letterSpacing * state.fontSize,
                fontFamily: _resolveReaderFontFamily(context),
                fontWeight: _fontWeightFor(widget.textBold),
                fontStyle: _fontStyleFor(widget.italic),
                // [UI-fix v2.0.3 | 2026-08-08] selectText 开关接入滚动回退渲染 — Qoder
                selectText: widget.selectText,
                // 回退渲染同样按章节全局坐标切 span（段间换行计 1 字符）
                highlightMatches: _combinedHighlightMatches,
              )
            else if (!state.isLoading)
              Center(
                child: Padding(
                  padding: const EdgeInsets.all(48),
                  child: Text(
                    AppStrings.noContent,
                    style: TextStyle(
                      fontSize: state.fontSize,
                      color: textColor.withValues(alpha: 0.5),
                    ),
                  ),
                ),
              ),
            const SizedBox(height: 80),
          ],
        ),
      ),
    );
  }

  /// 渲染排版引擎分页后的单页内容
  ///
  /// [UI-fix v2.0.5 | 2026-08-10] 双页模式：`doublePageSide` 为 'left'/'right'
  /// 时按栏调整左右边距（中间间隙 8px，与分页可用宽严格一致）— Reasonix
  Widget _buildTypographicPage(
    ReaderState state,
    int pageIndex, {
    String? doublePageSide,
  }) {
    final safeIndex = _paginatedPages.isEmpty
        ? 0
        : pageIndex.clamp(0, _paginatedPages.length - 1);
    final pageInfo = _paginatedPages.isEmpty
        ? null
        : _paginatedPages[safeIndex];

    // 计算全局页索引（章起始全局索引 + 章内页索引）
    final notifier = ref.read(readerNotifierProvider.notifier);
    final chapterStart = notifier.paginator.globalIndexForChapterStart(
      state.currentChapterIndex,
    );
    final globalIndex = chapterStart >= 0 ? chapterStart + safeIndex : null;
    final bookmarks = ref.read(bookmarkNotifierProvider).bookmarks;
    final pageBookmark = _bookmarkOnPage(state, bookmarks, safeIndex);
    final advCfg = ref.read(readerAdvConfigProvider) ?? ReaderAdvancedConfig();

    return ReaderTypographicPage(
      pageInfo: pageInfo,
      pageIndex: safeIndex,
      totalPages: _paginatedPages.length,
      chapterTitle: _paginatedChapterTitle ?? state.currentChapter?.title,
      // [P2-2] 分页快照章号：加载冻结帧时 state 可能已是新章
      chapterIndex: _paginatedChapterIndex >= 0
          ? _paginatedChapterIndex
          : state.currentChapterIndex,
      pageChrome: widget.pageChrome,
      tipContext: _buildTipContext(
        state,
        safeIndex,
        _paginatedPages.length,
        globalIndex,
      ),
      fontSize: state.fontSize,
      lineHeight: state.lineHeight,
      paragraphSpacing: widget.paragraphSpacing,
      backgroundColor: state.backgroundColor,
      // [UI-fix v2.0.4 | 2026-08-08] 文字色经自定义配色解析；字距/字体/
      // 对齐/字重透传到分页页渲染（与测量同参）— Qoder
      textColor: _resolveTextColor(state),
      letterSpacing: widget.letterSpacing * state.fontSize,
      fontFamily: _resolveReaderFontFamily(context),
      justify: widget.textFullJustify,
      fontWeight: _fontWeightFor(widget.textBold),
      fontStyle: _fontStyleFor(widget.italic),
      // [UI-fix v2.0.3 | 2026-08-08] selectText 开关接入分页页正文渲染 — Qoder
      selectText: widget.selectText,
      // [UI-fix v2.0.3 | 2026-08-06] 分页页内容边距接配置 — Qoder
      contentPadding: doublePageSide == null
          ? EdgeInsets.only(
              left: widget.marginLeft,
              right: widget.marginRight,
              top: widget.marginTop,
              bottom: widget.marginBottom,
            )
          : EdgeInsets.only(
              left: doublePageSide == 'left' ? widget.marginLeft : 8,
              right: doublePageSide == 'right' ? widget.marginRight : 8,
              top: widget.marginTop,
              bottom: widget.marginBottom,
            ),
      globalPageIndex: globalIndex,
      globalTotalPages: state.totalPages > 0 ? state.totalPages : null,
      reviewCounts: widget.reviewCounts,
      onReviewTap: widget.onReviewTap,
      // [批34] 正文高亮命中；[批7b-2b] 合并用户笔记（笔记优先）
      highlightMatches: _combinedHighlightMatches,
      // [批4d] 每页右上角书签角标（滚动模式不构建本页，故天然隐藏）
      showBookmarkBadge: pageBookmark != null,
      bookmarkBadgeImage: advCfg.bookmarkBadgeImage,
      bookmarkBadgeSize: advCfg.bookmarkBadgeSize,
      // [批16] 正文行内图片与章节标题图（仅首屏）
      imageConfig: _imageRenderConfig(state),
      titleImageLayout: safeIndex == 0 ? _paginatedTitleImageLayout : null,
    );
  }

  ReaderTipContext _buildTipContext(
    ReaderState state,
    int pageIndex,
    int totalPages,
    int? globalIndex,
  ) {
    return ReaderTipContext(
      bookName: state.currentBook?.name ?? '',
      // [UI_SYNC_REFACTOR S4 修] 章题取分页同源快照（加载冻结帧不串章）— Qoder
      chapterTitle: _paginatedChapterTitle ?? state.currentChapter?.title ?? '',
      pageIndex: pageIndex,
      totalPages: totalPages,
      globalPageIndex: globalIndex,
      globalTotalPages: state.totalPages > 0 ? state.totalPages : null,
      readProgress: state.readingProgress,
      chapterIndex: state.currentChapterIndex,
      chapterCount: state.chapters.length,
    );
  }

  /// [UI-fix v2.0.5 | 2026-08-10] 双页模式：一屏左右双栏
  ///（左 = 2s、右 = 2s+1；奇数页数时末屏右栏留白占位）— Reasonix
  Widget _buildSpread(ReaderState state, int screenIndex) {
    final left = screenIndex * 2;
    final right = left + 1;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: _buildTypographicPage(state, left, doublePageSide: 'left'),
        ),
        Expanded(
          child: right < _paginatedPages.length
              ? _buildTypographicPage(state, right, doublePageSide: 'right')
              : const SizedBox.shrink(),
        ),
      ],
    );
  }
}
