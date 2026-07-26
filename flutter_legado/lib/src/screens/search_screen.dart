import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/app_strings.dart';
import '../models/models.dart';
import '../providers/bookshelf_provider.dart';
import '../providers/search_provider.dart';
import '../services/rust_api.dart';
import '../widgets/book_cover.dart';
import '../widgets/empty_state.dart';
import '../widgets/error_view.dart';
import '../widgets/loading_indicator.dart';

/// 搜索页面
class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key});

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  final _searchController = TextEditingController();
  final _focusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<SearchProvider>().loadHistory();
    });
  }

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
    final provider = context.watch<SearchProvider>();
    return AppBar(
      title: TextField(
        controller: _searchController,
        focusNode: _focusNode,
        decoration: InputDecoration(
          hintText: AppStrings.searchBookHint,
          border: InputBorder.none,
          filled: true,
          fillColor: Theme.of(context).colorScheme.surfaceContainerHighest,
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          prefixIcon: const Icon(Icons.search, size: 20),
          suffixIcon: _searchController.text.isNotEmpty
              ? IconButton(
                  icon: const Icon(Icons.clear, size: 20),
                  onPressed: () {
                    _searchController.clear();
                    provider.clearResults();
                  },
                )
              : null,
        ),
        textInputAction: TextInputAction.search,
        onSubmitted: (value) => provider.search(value),
        onChanged: (_) => setState(() {}),
      ),
      actions: [
        TextButton(
          onPressed: () {
            final text = _searchController.text.trim();
            if (text.isNotEmpty) {
              provider.search(text);
            }
          },
          child: Text(AppStrings.search),
        ),
      ],
    );
  }

  Widget _buildBody(BuildContext context) {
    final provider = context.watch<SearchProvider>();

    if (provider.loading) {
      return LoadingIndicator(message: AppStrings.searching);
    }

    if (provider.error != null) {
      return ErrorView(
        message: provider.error!,
        onRetry: () {
          if (provider.keyword.isNotEmpty) {
            provider.search(provider.keyword);
          }
        },
      );
    }

    if (provider.isEmpty) {
      return EmptyState(
        icon: Icons.search_off,
        title: AppStrings.noResults,
        subtitle: AppStrings.noResultsHint,
      );
    }

    if (!provider.hasResults) {
      return _buildSearchHistory(context, provider);
    }

    return Column(
      children: [
        // 结果统计
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            children: [
              Text(
                '${AppStrings.search}: ${provider.results.length}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const Spacer(),
              if (provider.selectedSourceUrls.isNotEmpty)
                ActionChip(
                  avatar: const Icon(Icons.filter_list, size: 16),
                  label: Text('${provider.selectedSourceUrls.length} ${AppStrings.sources}'),
                  onPressed: () => provider.clearSourceFilter(),
                ),
            ],
          ),
        ),
        // 结果列表
        Expanded(
          child: ListView.separated(
            itemCount: provider.results.length,
            separatorBuilder: (_, _) => const Divider(height: 1, indent: 88),
            itemBuilder: (context, index) {
              final result = provider.results[index];
              return _buildResultItem(context, result);
            },
          ),
        ),
      ],
    );
  }

  Widget _buildResultItem(BuildContext context, SearchResult result) {
    final book = result.book;
    return ListTile(
      leading: BookCover(
        coverUrl: book.coverUrl,
        width: 48,
        height: 64,
        borderRadius: 4,
      ),
      title: Text(
        book.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontWeight: FontWeight.w500),
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (book.author.isNotEmpty)
            Text(
              '${AppStrings.author}: ${book.author}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          Text(
            '${AppStrings.source}: ${result.sourceName}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
          ),
          if (book.intro != null && book.intro!.isNotEmpty)
            Text(
              book.intro!,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall,
            ),
        ],
      ),
      isThreeLine: true,
      onTap: () => _showBookDetail(context, result),
    );
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
                BookCover(coverUrl: book.coverUrl, width: 80, height: 110),
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
    context.read<BookshelfProvider>().addBook(book);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('${book.name} ${AppStrings.addedToBookshelf}')),
    );
  }

  /// 搜索历史页面（无结果时显示）
  Widget _buildSearchHistory(BuildContext context, SearchProvider provider) {
    if (provider.searchHistory.isEmpty) {
      return EmptyState(
        icon: Icons.search,
        title: AppStrings.searchBooks,
        subtitle: AppStrings.searchBooksHint,
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
                onPressed: () => provider.clearHistory(),
                icon: const Icon(Icons.delete_outline, size: 18),
                label: Text(AppStrings.clearHistory),
              ),
            ],
          ),
        ),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: provider.searchHistory.map((keyword) {
                return ActionChip(
                  label: Text(keyword),
                  onPressed: () {
                    _searchController.text = keyword;
                    provider.search(keyword);
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
