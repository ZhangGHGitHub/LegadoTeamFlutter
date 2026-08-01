import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;

import '../../l10n/app_strings.dart';
import '../../providers/reader/reader_notifier.dart';

/// 阅读器目录抽屉
///
/// 对齐安卓原版目录列表：书名标题 + 章节搜索框 + 章节列表（当前章节高亮）
class ReaderCatalogDrawer extends ConsumerStatefulWidget {
  const ReaderCatalogDrawer({super.key});

  @override
  ConsumerState<ReaderCatalogDrawer> createState() =>
      _ReaderCatalogDrawerState();
}

class _ReaderCatalogDrawerState extends ConsumerState<ReaderCatalogDrawer> {
  /// 目录搜索关键词
  String _chapterSearchQuery = '';

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(readerNotifierProvider);
    final notifier = ref.read(readerNotifierProvider.notifier);

    return Drawer(
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                state.currentBook?.name ?? AppStrings.catalog,
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
              child: _buildCatalogList(context, state, notifier),
            ),
          ],
        ),
      ),
    );
  }

  /// 目录列表（支持按章节标题搜索过滤，保留原始索引用于跳转）
  Widget _buildCatalogList(
    BuildContext context,
    ReaderState state,
    ReaderNotifier notifier,
  ) {
    if (state.chapters.isEmpty) {
      return Center(child: Text(AppStrings.noChapters));
    }

    final query = _chapterSearchQuery.trim().toLowerCase();
    final entries = query.isEmpty
        ? state.chapters.asMap().entries.toList()
        : state.chapters
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
        final isCurrent = entry.key == state.currentChapterIndex;
        return ListTile(
          title: Text(
            chapter.title,
            style: TextStyle(
              fontWeight: isCurrent ? FontWeight.bold : FontWeight.normal,
              color: isCurrent
                  ? Theme.of(context).colorScheme.primary
                  : null,
            ),
          ),
          dense: true,
          selected: isCurrent,
          onTap: () {
            Navigator.of(context).pop(); // 关闭 drawer
            notifier.goToChapter(entry.key);
          },
        );
      },
    );
  }
}
