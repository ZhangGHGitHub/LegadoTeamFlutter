import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:shared_preferences/shared_preferences.dart';

import '../../l10n/app_strings.dart';
import '../../providers/reader/reader_notifier.dart';
import '../../widgets/error_view.dart';
import '../../widgets/instant_scroll_physics.dart';
import '../../widgets/loading_indicator.dart';
import '../../widgets/paragraph_layout_engine.dart';
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

  /// 字距（对标原版 ReadBookConfig.letterSpacing）
  final double letterSpacing;

  /// 首行缩进开关（true=缩进两字符，对标原版 paragraphIndent）
  final bool paragraphIndent;

  /// 两端对齐开关（对标 MoreConfig textFullJustify）
  final bool textFullJustify;

  // [UI-fix v2.0.3 | 2026-08-06] 页面边距四向可调（对标原版
  // ReadBookConfig paddingTop/Bottom/Left/Right） — Qoder
  final double marginTop;
  final double marginBottom;
  final double marginLeft;
  final double marginRight;

  // [UI-fix v2.0.3 | 2026-08-08] MoreConfig 第①批消费点 — Qoder

  /// 长按选择文本开关（对标原版 selectText，关闭后长按不弹选区面板）
  final bool selectText;

  /// 滚动翻页无动画（对标原版 noAnimScrollPage：程序化翻页去除动画）
  final bool noAnimScroll;

  const ReaderPageView({
    super.key,
    required this.paragraphSpacing,
    this.letterSpacing = 0.0,
    this.paragraphIndent = true,
    this.textFullJustify = true,
    this.marginTop = 24,
    this.marginBottom = 24,
    this.marginLeft = 20,
    this.marginRight = 20,
    this.selectText = true,
    this.noAnimScroll = false,
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
  bool _paginatedIndent = true;
  bool _paginatedJustify = true;
  String? _paginatedFontFamily;

  // [UI-fix v2.0.3 | 2026-08-06] 分页缓存键新增页面边距 — Qoder
  String _paginatedMargins = '';

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

  /// 当前章分页总数（进度条「调章内页」行为消费）
  int get pageCount => _paginatedPages.length;

  // [UI-fix v2.0.3 | 2026-08-08] 程序化翻页统一入口：noAnimScrollPage
  // 开启时 jumpToPage 无动画，否则保留 300ms 动画（对标原版
  // ReadBook.callBack?.upPageAnim 后的 PageAnim.NONE 语义）— Qoder
  void _navigateToPage(int index) {
    _currentPageIndex = index;
    if (_pageController.hasClients) {
      if (widget.noAnimScroll) {
        _pageController.jumpToPage(index);
      } else {
        _pageController.animateToPage(
          index,
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
    if (_currentPageIndex < _paginatedPages.length - 1) {
      _navigateToPage(_currentPageIndex + 1);
    } else {
      // 本章最后一页 → 跨章节无缝进入下一章
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
    if (_currentPageIndex > 0) {
      _navigateToPage(_currentPageIndex - 1);
    } else {
      // 本章第一页 → 跨章节无缝进入上一章
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
    final letterSpacing = widget.letterSpacing;
    final indent = widget.paragraphIndent;
    final justify = widget.textFullJustify;
    final fontFamily = _fontFamily;
    // [UI-fix v2.0.3 | 2026-08-06] 页面边距变化同样触发重新分页 — Qoder
    final margins =
        '${widget.marginTop}_${widget.marginBottom}_${widget.marginLeft}_${widget.marginRight}';
    // [UI-fix v2.0.3 | 2026-08-08] 系统栏显隐改变可用高度时重新分页 — Qoder
    final sysPadding = MediaQuery.of(context).padding;
    final sysPaddingKey =
        '${sysPadding.top}_${sysPadding.bottom}_${sysPadding.left}_${sysPadding.right}';

    final needRepaginate = content.isNotEmpty &&
        (content != _paginatedContent ||
            chapterIndex != _paginatedChapterIndex ||
            fontSize != _paginatedFontSize ||
            lineHeight != _paginatedLineHeight ||
            spacing != _paginatedParagraphSpacing ||
            letterSpacing != _paginatedLetterSpacing ||
            indent != _paginatedIndent ||
            justify != _paginatedJustify ||
            fontFamily != _paginatedFontFamily ||
            margins != _paginatedMargins ||
            sysPaddingKey != _paginatedSysPadding);

    if (!needRepaginate) return;

    // 计算可用尺寸（减去配置的页面边距）
    final screenSize = MediaQuery.of(context).size;
    final padding = MediaQuery.of(context).padding;
    final availableWidth = screenSize.width -
        widget.marginLeft -
        widget.marginRight;
    final availableHeight = screenSize.height -
        padding.top -
        padding.bottom -
        40 -
        widget.marginTop -
        widget.marginBottom;

    final config = ParagraphConfig(
      fontSize: fontSize,
      lineHeight: lineHeight,
      paragraphSpacing: spacing,
      // [UI-fix v2.0.2 | 2026-08-06] 首行缩进接入配置（关闭时为 0，
      // 排版引擎按全角空格实现；单字符缩进待排版引擎增强） — Qoder
      indent: indent ? fontSize * 2 : 0,
      justify: justify,
      textColor: state.textColor,
      backgroundColor: state.backgroundColor,
      letterSpacing: letterSpacing,
      fontFamily: fontFamily,
    );

    final engine = ParagraphLayoutEngine(config: config, context: context);
    final pages = engine.paginateChapter(content, availableWidth, availableHeight);

    _paginatedPages = pages;
    _paginatedContent = content;
    _paginatedChapterIndex = chapterIndex;
    _paginatedFontSize = fontSize;
    _paginatedLineHeight = lineHeight;
    _paginatedParagraphSpacing = spacing;
    _paginatedLetterSpacing = letterSpacing;
    _paginatedIndent = indent;
    _paginatedJustify = justify;
    _paginatedFontFamily = fontFamily;
    _paginatedMargins = margins;
    _paginatedSysPadding = sysPaddingKey;
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
      return ErrorView(
        message: state.error!,
        onRetry: () {
          final book = state.currentBook;
          if (book != null) {
            notifier.openBook(book);
          }
        },
      );
    }

    // 排版引擎：检测是否需要重新分页
    _paginateIfNeeded(context, state);

    switch (state.pageTurnMode) {
      case PageTurnMode.scroll:
        return _buildScrollContent(state);
      case PageTurnMode.slide:
        return _buildSlideContent(state);
      case PageTurnMode.simulate:
        return _buildSimulateContent(state);
      case PageTurnMode.none:
        return _buildNoneContent(state);
      case PageTurnMode.cover:
        return _buildCoverContent(state);
    }
  }

  Widget _buildScrollContent(ReaderState state) {
    final textColor = state.textColor;

    return SafeArea(
      top: !state.showControls,
      bottom: !state.showControls,
      child: SingleChildScrollView(
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
                  letterSpacing: widget.letterSpacing,
                  fontFamily: _fontFamily,
                  justify: widget.textFullJustify,
                  // [UI-fix v2.0.3 | 2026-08-08] selectText 开关接入长按选择 — Qoder
                  selectText: widget.selectText,
                )
            else if (state.chapterContent.isNotEmpty)
              ReaderParagraphs(
                content: state.chapterContent,
                fontSize: state.fontSize,
                lineHeight: state.lineHeight,
                paragraphSpacing: widget.paragraphSpacing,
                textColor: textColor,
                letterSpacing: widget.letterSpacing,
                fontFamily: _fontFamily,
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
    return SafeArea(
      top: !state.showControls,
      bottom: !state.showControls,
      child: PageView.builder(
        controller: _pageController,
        itemCount: _paginatedPages.isNotEmpty ? _paginatedPages.length : 1,
        onPageChanged: (index) {
          setState(() => _currentPageIndex = index);
          notifier.updatePosition(index);
        },
        itemBuilder: (context, index) => _buildTypographicPage(state, index),
      ),
    );
  }

  Widget _buildSimulateContent(ReaderState state) {
    final notifier = ref.read(readerNotifierProvider.notifier);
    // 仿真翻页：PageView + 翻页阴影 + 缩放动画效果
    return SafeArea(
      top: !state.showControls,
      bottom: !state.showControls,
      child: Stack(
        children: [
          PageView.builder(
            controller: _pageController,
            itemCount: _paginatedPages.isNotEmpty ? _paginatedPages.length : 1,
            pageSnapping: true,
            onPageChanged: (index) {
              setState(() => _currentPageIndex = index);
              notifier.updatePosition(index);
            },
            itemBuilder: (context, index) {
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
    return SafeArea(
      top: !state.showControls,
      bottom: !state.showControls,
      child: PageView.builder(
        controller: _pageController,
        physics: const InstantScrollPhysics(), // 无动画瞬间切换
        itemCount: _paginatedPages.isNotEmpty ? _paginatedPages.length : 1,
        onPageChanged: (index) {
          setState(() => _currentPageIndex = index);
          notifier.updatePosition(index);
        },
        itemBuilder: (context, index) => _buildTypographicPage(state, index),
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
    final targetIndex = _currentPageIndex;
    // 检测翻页方向
    if (targetIndex != _coverChapterIndex) {
      _coverForward = targetIndex > _coverChapterIndex;
      _coverChapterIndex = targetIndex;
    }
    final forward = _coverForward;

    return SafeArea(
      top: !state.showControls,
      bottom: !state.showControls,
      child: AnimatedSwitcher(
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
          child: _buildTypographicPage(state, targetIndex),
        ),
      ),
    );
  }

  /// 渲染排版引擎分页后的单页内容
  Widget _buildTypographicPage(ReaderState state, int pageIndex) {
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
      fontSize: state.fontSize,
      lineHeight: state.lineHeight,
      paragraphSpacing: widget.paragraphSpacing,
      backgroundColor: state.backgroundColor,
      textColor: state.textColor,
      // [UI-fix v2.0.3 | 2026-08-08] selectText 开关接入分页页正文渲染 — Qoder
      selectText: widget.selectText,
      // [UI-fix v2.0.3 | 2026-08-06] 分页页内容边距接配置 — Qoder
      contentPadding: EdgeInsets.only(
        left: widget.marginLeft,
        right: widget.marginRight,
        top: widget.marginTop,
        bottom: widget.marginBottom,
      ),
      globalPageIndex: globalIndex,
      globalTotalPages: state.totalPages > 0 ? state.totalPages : null,
    );
  }
}
