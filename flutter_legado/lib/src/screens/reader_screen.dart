import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/app_strings.dart';
import '../providers/bookmark_provider.dart';
import '../providers/reader_provider.dart';
import '../widgets/loading_indicator.dart';
import '../widgets/error_view.dart';

/// 阅读器页面
class ReaderScreen extends StatefulWidget {
  const ReaderScreen({super.key});

  @override
  State<ReaderScreen> createState() => _ReaderScreenState();
}

class _ReaderScreenState extends State<ReaderScreen> {
  final PageController _pageController = PageController();

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<ReaderProvider>(
      builder: (context, provider, _) {
        return Scaffold(
          backgroundColor: provider.backgroundColor,
          body: GestureDetector(
            onTapUp: (details) => _handleTap(context, details, provider),
            child: Stack(
              children: [
                _buildContent(context, provider),
                if (provider.showControls) _buildTopBar(context, provider),
                if (provider.showControls) _buildBottomBar(context, provider),
              ],
            ),
          ),
          endDrawer: _buildCatalogDrawer(context, provider),
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
              Text(
                provider.chapterContent,
                style: TextStyle(
                  fontSize: provider.fontSize,
                  height: provider.lineHeight,
                  color: textColor,
                ),
              )
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
    // 仿真翻页：使用 PageView + 翻页动画效果
    return SafeArea(
      top: !provider.showControls,
      bottom: !provider.showControls,
      child: PageView.builder(
        controller: _pageController,
        itemCount: provider.chapters.isNotEmpty ? provider.chapters.length : 1,
        pageSnapping: true,
        onPageChanged: (index) {
          if (index != provider.currentChapterIndex) {
            provider.goToChapter(index);
          }
        },
        itemBuilder: (context, index) {
          return AnimatedSwitcher(
            duration: const Duration(milliseconds: 400),
            switchInCurve: Curves.easeInOut,
            transitionBuilder: (child, animation) {
              return FadeTransition(opacity: animation, child: child);
            },
            child: _buildChapterPage(context, provider, index),
          );
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
            Text(
              content,
              style: TextStyle(
                fontSize: provider.fontSize,
                height: provider.lineHeight,
                color: textColor,
              ),
            )
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
                // 书签按钮
                IconButton(
                  icon: const Icon(Icons.bookmark_add_outlined),
                  tooltip: '添加书签',
                  onPressed: () => _addBookmark(context, provider),
                ),
                IconButton(
                  icon: const Icon(Icons.more_vert),
                  onPressed: () {},
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
            const Divider(height: 1),
            Expanded(
              child: provider.chapters.isEmpty
                  ? Center(child: Text(AppStrings.noChapters))
                  : ListView.builder(
                      itemCount: provider.chapters.length,
                      itemBuilder: (context, index) {
                        final chapter = provider.chapters[index];
                        final isCurrent =
                            index == provider.currentChapterIndex;
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
                            provider.goToChapter(index);
                          },
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
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

    // 点击中间区域：切换控制栏
    if (tapX > screenWidth * 0.3 && tapX < screenWidth * 0.7) {
      provider.toggleControls();
    }
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
