import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/app_strings.dart';
import '../routes.dart';
import '../services/book_api.dart';
import '../providers/bookmark_provider.dart';
import '../providers/reader_provider.dart';
import '../widgets/loading_indicator.dart';
import '../widgets/error_view.dart';
import '../widgets/paragraph_layout_engine.dart';
import 'reader_config_panel.dart';
import '../widgets/instant_scroll_physics.dart';

/// 阅读器页面
class ReaderScreen extends StatefulWidget {
  const ReaderScreen({super.key});

  @override
  State<ReaderScreen> createState() => _ReaderScreenState();
}

class _ReaderScreenState extends State<ReaderScreen> {
  final PageController _pageController = PageController();
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();

  /// 上一章是否处于加载状态（用于检测章节加载完成以触发预加载）
  bool _wasLoading = false;

  /// 已触发过预加载的章节索引（避免重复预加载）
  int _lastPreloadedIndex = -1;

  /// 目录搜索关键词
  String _chapterSearchQuery = '';

  /// 覆盖翻页：当前显示的章节索引（用于 AnimatedSwitcher 触发过渡）
  int _coverChapterIndex = 0;

  /// 覆盖翻页：是否为前进方向（决定动画方向和层叠顺序）
  bool _coverForward = true;

  /// 阅读器高级配置（自动翻页/点击区域/段距/状态栏）
  ReaderAdvancedConfig _advConfig = ReaderAdvancedConfig();

  /// 自动翻页定时器
  Timer? _autoTimer;

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

  /// 当前页索引（屏级分页）
  int _currentPageIndex = 0;

