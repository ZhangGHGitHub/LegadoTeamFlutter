import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;

import '../l10n/app_strings.dart';
import '../models/models.dart';
import '../providers/bookshelf/bookshelf_notifier.dart';
import '../providers/search/search_notifier.dart';
import '../widgets/book_cover.dart';
import '../widgets/empty_state.dart';
import '../widgets/error_view.dart';
import '../widgets/loading_indicator.dart';
import '../widgets/search_filter_panel.dart';

/// 搜索页面
///
/// 状态由 [SearchNotifier]（Riverpod）管理；加书架过渡期仍用 BookshelfProvider。
class SearchScreen extends ConsumerStatefulWidget {
  const SearchScreen({super.key});

  @override
  ConsumerState<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends ConsumerState<SearchScreen> {
  final _searchController = TextEditingController();
  final _focusNode = FocusNode();
  // 精准搜索开关（对标原版 menu_precision_search，展示层精确书名过滤）
  bool _precision = false;

  @override
  void dispose() {
    _searchController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: _buildAppBar(context),
      body: _buildBody(context),
    );
  }

  PreferredSizeWidget _buildAppBar(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return AppBar(
      title: Container(
        height: 36,
        margin: const EdgeInsets.symmetric(vertical: 4),
        child: TextField(
          controller: _searchController,
          focusNode: _focusNode,
          // 对标原版 SearchActivity：进入即聚焦弹出键盘
          autofocus: true,
          decoration: InputDecoration(
            hintText: AppStrings.searchBookHint,
            // 安卓端 bg_searchview: 35dp圆角胶囊形、半透明填充、0.5dp描边
            filled: true,
            fillColor: colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 0),
            prefixIcon: const Icon(Icons.search, size: 20),
            suffixIcon: _searchController.text.isNotEmpty
                ? IconButton(
                    icon: const Icon(Icons.clear, size: 20),
                    onPressed: () {
                      _searchController.clear();
                      ref.read(searchNotifierProvider.notifier).clearResults();
                    },
                  )
                : null,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(35),
              borderSide: BorderSide.none,
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(35),
              borderSide: BorderSide(
                color: colorScheme.surfaceContainerHighest,
                width: 0.5,
              ),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(35),
              borderSide: BorderSide(
                color: colorScheme.primary.withValues(alpha: 0.5),
                width: 0.5,
              ),
            ),
          ),
          textInputAction: TextInputAction.search,
          onSubmitted: (value) =>
              ref.read(searchNotifierProvider.notifier).search(value),
          // 实时驱动联想过滤（对标原版 SearchActivity.upHistory）
          onChanged: (value) =>
              ref.read(searchNotifierProvider.notifier).setInput(value),
        ),
      ),
      actions: [
        // 安卓原版：右侧「>」图标提交搜索
        IconButton(
          icon: const Icon(Icons.arrow_forward),
          tooltip: AppStrings.search,
          onPressed: () {
            final text = _searchController.text.trim();
            if (text.isNotEmpty) {
              ref.read(searchNotifierProvider.notifier).search(text);
            }
          },
        ),
        // 安卓原版：三点菜单（book_search.xml：精准搜索/显示搜索记录/书源管理/分组或书源/日志）
        PopupMenuButton<String>(
          onSelected: (value) {
            switch (value) {
              case 'precision':
                setState(() => _precision = !_precision);
                break;
              case 'readRecord':
                _todo(context, '显示搜索记录');
                break;
              case 'sources':
                Navigator.pushNamed(context, '/sources');
                break;
              case 'scope':
                SearchFilterPanel.show(context);
                break;
              case 'log':
                _todo(context, '日志');
                break;
            }
          },
          itemBuilder: (_) => [
            CheckedPopupMenuItem(
              value: 'precision',
              checked: _precision,
              child: const Text('精准搜索'),
            ),
            const PopupMenuItem(value: 'readRecord', child: Text('显示搜索记录')),
            const PopupMenuItem(value: 'sources', child: Text('书源管理')),
            const PopupMenuItem(value: 'scope', child: Text('分组或书源')),
            const PopupMenuItem(value: 'log', child: Text('日志')),
          ],
        ),
      ],
    );
  }

  Widget _buildBody(BuildContext context) {
    final state = ref.watch(searchNotifierProvider);
    // 精准搜索：展示层按精确书名过滤（对标原版 menu_precision_search）
    final results = _precision
        ? state.results
            .where((r) => r.book.name == state.keyword)
            .toList(growable: false)
        : state.results;

    if (state.isLoading) {
      return LoadingIndicator(message: AppStrings.searching);
    }

    if (state.error != null) {
      return ErrorView(
        message: state.error!,
        onRetry: () {
          if (state.keyword.isNotEmpty) {
            ref.read(searchNotifierProvider.notifier).search(state.keyword);
          }
        },
      );
    }

    if (state.isEmpty || (_precision && results.isEmpty)) {
      return EmptyState(
        icon: Icons.search_off,
        title: AppStrings.noResults,
        subtitle: AppStrings.noResultsHint,
      );
    }

    if (!state.hasResults) {
      return _buildSearchHistory(context, state);
    }

    return Column(
      children: [
        // 结果统计
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            children: [
              Text(
                '${AppStrings.search}: ${results.length}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const Spacer(),
              if (state.selectedGroups.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ActionChip(
                    avatar: const Icon(Icons.folder, size: 16),
                    label: Text('${state.selectedGroups.length} 分组'),
                    onPressed: () => ref
                        .read(searchNotifierProvider.notifier)
                        .clearGroupFilter(),
                  ),
                ),
              if (state.selectedSourceUrls.isNotEmpty)
                ActionChip(
                  avatar: const Icon(Icons.filter_list, size: 16),
                  label: Text(
                      '${state.selectedSourceUrls.length} ${AppStrings.sources}'),
                  onPressed: () => ref
                      .read(searchNotifierProvider.notifier)
                      .clearSourceFilter(),
                ),
            ],
          ),
        ),
        // 结果列表
        Expanded(
          child: ListView.separated(
            itemCount: results.length,
            separatorBuilder: (_, _) => const Divider(height: 1, indent: 88),
            itemBuilder: (context, index) {
              final result = results[index];
              return _buildResultItem(context, result);
            },
          ),
        ),
      ],
    );
  }

  /// 搜索结果项（对标原版 item_search.xml：80x110 封面 + 书名 16sp +
  /// 作者/最新章节 12sp + 简介 3 行 + 右上角来源徽标）
  Widget _buildResultItem(BuildContext context, SearchResult result) {
    final book = result.book;
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final infoStyle = theme.textTheme.bodySmall?.copyWith(fontSize: 12);
    // 稳定 ValueKey（来源+书址）避免结果列表整表重建；RepaintBoundary 隔离重绘区域
    final tile = InkWell(
      key: ValueKey('${result.sourceName}:${book.bookUrl}'),
      onTap: () => _showBookDetail(context, result),
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            BookCover(
              coverUrl: book.coverUrl,
              width: 80,
              height: 110,
              // iOS 风格圆角封面
              borderRadius: 10,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 书名 16sp + 右侧来源徽标（对标 tv_name + bv_originCount）
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          book.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 16,
                            color: colorScheme.onSurface,
                          ),
                        ),
                      ),
                      // 来源徽标（iOS 风格填充胶囊）
                      Container(
                        margin: const EdgeInsets.only(left: 8),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: colorScheme.primaryContainer,
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          result.sourceName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 11,
                            color: colorScheme.onPrimaryContainer,
                          ),
                        ),
                      ),
                    ],
                  ),
                  // 作者行（对标 tv_author 12sp）
                  if (book.author.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 3),
                      child: Text(
                        book.author,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: infoStyle,
                      ),
                    ),
                  // 最新章节行（对标 tv_lasted 12sp）
                  if ((book.latestChapterTitle ?? '').isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text(
                        '最新：${book.latestChapterTitle}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: infoStyle,
                      ),
                    ),
                  // 简介（对标 tv_introduce 12sp 最多 3 行）
                  if (book.intro != null && book.intro!.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text(
                        book.intro!,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: infoStyle?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
    return RepaintBoundary(child: tile);
  }

  void _showBookDetail(BuildContext context, SearchResult result) {
    final book = result.book;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(book.name),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                BookCover(coverUrl: book.coverUrl, width: 80, height: 110, borderRadius: 10),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (book.author.isNotEmpty)
                        Text('${AppStrings.author}: ${book.author}',
                            style: Theme.of(ctx).textTheme.bodyMedium),
                      Text('${AppStrings.source}: ${result.sourceName}',
                          style: Theme.of(ctx).textTheme.bodySmall),
                      if (book.totalChapterNum > 0)
                        Text('${book.totalChapterNum} ${AppStrings.chapters}',
                            style: Theme.of(ctx).textTheme.bodySmall),
                    ],
                  ),
                ),
              ],
            ),
            if (book.intro != null && book.intro!.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text(
                book.intro!,
                maxLines: 4,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(ctx).textTheme.bodySmall,
              ),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(AppStrings.cancel),
          ),
          FilledButton.icon(
            onPressed: () {
              Navigator.pop(ctx);
              _addToBookshelf(context, book);
            },
            icon: const Icon(Icons.add, size: 18),
            label: Text(AppStrings.addToBookshelf),
          ),
        ],
      ),
    );
  }

  void _addToBookshelf(BuildContext context, Book book) {
    // 书架数据源由 BookshelfNotifier 提供（book_info_screen 等同步使用）
    ref.read(bookshelfNotifierProvider.notifier).addBook(book);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('${book.name} ${AppStrings.addedToBookshelf}')),
    );
  }

  /// 未移植功能提示
  void _todo(BuildContext context, String feature) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('「$feature」后续版本支持')),
    );
  }

  /// 搜索历史/联想区（无结果时显示，对标安卓原版「输入帮助」区域）
  ///
  /// 输入为空时展示全部历史；输入非空时展示前缀联想词（[SearchState.suggestions]）。
  Widget _buildSearchHistory(BuildContext context, SearchState state) {
    final suggestions = state.suggestions;
    if (state.searchHistory.isEmpty) {
      // 安卓原版：无历史时显示纯灰字提示
      return const EmptyState(
        icon: Icons.search,
        title: '搜索书名、作者',
        simple: true,
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Row(
            children: [
              Text(
                AppStrings.searchHistory,
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
              ),
              const Spacer(),
              TextButton.icon(
                onPressed: () =>
                    ref.read(searchNotifierProvider.notifier).clearHistory(),
                icon: const Icon(Icons.delete_outline, size: 18),
                label: Text(AppStrings.clearHistory),
              ),
            ],
          ),
        ),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: suggestions.isEmpty
                // 联想无匹配（原版：联想列表为空时隐藏历史项）
                ? Padding(
                    padding: const EdgeInsets.only(top: 24),
                    child: Center(
                      child: Text(
                        '无匹配的历史关键词',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurfaceVariant,
                            ),
                      ),
                    ),
                  )
                : Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: suggestions.map((keyword) {
                      return ActionChip(
                        label: Text(keyword),
                        onPressed: () {
                          _searchController.text = keyword;
                          ref
                              .read(searchNotifierProvider.notifier)
                              .setInput(keyword);
                          ref
                              .read(searchNotifierProvider.notifier)
                              .search(keyword);
                        },
                      );
                    }).toList(),
                  ),
          ),
        ),
      ],
    );
  }
}
