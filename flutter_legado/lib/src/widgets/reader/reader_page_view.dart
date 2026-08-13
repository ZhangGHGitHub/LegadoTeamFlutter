import 'dart:async';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:shared_preferences/shared_preferences.dart';

import '../../l10n/app_strings.dart';
import '../../models/models.dart';
import '../../providers/reader/reader_notifier.dart';
import '../../routes.dart';
import '../../screens/reader_config_panel.dart';
import '../../widgets/error_view.dart';
import '../../widgets/instant_scroll_physics.dart';
import '../../widgets/loading_indicator.dart';
import '../../widgets/paragraph_layout_engine.dart';
import 'reader_page_chrome.dart';
import 'reader_text_content.dart';

/// 阅读器内容区（分页 + 5 种翻页模式）
///
/// 对齐安卓原版 ReadView + 5 种 PageDelegate（覆盖/滑动/仿真/滚动/无动画）。
/// 拥有排版分页状态与 PageController，通过 [ReaderPageViewState] 对外暴露
/// 翻页导航方法（供自动翻页/点击区域调用）。
class ReaderPageView extends ConsumerStatefulWidget {
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

  // [UI-fix v2.0.3 | 2026-08-08] MoreConfig 第①批消费点 — Qoder

  /// 长按选择文本开关（对标原版 selectText，关闭后长按不弹选区面板）
  final bool selectText;

  /// 滚动翻页无动画（对标原版 noAnimScrollPage：程序化翻页去除动画）
  final bool noAnimScroll;

  // [UI-fix v2.0.4 | 2026-08-08] 界面面板/MoreConfig 第②批消费点 — Qoder

  /// 文字字重（0中/1粗/2细，对标原版 textBold）
  final int textBold;

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

  const ReaderPageView({
    super.key,
    required this.paragraphSpacing,
    this.letterSpacing = 0.0,
    this.paragraphIndent = 2,
    this.textFullJustify = true,
    this.marginTop = 24,
    this.marginBottom = 24,
    this.marginLeft = 20,
    this.marginRight = 20,
    this.pageChrome = const ReaderPageChromeConfig(),
    this.selectText = true,
    this.noAnimScroll = false,
    this.textBold = 0,
    this.customTextColor = 0,
    this.mouseWheelPage = true,
    this.doubleHorizontalPage = 0,
    this.useZhLayout = true,
    this.hangingPunctuation = false,
    this.reviewCounts,
    this.onReviewTap,
  });

  @override
  ConsumerState<ReaderPageView> createState() => ReaderPageViewState();
}

class ReaderPageViewState extends ConsumerState<ReaderPageView> {
  final PageController _pageController = PageController();

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
  bool _paginatedJustify = true;
  String? _paginatedFontFamily;

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

  /// 当前阅读字体 family（与 FontScreen 持久化键 reader_font_family 同步）
  String? _fontFamily;

  /// 当前页索引（屏级分页）
  int _currentPageIndex = 0;

  /// 覆盖翻页：当前显示的章节索引（用于 AnimatedSwitcher 触发过渡）
  int _coverChapterIndex = 0;

  /// 覆盖翻页：是否为前进方向（决定动画方向和层叠顺序）
  bool _coverForward = true;

  /// 当前页索引
  int get currentPageIndex => _currentPageIndex;

  // [UI-fix v2.0.4 | 2026-08-08] 鼠标滚轮翻页节流时间戳（300ms 防连翻，
  // 对标原版 ReadView 滚轮事件单次翻页语义）— Qoder
  DateTime _lastWheelTurn = DateTime.fromMillisecondsSinceEpoch(0);

  /// 当前章分页总数（进度条「调章内页」行为消费）
  int get pageCount => _paginatedPages.length;

