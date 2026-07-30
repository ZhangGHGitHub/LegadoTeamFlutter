import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/app_strings.dart';
import '../routes.dart';
import '../services/rust_api.dart';
import '../providers/bookmark_provider.dart';
import '../providers/reader_provider.dart';
import '../widgets/loading_indicator.dart';
import '../widgets/error_view.dart';
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

  /// 阅读器高级配置（自动翻页/点击区域/段距/状态栏）
  ReaderAdvancedConfig _advConfig = ReaderAdvancedConfig();

  /// 自动翻页定时器
  Timer? _autoTimer;

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
        provider.nextChapter();
      } else {
        provider.prevChapter();
      }
    });
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
            if (provider.chapterContent.isNotEmpty)
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
        itemCount: provider.chapters.isNotEmpty ? provider.chapters.length : 1,
        onPageChanged: (index) {
          if (index != provider.currentChapterIndex) {
            provider.goToChapter(index);
          }
        },
        itemBuilder: (context, index) {
          return _buildChapterPage(context, provider, index);
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
            itemCount: provider.chapters.isNotEmpty ? provider.chapters.length : 1,
            pageSnapping: true,
            onPageChanged: (index) {
              if (index != provider.currentChapterIndex) {
                provider.goToChapter(index);
              }
            },
            itemBuilder: (context, index) {
              return AnimatedBuilder(
                animation: _pageController,
                builder: (context, child) {
                  double value = 1.0;
                  if (_pageController.position.hasContentDimensions) {
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
                child: _buildChapterPage(context, provider, index),
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
        itemCount: provider.chapters.isNotEmpty ? provider.chapters.length : 1,
        itemBuilder: (context, index) {
          return _buildChapterPage(context, provider, index);
        },
      ),
    );
  }

  Widget _buildChapterPage(BuildContext context, ReaderProvider provider, int index) {
    final isDark = provider.backgroundColor == ReaderBackground.dark;
    final textColor = isDark ? const Color(0xFFCCCCCC) : const Color(0xFF333333);
    final isCurrentChapter = index == provider.currentChapterIndex;
    final title = isCurrentChapter && provider.currentChapter != null
        ? provider.currentChapter!.title
        : (index < provider.chapters.length ? provider.chapters[index].title : '');
    final content = isCurrentChapter ? provider.chapterContent : '';

    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (title.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 20),
              child: Text(
                title,
                style: TextStyle(
                  fontSize: provider.fontSize + 4,
                  fontWeight: FontWeight.bold,
                  color: textColor,
                ),
              ),
            ),
          if (content.isNotEmpty)
            _buildParagraphs(provider, content, textColor)
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

    final api = context.read<RustApi>();
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
        provider.prevChapter();
      case TapAction.nextPage:
        provider.nextChapter();
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
      arguments: {'bookUrl': book.bookUrl, 'bookName': book.name},
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
                                  : Colors.grey.shade300,
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
                  label: Text(AppStrings.scrollMode),
                  selected: provider.pageTurnMode == PageTurnMode.scroll,
                  onSelected: (_) =>
                      provider.updatePageTurnMode(PageTurnMode.scroll),
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
              ],
            ),
          ],
        ),
      ),
    );
  }
}
