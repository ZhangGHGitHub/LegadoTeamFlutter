import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;

import '../../providers/reader/reader_notifier.dart';

/// 阅读器顶部工具栏
///
/// 对齐安卓原版 ReadMenu 顶部 TitleBar：
/// 返回键 + 书名 + 阅读进度百分比 + 夜间模式 + 正文搜索 + 书签 + 高级设置
class ReaderTopBar extends ConsumerWidget {
  final VoidCallback onOpenContentSearch;
  final VoidCallback onAddBookmark;
  final VoidCallback onOpenAdvancedConfig;

  const ReaderTopBar({
    super.key,
    required this.onOpenContentSearch,
    required this.onAddBookmark,
    required this.onOpenAdvancedConfig,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(readerNotifierProvider);
    final notifier = ref.read(readerNotifierProvider.notifier);
    final isDark = state.isDarkBackground;
    final progressPct = (state.readingProgress * 100).toStringAsFixed(1);

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
                    state.currentBook?.name ?? '',
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
                    notifier.updateBackgroundColor(
                      isDark ? ReaderBackground.white : ReaderBackground.dark,
                    );
                  },
                ),
                // 正文搜索
                IconButton(
                  icon: const Icon(Icons.search),
                  tooltip: '搜索正文',
                  onPressed: onOpenContentSearch,
                ),
                // 书签按钮
                IconButton(
                  icon: const Icon(Icons.bookmark_add_outlined),
                  tooltip: '添加书签',
                  onPressed: onAddBookmark,
                ),
                IconButton(
                  icon: const Icon(Icons.more_vert),
                  tooltip: '高级设置',
                  onPressed: onOpenAdvancedConfig,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