  // [UI-fix v2.0.3 | 2026-08-08] 程序化翻页统一入口：noAnimScrollPage
  // 开启时 jumpToPage 无动画，否则保留 300ms 动画（对标原版
  // ReadBook.callBack?.upPageAnim 后的 PageAnim.NONE 语义）— Qoder
  void _navigateToPage(int index) {
    _currentPageIndex = index;
    // [UI-fix v2.0.5 | 2026-08-10] 双页模式每屏两页：PageController 按屏
    // 索引驱动（屏 = 内容页 / 2）— Reasonix
    final screen = _isDoublePage ? index ~/ 2 : index;
    if (_pageController.hasClients) {
      if (widget.noAnimScroll) {
        _pageController.jumpToPage(screen);
      } else {
        _pageController.animateToPage(
          screen,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeInOut,
        );
      }
    } else {
      setState(() {});
    }
    // 同步全局页索引
    ref.read(readerNotifierProvider.notifier).updatePosition(index);
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
        if (pos.hasViewportDimension &&
            pos.pixels >= pos.maxScrollExtent - 1) {
          notifier.nextChapter();
        } else {
          _scrollByViewport(true);
        }
      } else {
        notifier.nextChapter();
      }
      return;
    }
    // [UI-fix v2.0.5 | 2026-08-10] 双页模式翻页步进 2（整屏翻动）— Reasonix
    final step = _isDoublePage ? 2 : 1;
    if (_currentPageIndex + step < _paginatedPages.length) {
      _navigateToPage(_currentPageIndex + step);
    } else {
      // 本章最后一屏 → 跨章节无缝进入下一章
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
        if (pos.hasViewportDimension &&
            pos.pixels <= pos.minScrollExtent + 1) {
          notifier.prevChapter();
        } else {
          _scrollByViewport(false);
        }
      } else {
        notifier.prevChapter();
      }
      return;
    }
    // [UI-fix v2.0.5 | 2026-08-10] 双页模式翻页步进 2（整屏翻动）— Reasonix
    final step = _isDoublePage ? 2 : 1;
    if (_currentPageIndex - step >= 0) {
      _navigateToPage(_currentPageIndex - step);
    } else {
      // 本章第一屏 → 跨章节无缝进入上一章
      notifier.prevChapter();
    }
  }

  @override
  void initState() {
    super.initState();
    unawaited(_refreshFontFamily());
  }

  @override
  void didUpdateWidget(covariant ReaderPageView oldWidget) {
    super.didUpdateWidget(oldWidget);
    // [UI-fix v2.0.2 | 2026-08-06] 从字体选择页返回时重建 widget，
    // 重新读取字体配置（自定义字体会经 FontLoader 重新注册） — Qoder
    unawaited(_refreshFontFamily());
  }

  /// 从 SharedPreferences 读取当前阅读字体，自定义字体需先经 FontLoader 注册
  Future<void> _refreshFontFamily() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final family = prefs.getString('reader_font_family');
      // 自定义字体（Custom_* 前缀）应用重启后需重新加载字体文件
      if (family != null && family.startsWith('Custom_')) {
        final customRaw = prefs.getStringList('reader_custom_fonts') ?? [];
        for (final entry in customRaw) {
          final parts = entry.split('|');
          if (parts.length != 2 || parts[0] != family) continue;
          final file = File(parts[1]);
          if (await file.exists()) {
            final loader = FontLoader(parts[0])
              ..addFont(
                file.readAsBytes().then((b) => b.buffer.asByteData()),
              );
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
    _pageController.dispose();
    _scrollController.dispose();
    super.dispose();
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
    final justify = widget.textFullJustify;
    final fontFamily = _fontFamily;
    // [UI-fix v2.0.3 | 2026-08-06] 页面边距变化同样触发重新分页 — Qoder
    final margins =
        '${widget.marginTop}_${widget.marginBottom}_${widget.marginLeft}_${widget.marginRight}';
    // [UI-fix v2.0.3 | 2026-08-08] 系统栏显隐改变可用高度时重新分页 — Qoder
    final sysPadding = MediaQuery.of(context).padding;
    final sysPaddingKey =
        '${sysPadding.top}_${sysPadding.bottom}_${sysPadding.left}_${sysPadding.right}';

    // [UI-fix v2.0.5 | 2026-08-10] 双页档位判定（对齐原版
    // ChapterProvider.upLayout：0=单页、1=双页、2=横屏双页、3=平板或
    // 横屏双页；滚动模式 pageAnim==3 强制单页；桌面端以窗口宽 >=700
    // 作为平板语义）— Reasonix
    final screenSize = MediaQuery.of(context).size;
    final doublePage = switch (widget.doubleHorizontalPage) {
      1 => state.pageTurnMode != PageTurnMode.scroll,
      2 => screenSize.width > screenSize.height &&
          state.pageTurnMode != PageTurnMode.scroll,
      3 => (screenSize.width > screenSize.height || screenSize.width >= 700) &&
          state.pageTurnMode != PageTurnMode.scroll,
      _ => false,
    };

    final needRepaginate = content.isNotEmpty &&
        (content != _paginatedContent ||
            chapterIndex != _paginatedChapterIndex ||
            fontSize != _paginatedFontSize ||
            lineHeight != _paginatedLineHeight ||
            spacing != _paginatedParagraphSpacing ||
            letterSpacing != _paginatedLetterSpacing ||
            indent != _paginatedIndent ||
            textBold != _paginatedTextBold ||
            justify != _paginatedJustify ||
            fontFamily != _paginatedFontFamily ||
            margins != _paginatedMargins ||
            widget.pageChrome.layoutKey != _paginatedPageChrome ||
            sysPaddingKey != _paginatedSysPadding ||
            doublePage != _paginatedDoublePage ||
            widget.useZhLayout != _paginatedUseZhLayout ||
            widget.hangingPunctuation != _paginatedHangingPunctuation);

    if (!needRepaginate) return;

    // 计算可用尺寸（减去配置的页面边距）
    final padding = MediaQuery.of(context).padding;
    // 双页模式：每栏可用宽 =（屏宽 - 左右边距 - 16 栏间隙）/ 2
    //（渲染侧左栏右间隙 8 + 右栏左间隙 8，与分页宽严格一致）
    final availableWidth = doublePage
        ? (screenSize.width - widget.marginLeft - widget.marginRight - 16) / 2
        : screenSize.width - widget.marginLeft - widget.marginRight;
    // [UI-fix v2.0.4 | 2026-08-08] 分页可用高度与渲染容器严格一致：
    // 渲染侧（ReaderTypographicPage）Column = 首页标题块 +
    // Expanded(正文) + 页码指示（top 8 + 11 号文字）；此前用固定
    // 40 估算页脚且未扣首页标题块高度，满页正文首页底部
    // RenderFlex 溢出 ~16-27px（随字号增大）。改为 TextPainter 按
    // 渲染同参实测页脚与标题块高度，首页容量单独下发排版引擎 — Qoder
    final textScaler = MediaQuery.textScalerOf(context);
    // 实测样式合并 DefaultTextStyle（与渲染侧 Text 的主题字体一致，
    // 避免字体度量差异引入像素级偏差）
    final baseStyle = DefaultTextStyle.of(context).style;
    final chrome = widget.pageChrome;
    final headerBlock = ReaderPageLayoutMetrics.headerBlockHeight(context, chrome);
    final footerBlock = ReaderPageLayoutMetrics.footerBlockHeight(context, chrome);
    final availableHeight = screenSize.height -
        padding.top -
        padding.bottom -
        headerBlock -
        footerBlock -
        widget.marginTop -
        widget.marginBottom;

    // 首页标题块高度（与渲染侧 pageIndex==0 分支同参：标题按
    // availableWidth 换行实测 + 20 底部间距）
    var firstPageHeight = availableHeight;
    final chapterTitle = state.currentChapter?.title;
    if (chapterTitle != null) {
      final showTitle = chrome.titleMode.clamp(0, 2) != 2;
      if (showTitle) {
        final titlePainter = TextPainter(
          text: TextSpan(
            text: chapterTitle,
            style: baseStyle.merge(TextStyle(
              fontSize: fontSize + chrome.titleSize,
              fontWeight: FontWeight.bold,
            )),
          ),
          textDirection: TextDirection.ltr,
          textScaler: textScaler,
        )..layout(maxWidth: availableWidth);
        firstPageHeight = availableHeight -
            titlePainter.height -
            chrome.titleTopSpacing -
            chrome.titleBottomSpacing;
        titlePainter.dispose();
      }
      // 极端小窗口兼底：首页至少容纳一行正文
      final minHeight = fontSize * lineHeight;
      if (firstPageHeight < minHeight) firstPageHeight = minHeight;
    }

    final config = ParagraphConfig(
      fontSize: fontSize,
      lineHeight: lineHeight,
      paragraphSpacing: spacing,
      // [UI-fix v2.0.4 | 2026-08-08] 缩进档位（0-3 字符）接入排版引擎；
      // 字重接入测量（与渲染同参）— Qoder
      indent: indent > 0 ? fontSize * indent : 0,
      indentCount: indent,
      fontWeight: _fontWeightFor(textBold),
      justify: justify,
      textColor: _resolveTextColor(state),
      backgroundColor: state.backgroundColor,
      letterSpacing: letterSpacing,
      fontFamily: fontFamily,
      // [UI-fix v2.0.5 | 2026-08-10] 中文分行开关接入排版引擎 — Reasonix
      useZhLayout: widget.useZhLayout,
      // [UI-fix v2.0.5 | 2026-08-10] 段首标点悬挂接入排版引擎 — Reasonix
      hangingPunctuation: widget.hangingPunctuation,
    );

    final engine = ParagraphLayoutEngine(config: config, context: context);
    // [UI-fix v2.0.4 | 2026-08-08] 首页容量单独下发（扣标题块）— Qoder
    final pages = engine.paginateChapter(content, availableWidth, availableHeight,
        firstPageHeight: firstPageHeight);

    _paginatedPages = pages;
    _paginatedContent = content;
    _paginatedChapterIndex = chapterIndex;
    _paginatedFontSize = fontSize;
    _paginatedLineHeight = lineHeight;
    _paginatedParagraphSpacing = spacing;
    _paginatedLetterSpacing = letterSpacing;
    _paginatedIndent = indent;
    _paginatedTextBold = textBold;
    _paginatedJustify = justify;
    _paginatedFontFamily = fontFamily;
    _paginatedMargins = margins;
    _paginatedPageChrome = widget.pageChrome.layoutKey;
    _paginatedSysPadding = sysPaddingKey;
    _paginatedDoublePage = doublePage;
    _paginatedUseZhLayout = widget.useZhLayout;
    _paginatedHangingPunctuation = widget.hangingPunctuation;
    _currentPageIndex = 0;

    // 跨章节分页：注册本章页数到全局分页器
    // 注：本方法在 build 阶段调用，不可同步修改 provider（会触发
    // "modify a provider while the widget tree was building" 断言），延迟到下一帧
    final notifier = ref.read(readerNotifierProvider.notifier);
    Future(() => notifier.updateChapterPageCount(chapterIndex, pages.length));

    if (_pageController.hasClients) {
      _pageController.jumpToPage(0);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(readerNotifierProvider);
    final notifier = ref.read(readerNotifierProvider.notifier);

    if (state.isLoading) {
      return LoadingIndicator(message: AppStrings.loadingChapter);
    }

    if (state.error != null) {
      final book = state.currentBook;
      // [fix Task#24 | 2026-08-08] 正文/章节加载失败（如「正文为空」，多由换源
      // 匹配错书导致）时，除「重试」外引导用户「换源」逃离坏书源（对齐原版）— Qoder
      final isOnline = book != null &&
          book.origin != BookType.localTag &&
          !book.origin.startsWith(BookType.webDavTag);
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

    // 排版引擎：检测是否需要重新分页
    _paginateIfNeeded(context, state);

    final Widget content;
    switch (state.pageTurnMode) {
      case PageTurnMode.scroll:
        content = _buildScrollContent(state);
        break;
      case PageTurnMode.slide:
        content = _buildSlideContent(state);
        break;
      case PageTurnMode.simulate:
        content = _buildSimulateContent(state);
        break;
      case PageTurnMode.none:
        content = _buildNoneContent(state);
        break;
      case PageTurnMode.cover:
        content = _buildCoverContent(state);
        break;
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
  Widget _contentViewport(Widget child) => child;

  Widget _buildScrollContent(ReaderState state) {
    // [UI-fix v2.0.4 | 2026-08-08] 文字色经自定义配色解析 — Qoder
    final textColor = _resolveTextColor(state);

    return _contentViewport(
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
                child: Text(
                  state.currentChapter!.title,
                  style: TextStyle(
                    fontSize: state.fontSize + 4,
                    fontWeight: FontWeight.bold,
                    color: textColor,
                  ),
                ),
              ),
            // 滚动模式：渲染所有分页内容（使用排版引擎的分行结果）
            if (_paginatedPages.isNotEmpty)
              for (final pageInfo in _paginatedPages)
                ReaderTextContent(
                  pageInfo: pageInfo,
                  fontSize: state.fontSize,
                  lineHeight: state.lineHeight,
                  paragraphSpacing: widget.paragraphSpacing,
                  textColor: textColor,
                  // [UI-fix v2.0.2 | 2026-08-06] 字距/字体/两端对齐透传到正文渲染 — Qoder
                  // [UI-fix v2.0.4 | 2026-08-08] 字距 em→px；字重接线 — Qoder
                  letterSpacing: widget.letterSpacing * state.fontSize,
                  fontFamily: _fontFamily,
                  fontWeight: _fontWeightFor(widget.textBold),
                  justify: widget.textFullJustify,
                  // [UI-fix v2.0.3 | 2026-08-08] selectText 开关接入长按选择 — Qoder
                  selectText: widget.selectText,
                  reviewCounts: widget.reviewCounts,
                  onReviewTap: widget.onReviewTap,
                )
            else if (state.chapterContent.isNotEmpty)
              ReaderParagraphs(
                content: state.chapterContent,
                fontSize: state.fontSize,
                lineHeight: state.lineHeight,
                paragraphSpacing: widget.paragraphSpacing,
                textColor: textColor,
                // [UI-fix v2.0.4 | 2026-08-08] 字距 em→px；字重接线 — Qoder
                letterSpacing: widget.letterSpacing * state.fontSize,
                fontFamily: _fontFamily,
                fontWeight: _fontWeightFor(widget.textBold),
                // [UI-fix v2.0.3 | 2026-08-08] selectText 开关接入滚动回退渲染 — Qoder
                selectText: widget.selectText,
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

  Widget _buildSlideContent(ReaderState state) {
    final notifier = ref.read(readerNotifierProvider.notifier);
    return _contentViewport(
      PageView.builder(
        controller: _pageController,
        itemCount: _isDoublePage
            ? (_paginatedPages.length + 1) ~/ 2
            : (_paginatedPages.isNotEmpty ? _paginatedPages.length : 1),
        onPageChanged: (index) {
          // [UI-fix v2.0.5 | 2026-08-10] 双页模式：屏索引 → 内容页索引 — Reasonix
          final page = _isDoublePage ? index * 2 : index;
          setState(() => _currentPageIndex = page);
          notifier.updatePosition(page);
        },
        itemBuilder: (context, index) => _isDoublePage
            ? _buildSpread(state, index)
            : _buildTypographicPage(state, index),
      ),
    );
  }

  Widget _buildSimulateContent(ReaderState state) {
    final notifier = ref.read(readerNotifierProvider.notifier);
    // 仿真翻页：PageView + 翻页阴影 + 缩放动画效果
    return _contentViewport(
      Stack(
        children: [
          PageView.builder(
            controller: _pageController,
            itemCount: _isDoublePage
                ? (_paginatedPages.length + 1) ~/ 2
                : (_paginatedPages.isNotEmpty ? _paginatedPages.length : 1),
            pageSnapping: true,
            onPageChanged: (index) {
              // [UI-fix v2.0.5 | 2026-08-10] 双页模式：屏索引 → 内容页索引 — Reasonix
              final page = _isDoublePage ? index * 2 : index;
              setState(() => _currentPageIndex = page);
              notifier.updatePosition(page);
            },
            itemBuilder: (context, index) {
              // [UI-fix v2.0.5 | 2026-08-10] 双页模式：双栏整屏渲染
              //（缩放/阴影动画不适用于整屏双栏，降级为 slide 语义）— Reasonix
              if (_isDoublePage) {
                return _buildSpread(state, index);
              }
              return AnimatedBuilder(
                animation: _pageController,
                builder: (context, child) {
                  double value = 1.0;
                  if (_pageController.hasClients &&
                      _pageController.position.hasContentDimensions) {
                    value = (_pageController.page ??
                            _pageController.initialPage.toDouble()) -
                        index;
                    value = (1 - value.abs().clamp(0.0, 1.0));
                  }
                  return Stack(
                    children: [
                      // 页面内容（带缩放和透明度动画）
                      Transform.scale(
                        scale: 0.96 + (0.04 * value),
                        child: Opacity(
                          opacity: 0.75 + (0.25 * value),
                          child: child,
                        ),
                      ),
                      // 翻页阴影效果
                      if (value < 1.0)
                        Positioned.fill(
                          child: IgnorePointer(
                            child: Container(
                              decoration: BoxDecoration(
                                gradient: LinearGradient(
                                  begin: Alignment.centerRight,
                                  end: Alignment.centerLeft,
                                  colors: [
                                    Colors.black
                                        .withValues(alpha: 0.12 * (1.0 - value)),
                                    Colors.transparent,
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                    ],
                  );
                },
                child: _buildTypographicPage(state, index),
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _buildNoneContent(ReaderState state) {
    final notifier = ref.read(readerNotifierProvider.notifier);
    // 无动画翻页：使用 PageView 但禁用动画
    return _contentViewport(
      PageView.builder(
        controller: _pageController,
        physics: const InstantScrollPhysics(), // 无动画瞬间切换
        itemCount: _isDoublePage
            ? (_paginatedPages.length + 1) ~/ 2
            : (_paginatedPages.isNotEmpty ? _paginatedPages.length : 1),
        onPageChanged: (index) {
          // [UI-fix v2.0.5 | 2026-08-10] 双页模式：屏索引 → 内容页索引 — Reasonix
          final page = _isDoublePage ? index * 2 : index;
          setState(() => _currentPageIndex = page);
          notifier.updatePosition(page);
        },
        itemBuilder: (context, index) => _isDoublePage
            ? _buildSpread(state, index)
            : _buildTypographicPage(state, index),
      ),
    );
  }

  /// 覆盖翻页模式（对齐安卓 CoverPageDelegate）
  ///
  /// 视觉效果：
  /// - 前进（下一页）：新页从右侧滑入覆盖旧页，旧页保持不动
  /// - 后退（上一页）：当前页向右滑出，露出下方的新页
  /// 动画时长 300ms，线性曲线（对齐安卓基准）
  Widget _buildCoverContent(ReaderState state) {
    // [UI-fix v2.0.5 | 2026-08-10] 双页模式：覆盖翻页按整屏动画（屏索引）— Reasonix
    final targetIndex = _isDoublePage ? _currentPageIndex ~/ 2 : _currentPageIndex;
    // 检测翻页方向
    if (targetIndex != _coverChapterIndex) {
      _coverForward = targetIndex > _coverChapterIndex;
      _coverChapterIndex = targetIndex;
    }
    final forward = _coverForward;

    return _contentViewport(
      AnimatedSwitcher(
        duration: const Duration(milliseconds: 300),
        switchInCurve: Curves.linear,
        switchOutCurve: Curves.linear,
        // 层叠策略：前进时新页在上（覆盖效果），后退时旧页在上（抽离效果）
        layoutBuilder: (currentChild, previousChildren) {
          return Stack(
            children: [
              ...previousChildren,
              // ignore: use_null_aware_elements
              if (currentChild != null) currentChild,
            ],
          );
        },
        transitionBuilder: (child, animation) {
          final isEntering = child.key == ValueKey<int>(targetIndex);
          final bool slides;
          if (forward) {
            slides = isEntering;
          } else {
            slides = !isEntering;
          }
          if (!slides) return child;
          final begin = forward ? const Offset(1.0, 0.0) : Offset.zero;
          final end = forward ? Offset.zero : const Offset(1.0, 0.0);
          return AnimatedBuilder(
            animation: animation,
            builder: (context, _) {
              final offset = Offset.lerp(begin, end, animation.value)!;
              return Stack(
                children: [
                  Positioned.fill(
                    child: FractionalTranslation(
                      translation: offset,
                      child: child,
                    ),
                  ),
                  // 翻页阴影（30px 渐变，对齐安卓 shadowDrawableR）
                  PositionedDirectional(
                    top: 0,
                    bottom: 0,
                    start: forward ? null : 0,
                    end: forward ? 0 : null,
                    width: 30,
                    child: FractionalTranslation(
                      translation: offset,
                      child: IgnorePointer(
                        child: Container(
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: forward
                                  ? Alignment.centerRight
                                  : Alignment.centerLeft,
                              end: forward
                                  ? Alignment.centerLeft
                                  : Alignment.centerRight,
                              colors: [
                                Colors.black
                                    .withValues(alpha: 0.2 * (1 - animation.value)),
                                Colors.transparent,
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              );
            },
          );
        },
        child: KeyedSubtree(
          key: ValueKey<int>(targetIndex),
          child: _isDoublePage
              ? _buildSpread(state, targetIndex)
              : _buildTypographicPage(state, targetIndex),
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
    final pageInfo = _paginatedPages.isEmpty ? null : _paginatedPages[safeIndex];

    // 计算全局页索引（章起始全局索引 + 章内页索引）
    final notifier = ref.read(readerNotifierProvider.notifier);
    final chapterStart = notifier.paginator.globalIndexForChapterStart(state.currentChapterIndex);
    final globalIndex = chapterStart >= 0 ? chapterStart + safeIndex : null;

    return ReaderTypographicPage(
      pageInfo: pageInfo,
      pageIndex: safeIndex,
      totalPages: _paginatedPages.length,
      chapterTitle: state.currentChapter?.title,
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
      fontFamily: _fontFamily,
      justify: widget.textFullJustify,
      fontWeight: _fontWeightFor(widget.textBold),
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
      chapterTitle: state.currentChapter?.title ?? '',
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
