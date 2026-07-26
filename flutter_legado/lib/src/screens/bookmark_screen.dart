import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../providers/bookmark_provider.dart';

/// 书签管理页面
class BookmarkScreen extends StatefulWidget {
  const BookmarkScreen({super.key});

  @override
  State<BookmarkScreen> createState() => _BookmarkScreenState();
}

class _BookmarkScreenState extends State<BookmarkScreen> {
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<BookmarkProvider>().loadAll();
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
      appBar: AppBar(
        title: const Text('书签'),
        actions: [
          IconButton(
            icon: const Icon(Icons.search),
            onPressed: () => _showSearchDialog(context),
          ),
        ],
      ),
      body: Consumer<BookmarkProvider>(
        builder: (context, provider, _) {
          if (provider.loading) {
            return const Center(child: CircularProgressIndicator());
          }
          if (provider.error != null) {
            return Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.error_outline, size: 48,
                      color: Theme.of(context).colorScheme.error),
                  const SizedBox(height: 16),
                  Text(provider.error!, textAlign: TextAlign.center),
                  const SizedBox(height: 16),
                  ElevatedButton(
                    onPressed: () => provider.loadAll(),
                    child: const Text('重试'),
                  ),
                ],
              ),
            );
          }
          if (provider.bookmarks.isEmpty) {
            return Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.bookmark_border, size: 64,
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
          return _buildBookmarkList(context, provider);
        },
      ),
    );
  }

  Widget _buildBookmarkList(BuildContext context, BookmarkProvider provider) {
    return ListView.builder(
      itemCount: provider.bookmarks.length,
      itemBuilder: (context, index) {
        final bookmark = provider.bookmarks[index];
        return _BookmarkTile(
          bookmark: bookmark,
          onTap: () => _navigateToChapter(context, bookmark),
          onDelete: () => _confirmDelete(context, provider, bookmark),
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

  void _confirmDelete(
      BuildContext context, BookmarkProvider provider, Bookmark bookmark) {
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
              provider.deleteBookmark(bookmark.id);
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
            context.read<BookmarkProvider>().search(value);
          },
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              setState(() => _searchQuery = '');
              context.read<BookmarkProvider>().loadAll();
            },
            child: const Text('清除'),
          ),
          TextButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              final query = _searchController.text;
              setState(() => _searchQuery = query);
              context.read<BookmarkProvider>().search(query);
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
    final time = DateTime.fromMillisecondsSinceEpoch(bookmark.time * 1000);
    final timeStr =
        '${time.year}-${time.month.toString().padLeft(2, '0')}-${time.day.toString().padLeft(2, '0')} '
        '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: InkWell(
        onTap: onTap,
        onLongPress: onDelete,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.bookmark, size: 16,
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
                  Icon(Icons.menu_book, size: 14,
                      color: theme.colorScheme.outline),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      bookmark.bookName,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.outline,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  Text(
                    '第 ${bookmark.chapterIndex + 1} 章',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.outline,
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