  @override
  void initState() {
    super.initState();
    _loadAdvancedConfig();
    // 下沉 loadSettings 到阅读器首帧回调
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        context.read<ReaderProvider>().loadSettings();
      }
    });
  }

  Future<void> _loadAdvancedConfig() async {
    final config = await ReaderAdvancedConfig.load();
    if (!mounted) return;
    setState(() => _advConfig = config);
    _syncAutoTimer();
  }

  /// 根据配置同步自动翻页定时器
  void _syncAutoTimer() {
    _autoTimer?.cancel();
    _autoTimer = null;
    final cfg = _advConfig;
    if (!cfg.autoPageTurn) return;
    final seconds = cfg.autoPageTurnInterval.round().clamp(3, 120);
    _autoTimer = Timer.periodic(Duration(seconds: seconds), (_) {
      if (!mounted) return;
      final provider = context.read<ReaderProvider>();
      if (cfg.autoPageTurnForward) {
        _goToNextChapterOrPage(provider);
      } else {
        _goToPrevChapterOrPage(provider);
      }
    });
  }

  /// 检查是否需要重新分页（章节/字号/行高/段距变化时触发）
  ///
  /// 移植自安卓端 TextChapterLayout 的排版触发时机：
  /// 章节加载完成、字体设置变更、屏幕尺寸变化
  void _paginateIfNeeded(BuildContext context, ReaderProvider provider) {
    final content = provider.chapterContent;
    final fontSize = provider.fontSize;
    final lineHeight = provider.lineHeight;
    final spacing = _advConfig.paragraphSpacing;
    final chapterIndex = provider.currentChapterIndex;

    // 检查是否需要重新分页
    final needRepaginate = content.isNotEmpty &&
        (chapterIndex != _paginatedChapterIndex ||
            fontSize != _paginatedFontSize ||
            lineHeight != _paginatedLineHeight ||
            spacing != _paginatedParagraphSpacing);

    if (!needRepaginate) return;

    // 计算可用尺寸（减去内边距）
    final screenSize = MediaQuery.of(context).size;
    final padding = MediaQuery.of(context).padding;
    final availableWidth = screenSize.width - 40; // 左右各 20px
    final availableHeight = screenSize.height - padding.top - padding.bottom - 48 - 40; // 上下内边距 + 标题区域

    // 构建排版配置
    final config = ParagraphConfig(
      fontSize: fontSize,
      lineHeight: lineHeight,
      paragraphSpacing: spacing,
      indent: fontSize * 2, // 首行缩进两个字符
      justify: true,
      textColor: provider.backgroundColor == ReaderBackground.dark
          ? const Color(0xFFCCCCCC)
          : const Color(0xFF333333),
      backgroundColor: provider.backgroundColor,
    );

    // 执行排版分页
    final engine = ParagraphLayoutEngine(config: config, context: context);
    final pages = engine.paginateChapter(content, availableWidth, availableHeight);

    _paginatedPages = pages;
    _paginatedChapterIndex = chapterIndex;
    _paginatedFontSize = fontSize;
    _paginatedLineHeight = lineHeight;
    _paginatedParagraphSpacing = spacing;
    _currentPageIndex = 0;

    // 重置 PageController 到第一页
    if (_pageController.hasClients) {
      _pageController.jumpToPage(0);
    }
  }

  /// 自动翻页/手动翻页：前进（下一页或下一章）
  void _goToNextChapterOrPage(ReaderProvider provider) {
    if (_currentPageIndex < _paginatedPages.length - 1) {
      // 当前章节还有下一页
      _currentPageIndex++;
      if (_pageController.hasClients) {
        _pageController.animateToPage(
          _currentPageIndex,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeInOut,
        );
      } else {
        setState(() {});
      }
    } else {
      // 已是最后一页，进入下一章
      provider.nextChapter();
    }
  }

  /// 自动翻页/手动翻页：后退（上一页或上一章）
  void _goToPrevChapterOrPage(ReaderProvider provider) {
    if (_currentPageIndex > 0) {
      _currentPageIndex--;
      if (_pageController.hasClients) {
        _pageController.animateToPage(
          _currentPageIndex,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeInOut,
        );
      } else {
        setState(() {});
      }
    } else {
      // 已是第一页，进入上一章
      provider.prevChapter();
    }
  }

  @override
  void dispose() {
    _autoTimer?.cancel();
    _pageController.dispose();
    super.dispose();
  }

  /// 章节内容加载完成后，后台预加载相邻章节
  void _maybePreloadAdjacentChapters(ReaderProvider provider) {
    if (_wasLoading && !provider.loading && provider.error == null) {
      final index = provider.currentChapterIndex;
      if (index != _lastPreloadedIndex) {
        _lastPreloadedIndex = index;
        _preloadAdjacentChapters(provider);
      }
    }
    _wasLoading = provider.loading;
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<ReaderProvider>(
      builder: (context, provider, _) {
        _maybePreloadAdjacentChapters(provider);
        // 排版引擎：检测是否需要重新分页
        if (!provider.loading && provider.error == null) {
          _paginateIfNeeded(context, provider);
        }
        return PopScope<Object?>(
          // 退出阅读器时确保阅读进度已保存到书架
          onPopInvokedWithResult: (didPop, result) {
            if (didPop) {
              unawaited(provider.saveProgress());
            }
          },
          child: Scaffold(
            key: _scaffoldKey,
            backgroundColor: provider.backgroundColor,
            body: GestureDetector(
              onTapUp: (details) => _handleTap(context, details, provider),
              child: Stack(
                children: [
                  _buildContent(context, provider),
                  if (!provider.showControls) _buildStatusStrip(context, provider),
                  if (provider.showControls) _buildTopBar(context, provider),
                  if (provider.showControls) _buildBottomBar(context, provider),
                ],
              ),
            ),
            endDrawer: _buildCatalogDrawer(context, provider),
          ),
        );
      },
    );
  }

  Widget _buildContent(BuildContext context, ReaderProvider provider) {
    if (provider.loading) {
      return LoadingIndicator(message: AppStrings.loadingChapter);
    }

    if (provider.error != null) {
      return ErrorView(
        message: provider.error!,
        onRetry: () {
          if (provider.currentBook != null) {
            provider.openBook(provider.currentBook!);
          }
        },
      );
    }

    switch (provider.pageTurnMode) {
      case PageTurnMode.scroll:
        return _buildScrollContent(context, provider);
      case PageTurnMode.slide:
        return _buildSlideContent(context, provider);
      case PageTurnMode.simulate:
        return _buildSimulateContent(context, provider);
      case PageTurnMode.none:
        return _buildNoneContent(context, provider);
      case PageTurnMode.cover:
        return _buildCoverContent(context, provider);
    }
  }

  Widget _buildScrollContent(BuildContext context, ReaderProvider provider) {
    final isDark = provider.backgroundColor == ReaderBackground.dark;
    final textColor = isDark ? const Color(0xFFCCCCCC) : const Color(0xFF333333);

    return SafeArea(
      top: !provider.showControls,
      bottom: !provider.showControls,
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (provider.currentChapter != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 20),
                child: Text(
                  provider.currentChapter!.title,
                  style: TextStyle(
                    fontSize: provider.fontSize + 4,
                    fontWeight: FontWeight.bold,
                    color: textColor,
                  ),
                ),
              ),
            // 滚动模式：渲染所有分页内容（使用排版引擎的分行结果）
            if (_paginatedPages.isNotEmpty)
              for (final pageInfo in _paginatedPages)
                _renderPageContent(pageInfo, provider, textColor)
            else if (provider.chapterContent.isNotEmpty)
              _buildParagraphs(provider, provider.chapterContent, textColor)
            else if (!provider.loading)
              Center(
                child: Padding(
                  padding: const EdgeInsets.all(48),
                  child: Text(
                    AppStrings.noContent,
                    style: TextStyle(
                      fontSize: provider.fontSize,
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

  Widget _buildSlideContent(BuildContext context, ReaderProvider provider) {
    return SafeArea(
      top: !provider.showControls,
      bottom: !provider.showControls,
      child: PageView.builder(
        controller: _pageController,
        itemCount: _paginatedPages.isNotEmpty ? _paginatedPages.length : 1,
        onPageChanged: (index) {
          setState(() => _currentPageIndex = index);
          // 更新阅读进度
          provider.updatePosition(index);
        },
        itemBuilder: (context, index) {
          return _buildTypographicPage(context, provider, index);
        },
      ),
    );
  }

  Widget _buildSimulateContent(BuildContext context, ReaderProvider provider) {
    // 仿真翻页：PageView + 翻页阴影 + 缩放动画效果
    return SafeArea(
      top: !provider.showControls,
      bottom: !provider.showControls,
      child: Stack(
        children: [
          PageView.builder(
            controller: _pageController,
            itemCount: _paginatedPages.isNotEmpty ? _paginatedPages.length : 1,
            pageSnapping: true,
            onPageChanged: (index) {
              setState(() => _currentPageIndex = index);
              provider.updatePosition(index);
            },
            itemBuilder: (context, index) {
              return AnimatedBuilder(
                animation: _pageController,
                builder: (context, child) {
                  double value = 1.0;
                  if (_pageController.hasClients && _pageController.position.hasContentDimensions) {
                    value = (_pageController.page ?? _pageController.initialPage.toDouble()) - index;
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
                                    Colors.black.withValues(alpha: 0.12 * (1.0 - value)),
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
                child: _buildTypographicPage(context, provider, index),
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _buildNoneContent(BuildContext context, ReaderProvider provider) {
    // 无动画翻页：使用 PageView 但禁用动画
    return SafeArea(
      top: !provider.showControls,
      bottom: !provider.showControls,
      child: PageView.builder(
        controller: _pageController,
        physics: const InstantScrollPhysics(), // 无动画瞬间切换
        itemCount: _paginatedPages.isNotEmpty ? _paginatedPages.length : 1,
        onPageChanged: (index) {
          setState(() => _currentPageIndex = index);
          provider.updatePosition(index);
        },
        itemBuilder: (context, index) {
          return _buildTypographicPage(context, provider, index);
        },
      ),
    );
  }

  /// 覆盖翻页模式（对齐安卓 CoverPageDelegate）
  ///
  /// 视觉效果：
  /// - 前进（下一页）：新页从右侧滑入覆盖旧页，旧页保持不动
  /// - 后退（上一页）：当前页向右滑出，露出下方的新页
  /// 动画时长 300ms，线性曲线（对齐安卓基准）
  Widget _buildCoverContent(BuildContext context, ReaderProvider provider) {
    final targetIndex = _currentPageIndex;
    // 检测翻页方向
    if (targetIndex != _coverChapterIndex) {
      _coverForward = targetIndex > _coverChapterIndex;
      _coverChapterIndex = targetIndex;
    }
    final forward = _coverForward;

    return SafeArea(
      top: !provider.showControls,
      bottom: !provider.showControls,
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 300),
        switchInCurve: Curves.linear,
        switchOutCurve: Curves.linear,
        // 层叠策略：前进时新页在上（覆盖效果），后退时旧页在上（抽离效果）
        layoutBuilder: (currentChild, previousChildren) {
          return Stack(
            children: [
              ...previousChildren,
              ?currentChild,
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
                                Colors.black.withValues(
                                    alpha: 0.2 * (1 - animation.value)),
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
          child: _buildTypographicPage(context, provider, targetIndex),
        ),
      ),
    );
  }

  /// 渲染排版引擎分页后的单页内容
  ///
  /// 移植自安卓端 TextChapterLayout 的页面渲染逻辑：
  /// - 首屏显示章节标题
  /// - 正文使用排版引擎的分行结果渲染
  /// - 支持两端对齐、首行缩进、中文避头尾
  Widget _buildTypographicPage(BuildContext context, ReaderProvider provider, int pageIndex) {
    final isDark = provider.backgroundColor == ReaderBackground.dark;
    final textColor = isDark ? const Color(0xFFCCCCCC) : const Color(0xFF333333);

    // 分页结果尚未就绪时显示加载状态
    if (_paginatedPages.isEmpty) {
      return Center(
        child: Text(
          AppStrings.noContent,
          style: TextStyle(fontSize: provider.fontSize, color: textColor.withValues(alpha: 0.5)),
        ),
      );
    }

    // 安全索引
    final safeIndex = pageIndex.clamp(0, _paginatedPages.length - 1);
    final pageInfo = _paginatedPages[safeIndex];

    return Container(
      color: provider.backgroundColor,
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 第一页显示章节标题
          if (safeIndex == 0 && provider.currentChapter != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 20),
              child: Text(
                provider.currentChapter!.title,
                style: TextStyle(
                  fontSize: provider.fontSize + 4,
                  fontWeight: FontWeight.bold,
                  color: textColor,
                ),
              ),
            ),
          // 使用排版引擎渲染分页内容
          Expanded(
            child: _renderPageContent(pageInfo, provider, textColor),
          ),
          // 页码指示（对齐安卓端底部页码显示）
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Center(
              child: Text(
                '${safeIndex + 1} / ${_paginatedPages.length}',
                style: TextStyle(
                  fontSize: 11,
                  color: textColor.withValues(alpha: 0.4),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 渲染单页的排版内容（逐行渲染，支持两端对齐）
  ///
  /// 移植自 TextChapterLayout.kt 的 addCharsToLineFirst/Middle/Natural
  Widget _renderPageContent(PageInfo pageInfo, ReaderProvider provider, Color textColor) {
    final widgets = <Widget>[];

    for (var paraIdx = 0; paraIdx < pageInfo.paragraphs.length; paraIdx++) {
      final para = pageInfo.paragraphs[paraIdx];

      // 段落间距（非第一段时添加）
      if (paraIdx > 0 && provider.lineHeight > 0) {
        widgets.add(SizedBox(height: _advConfig.paragraphSpacing));
      }

      // 逐行渲染
      for (var lineIdx = 0; lineIdx < para.lines.length; lineIdx++) {
        final line = para.lines[lineIdx];
        final text = line.words.join('');
        final isLastLine = lineIdx == para.lines.length - 1;
        final isSingleLine = para.lines.length == 1;

        // 两端对齐：非最后一行且非单行时分配额外字间距
        double extraLetterSpacing = 0.0;
        final shouldJustify = !isLastLine && !isSingleLine;
        if (shouldJustify && line.width > 0) {
          final screenSize = MediaQuery.of(context).size;
          final availableWidth = screenSize.width - 40;
          if (line.width < availableWidth) {
            final gapCount = line.words.length - 1;
            if (gapCount > 0) {
              extraLetterSpacing = (availableWidth - line.width) / gapCount;
              // 限制最大字间距避免过度拉伸
              extraLetterSpacing = extraLetterSpacing.clamp(0.0, provider.fontSize * 0.5);
            }
          }
        }

        widgets.add(
          SizedBox(
            height: provider.fontSize * provider.lineHeight,
            child: Text(
              text,
              style: TextStyle(
                fontSize: provider.fontSize,
                height: provider.lineHeight,
                color: textColor,
                letterSpacing: extraLetterSpacing > 0.1 ? extraLetterSpacing : null,
              ),
              maxLines: 1,
              overflow: TextOverflow.clip,
            ),
          ),
        );
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: widgets,
    );
  }

  Widget _buildTopBar(BuildContext context, ReaderProvider provider) {
    final isDark = provider.backgroundColor == ReaderBackground.dark;
    final progressPct =
        (provider.readingProgress * 100).toStringAsFixed(1);
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: Material(
        color: Theme.of(context).colorScheme.surface,
        elevation: 2,
        child: SafeArea(
          bottom: false,
          child: SizedBox(
            height: kToolbarHeight,
            child: Row(
              children: [
                IconButton(
                  icon: const Icon(Icons.arrow_back),
                  onPressed: () => Navigator.of(context).pop(),
                ),
                Expanded(
                  child: Text(
                    provider.currentBook?.name ?? '',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                // 阅读进度百分比
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Text(
                    '$progressPct%',
                    style: Theme.of(context).textTheme.labelMedium?.copyWith(
                          color: Theme.of(context).colorScheme.primary,
                          fontWeight: FontWeight.w600,
                        ),
                  ),
                ),
                // 夜间模式快速切换
                IconButton(
                  icon: Icon(
                    isDark ? Icons.light_mode : Icons.dark_mode,
                  ),
                  tooltip: isDark ? '日间模式' : '夜间模式',
                  onPressed: () {
                    provider.updateBackgroundColor(
                      isDark ? ReaderBackground.white : ReaderBackground.dark,
                    );
                  },
                ),
                // 正文搜索
                IconButton(
                  icon: const Icon(Icons.search),
                  tooltip: '搜索正文',
                  onPressed: () => _openContentSearch(context, provider),
                ),
                // 书签按钮
                IconButton(
                  icon: const Icon(Icons.bookmark_add_outlined),
                  tooltip: '添加书签',
                  onPressed: () => _addBookmark(context, provider),
                ),
                IconButton(
                  icon: const Icon(Icons.more_vert),
                  tooltip: '高级设置',
                  onPressed: () => _openAdvancedConfig(context),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildBottomBar(BuildContext context, ReaderProvider provider) {
    return Positioned(
      bottom: 0,
      left: 0,
      right: 0,
      child: Material(
        color: Theme.of(context).colorScheme.surface,
        elevation: 4,
        child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 进度条
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  children: [
                    IconButton(
                      icon: const Icon(Icons.skip_previous),
                      onPressed: provider.hasPreviousChapter
                          ? () => provider.prevChapter()
                          : null,
                      tooltip: AppStrings.previousChapter,
                    ),
                    Expanded(
                      child: Slider(
                        value: provider.chapters.isNotEmpty
                            ? provider.currentChapterIndex.toDouble()
                            : 0,
                        min: 0,
                        max: provider.chapters.length > 1
                            ? (provider.chapters.length - 1).toDouble()
                            : 1,
                        divisions: provider.chapters.length > 1
                            ? provider.chapters.length - 1
                            : null,
                        onChanged: (value) {
                          provider.goToChapter(value.toInt());
                        },
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.skip_next),
                      onPressed: provider.hasNextChapter
                          ? () => provider.nextChapter()
                          : null,
                      tooltip: AppStrings.nextChapter,
                    ),
                  ],
                ),
              ),
              // 功能按钮
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  _buildBottomAction(
                    context,
                    Icons.format_list_numbered,
                    AppStrings.catalog,
                    () => Scaffold.of(context).openEndDrawer(),
                  ),
                  _buildBottomAction(
                    context,
                    Icons.settings,
                    AppStrings.settings,
                    () => _showSettingsSheet(context, provider),
                  ),
                  _buildBottomAction(
                    context,
                    Icons.brightness_6,
                    AppStrings.nightMode,
                    () {
                      final isDark =
                          provider.backgroundColor == ReaderBackground.dark;
                      provider.updateBackgroundColor(
                        isDark ? ReaderBackground.white : ReaderBackground.dark,
                      );
                    },
                  ),
                ],
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBottomAction(
    BuildContext context,
    IconData icon,
    String label,
    VoidCallback onTap,
  ) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 22),
            const SizedBox(height: 2),
            Text(label, style: Theme.of(context).textTheme.labelSmall),
          ],
        ),
      ),
    );
  }

  Widget _buildCatalogDrawer(BuildContext context, ReaderProvider provider) {
    return Drawer(
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                provider.currentBook?.name ?? AppStrings.catalog,
                style: Theme.of(context).textTheme.titleLarge,
              ),
            ),
            // 目录搜索框
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: TextField(
                decoration: InputDecoration(
                  hintText: '搜索章节...',
                  isDense: true,
                  prefixIcon: const Icon(Icons.search, size: 20),
                  suffixIcon: _chapterSearchQuery.isEmpty
                      ? null
                      : IconButton(
                          icon: const Icon(Icons.clear, size: 18),
                          onPressed: () =>
                              setState(() => _chapterSearchQuery = ''),
                        ),
                  border: const OutlineInputBorder(),
                ),
                onChanged: (query) =>
                    setState(() => _chapterSearchQuery = query),
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: _buildCatalogList(context, provider),
            ),
          ],
        ),
      ),
    );
  }

  /// 目录列表（支持按章节标题搜索过滤，保留原始索引用于跳转）
  Widget _buildCatalogList(BuildContext context, ReaderProvider provider) {
    if (provider.chapters.isEmpty) {
      return Center(child: Text(AppStrings.noChapters));
    }

    final query = _chapterSearchQuery.trim().toLowerCase();
    final entries = query.isEmpty
        ? provider.chapters.asMap().entries.toList()
        : provider.chapters
            .asMap()
            .entries
            .where((e) => e.value.title.toLowerCase().contains(query))
            .toList();

    if (entries.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            '未找到匹配的章节',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
          ),
        ),
      );
    }

    return ListView.builder(
      itemCount: entries.length,
      itemBuilder: (context, i) {
        final entry = entries[i];
        final chapter = entry.value;
        final isCurrent = entry.key == provider.currentChapterIndex;
        return ListTile(
          title: Text(
            chapter.title,
            style: TextStyle(
              fontWeight:
                  isCurrent ? FontWeight.bold : FontWeight.normal,
              color: isCurrent
                  ? Theme.of(context).colorScheme.primary
                  : null,
            ),
          ),
          dense: true,
          selected: isCurrent,
          onTap: () {
            Navigator.of(context).pop(); // 关闭 drawer
            provider.goToChapter(entry.key);
          },
        );
      },
    );
  }

  /// 预加载当前章节的前后各 1 章内容，提升翻页阅读体验（静默失败）
  void _preloadAdjacentChapters(ReaderProvider provider) {
    final book = provider.currentBook;
    final chapters = provider.chapters;
    if (book == null || chapters.isEmpty) return;

    final api = context.read<BookApi>();
    final index = provider.currentChapterIndex;

    // 预加载下一章
    if (index + 1 < chapters.length) {
      unawaited(
        api.getChapterContent(book.bookUrl, index + 1).catchError((_) => ''),
      );
    }
    // 预加载上一章
    if (index > 0) {
      unawaited(
        api.getChapterContent(book.bookUrl, index - 1).catchError((_) => ''),
      );
    }
  }

  // ===== 交互 =====

  void _addBookmark(BuildContext context, ReaderProvider provider) {
    final book = provider.currentBook;
    final chapter = provider.currentChapter;
    if (book == null || chapter == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('无法添加书签：未打开书籍')),
      );
      return;
    }
    // 提取当前章节内容前 100 字符作为摘要
    final content = provider.chapterContent;
    final summary = content.length > 100 ? content.substring(0, 100) : content;

    context.read<BookmarkProvider>().addBookmark(
          bookName: book.name,
          bookAuthor: book.author,
          chapterIndex: provider.currentChapterIndex,
          chapterPos: 0,
          chapterName: chapter.title,
          bookText: summary,
        );
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('已添加书签：${chapter.title}')),
    );
  }

  void _handleTap(
    BuildContext context,
    TapUpDetails details,
    ReaderProvider provider,
  ) {
    final screenWidth = MediaQuery.of(context).size.width;
    final tapX = details.globalPosition.dx;

    // 根据点击区域配置执行对应功能
    TapAction action;
    if (tapX < screenWidth * 0.3) {
      action = _advConfig.leftAction;
    } else if (tapX > screenWidth * 0.7) {
      action = _advConfig.rightAction;
    } else {
      action = _advConfig.centerAction;
    }
    _performTapAction(action, provider);
  }

  void _performTapAction(TapAction action, ReaderProvider provider) {
    switch (action) {
      case TapAction.none:
        break;
      case TapAction.prevPage:
        _goToPrevChapterOrPage(provider);
      case TapAction.nextPage:
        _goToNextChapterOrPage(provider);
      case TapAction.toggleControls:
        provider.toggleControls();
      case TapAction.openCatalog:
        _scaffoldKey.currentState?.openEndDrawer();
    }
  }

  /// 打开正文搜索页面
  void _openContentSearch(BuildContext context, ReaderProvider provider) {
    final book = provider.currentBook;
    if (book == null) return;
    Navigator.pushNamed(
      context,
      AppRoutes.searchContent,
      arguments: book,
    );
  }

  /// 打开高级设置面板，配置变更后实时应用
  Future<void> _openAdvancedConfig(BuildContext context) async {
    await ReaderConfigPanel.show(
      context,
      config: _advConfig,
      onChanged: (cfg) {
        _advConfig = cfg;
        _syncAutoTimer();
        if (mounted) setState(() {});
      },
    );
  }

  /// 按段落渲染正文，应用配置的段落间距
  Widget _buildParagraphs(ReaderProvider provider, String content, Color textColor) {
    final spacing = _advConfig.paragraphSpacing;
    final paragraphs = content.split('\n');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final p in paragraphs)
          Padding(
            padding: EdgeInsets.only(bottom: spacing),
            child: Text(
              p.isEmpty ? ' ' : p,
              style: TextStyle(
                fontSize: provider.fontSize,
                height: provider.lineHeight,
                color: textColor,
              ),
            ),
          ),
      ],
    );
  }

  /// 隐藏控制栏时顶部的状态提示栏（电量/时间/进度/章节名）
  Widget _buildStatusStrip(BuildContext context, ReaderProvider provider) {
    final cfg = _advConfig;
    if (!cfg.showBattery && !cfg.showTime && !cfg.showProgress && !cfg.showChapterName) {
      return const SizedBox.shrink();
    }
    final isDark = provider.backgroundColor == ReaderBackground.dark;
    final color = isDark ? const Color(0xFFBBBBBB) : const Color(0xFF888888);
    final now = DateTime.now();
    final time =
        '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';
    final progress = '${(provider.readingProgress * 100).toStringAsFixed(1)}%';
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          child: DefaultTextStyle(
            style: TextStyle(fontSize: 11, color: color),
            child: Row(
              children: [
                if (cfg.showBattery) ...[
                  Icon(Icons.battery_std, size: 12, color: color),
                  const SizedBox(width: 4),
                ],
                if (cfg.showTime) ...[
                  Text(time),
                  const SizedBox(width: 10),
                ],
                const Spacer(),
                if (cfg.showChapterName)
                  Flexible(
                    child: Text(
                      provider.currentChapter?.title ?? '',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                if (cfg.showProgress) ...[
                  const SizedBox(width: 10),
                  Text(progress),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _showSettingsSheet(BuildContext context, ReaderProvider provider) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => _ReaderSettingsSheet(provider: provider),
    );
  }
}

/// 阅读设置底部弹出面板
class _ReaderSettingsSheet extends StatelessWidget {
  final ReaderProvider provider;

  const _ReaderSettingsSheet({required this.provider});

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(AppStrings.readingSettingsTitle, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 20),

            // 字体大小
            Text(AppStrings.fontSizeLabel, style: Theme.of(context).textTheme.bodyMedium),
            Row(
              children: [
                Text(AppStrings.fontSmall, style: const TextStyle(fontSize: 12)),
                Expanded(
                  child: Slider(
                    value: provider.fontSize,
                    min: 12,
                    max: 32,
                    divisions: 20,
                    label: provider.fontSize.round().toString(),
                    onChanged: (v) => provider.updateFontSize(v),
                  ),
                ),
                Text(AppStrings.fontLarge, style: const TextStyle(fontSize: 20)),
              ],
            ),

            // 行距
            Text(AppStrings.lineHeightLabel, style: Theme.of(context).textTheme.bodyMedium),
            Row(
              children: [
                for (final value in [1.2, 1.6, 2.0, 2.5])
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                      label: Text('${value}x'),
                      selected: provider.lineHeight == value,
                      onSelected: (_) => provider.updateLineHeight(value),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 12),

            // 背景色
            Text(AppStrings.bgColor, style: Theme.of(context).textTheme.bodyMedium),
            const SizedBox(height: 8),
            Row(
              children: List.generate(ReaderBackground.presets.length, (i) {
                final color = ReaderBackground.presets[i];
                final label = ReaderBackground.labels[i];
                final isSelected = provider.backgroundColor == color;
                return Padding(
                  padding: const EdgeInsets.only(right: 12),
                  child: GestureDetector(
                    onTap: () => provider.updateBackgroundColor(color),
                    child: Column(
                      children: [
                        Container(
                          width: 44,
                          height: 44,
                          decoration: BoxDecoration(
                            color: color,
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: isSelected
                                  ? Theme.of(context).colorScheme.primary
                                  : Theme.of(context).colorScheme.outlineVariant,
                              width: isSelected ? 3 : 1,
                            ),
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(label, style: Theme.of(context).textTheme.labelSmall),
                      ],
                    ),
                  ),
                );
              }),
            ),
            const SizedBox(height: 16),

            // 翻页模式
            Text(AppStrings.flipModeLabel, style: Theme.of(context).textTheme.bodyMedium),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: [
                ChoiceChip(
                  label: Text(AppStrings.coverMode),
                  selected: provider.pageTurnMode == PageTurnMode.cover,
                  onSelected: (_) =>
                      provider.updatePageTurnMode(PageTurnMode.cover),
                ),
                ChoiceChip(
                  label: Text(AppStrings.slideMode),
                  selected: provider.pageTurnMode == PageTurnMode.slide,
                  onSelected: (_) =>
                      provider.updatePageTurnMode(PageTurnMode.slide),
                ),
                ChoiceChip(
                  label: Text(AppStrings.simulateMode),
                  selected: provider.pageTurnMode == PageTurnMode.simulate,
                  onSelected: (_) =>
                      provider.updatePageTurnMode(PageTurnMode.simulate),
                ),
                ChoiceChip(
                  label: Text(AppStrings.scrollMode),
                  selected: provider.pageTurnMode == PageTurnMode.scroll,
                  onSelected: (_) =>
                      provider.updatePageTurnMode(PageTurnMode.scroll),
                ),
                ChoiceChip(
                  label: Text(AppStrings.noneMode),
                  selected: provider.pageTurnMode == PageTurnMode.none,
                  onSelected: (_) =>
                      provider.updatePageTurnMode(PageTurnMode.none),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
