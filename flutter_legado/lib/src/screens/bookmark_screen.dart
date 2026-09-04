import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import '../widgets/legado_app_bar.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;

import '../models/models.dart';
import '../providers/bookmark/bookmark_notifier.dart';

/// 书签管理页面
class BookmarkScreen extends ConsumerStatefulWidget {
  const BookmarkScreen({super.key});

  @override
  ConsumerState<BookmarkScreen> createState() => _BookmarkScreenState();
}

class _BookmarkScreenState extends ConsumerState<BookmarkScreen> {
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(bookmarkNotifierProvider.notifier).loadAll();
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: LegadoAppBar(
        title: const Text('书签'),
        actions: [
          IconButton(
            icon: const Icon(Symbols.search_rounded),
            onPressed: () => _showSearchDialog(context),
          ),
        ],
      ),
      body: _buildBody(ref.watch(bookmarkNotifierProvider)),
    );
  }

  Widget _buildBody(BookmarkState state) {
    final notifier = ref.read(bookmarkNotifierProvider.notifier);
    if (state.isLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (state.error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Symbols.error_rounded, size: 48,
                color: Theme.of(context).colorScheme.error),
            const SizedBox(height: 16),
            Text(state.error!, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: () => notifier.loadAll(),
              child: const Text('重试'),
            ),
          ],
        ),
      );
    }
    if (state.bookmarks.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Symbols.bookmark_border_rounded, size: 64,
                color: Theme.of(context).colorScheme.outline),
            const SizedBox(height: 16),
            Text(
              _searchQuery.isEmpty ? '暂无书签' : '未找到匹配的书签',
              style: Theme.of(context).textTheme.bodyLarge,
            ),
          ],
        ),
      );
    }
    return _buildBookmarkList(context, state);
  }

  Widget _buildBookmarkList(BuildContext context, BookmarkState state) {
    return ListView.builder(
      itemCount: state.bookmarks.length,
      itemBuilder: (context, index) {
        final bookmark = state.bookmarks[index];
        return _BookmarkTile(
          bookmark: bookmark,
          onTap: () => _navigateToChapter(context, bookmark),
          onDelete: () => _confirmDelete(context, bookmark),
        );
      },
    );
  }

  void _navigateToChapter(BuildContext context, Bookmark bookmark) {
    // 返回书签信息给调用方，由 reader_screen 处理跳转
    Navigator.of(context).pop({
      'bookName': bookmark.bookName,
      'chapterIndex': bookmark.chapterIndex,
      'chapterPos': bookmark.chapterPos,
    });
  }

  void _confirmDelete(BuildContext context, Bookmark bookmark) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除书签'),
        content: Text('确定删除「${bookmark.chapterName}」的书签吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              ref
                  .read(bookmarkNotifierProvider.notifier)
                  .deleteBookmark(bookmark.id);
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('书签已删除')),
              );
            },
            child: const Text('删除'),
          ),
        ],
      ),
    );
  }

  void _showSearchDialog(BuildContext context) {
    _searchController.text = _searchQuery;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('搜索书签'),
        content: TextField(
          controller: _searchController,
          decoration: const InputDecoration(
            hintText: '输入关键词搜索书签',
            border: OutlineInputBorder(),
          ),
          autofocus: true,
          onSubmitted: (value) {
            Navigator.of(ctx).pop();
            setState(() => _searchQuery = value);
            ref.read(bookmarkNotifierProvider.notifier).search(value);
          },
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              setState(() => _searchQuery = '');
              ref.read(bookmarkNotifierProvider.notifier).loadAll();
            },
            child: const Text('清除'),
          ),
          TextButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              final query = _searchController.text;
              setState(() => _searchQuery = query);
              ref.read(bookmarkNotifierProvider.notifier).search(query);
            },
            child: const Text('搜索'),
          ),
        ],
      ),
    );
  }
}

class _BookmarkTile extends StatelessWidget {
  final Bookmark bookmark;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  const _BookmarkTile({
    required this.bookmark,
    required this.onTap,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // [Task #54 | 2026-08-10] 缺陷⑤修复：Rust 侧 bookmark.time 已是
    // epoch 毫秒，删除多余的 ×1000 换算（原导致年份 58575） — Qoder
    final time = DateTime.fromMillisecondsSinceEpoch(bookmark.time);
    final timeStr =
        '${time.year}-${time.month.toString().padLeft(2, '0')}-${time.day.toString().padLeft(2, '0')} '
        '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';

    return Card(
      // [LAYOUT_PLAN P1] 卡片边距统一 horizontal16（全局标尺），纵向 4 保留密度
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: InkWell(
        onTap: onTap,
        onLongPress: onDelete,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          // [LAYOUT_PLAN P1] 卡内统一 16dp
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Symbols.bookmark_rounded, size: 16,
                      color: theme.colorScheme.primary),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      bookmark.chapterName,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  Text(timeStr, style: theme.textTheme.labelSmall),
                ],
              ),
              const SizedBox(height: 6),
              Row(
                children: [
                  Icon(Symbols.menu_book_rounded, size: 14,
                      color: theme.colorScheme.outline),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      bookmark.bookName,
                      style: theme.textTheme.bodySmall?.copyWith(
                        // [FIX 2026-09-04] 正文次要文字走 onSurfaceVariant（outline 仅用于边框/装饰图标）
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  Text(
                    '第 ${bookmark.chapterIndex + 1} 章',
                    style: theme.textTheme.labelSmall?.copyWith(
                      // [FIX 2026-09-04] 正文次要文字走 onSurfaceVariant（outline 仅用于边框/装饰图标）
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
              if (bookmark.bookText.isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(
                  bookmark.bookText,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
              if (bookmark.content.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(
                  '备注: ${bookmark.content}',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.secondary,
                    fontStyle: FontStyle.italic,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
