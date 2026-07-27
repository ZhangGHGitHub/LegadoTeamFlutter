import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../providers/bookshelf_provider.dart';
import '../providers/reader_provider.dart';
import '../routes.dart';
import '../services/rust_api.dart';
import '../widgets/book_cover.dart';
import '../widgets/error_view.dart';
import '../widgets/loading_indicator.dart';

/// 书籍详情页面
class BookInfoScreen extends StatefulWidget {
  final String bookUrl;

  const BookInfoScreen({super.key, required this.bookUrl});

  @override
  State<BookInfoScreen> createState() => _BookInfoScreenState();
}

class _BookInfoScreenState extends State<BookInfoScreen> {
  late Future<_BookInfoData> _future;
  final TextEditingController _searchCtrl = TextEditingController();
  String _filter = '';
  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    _future = _loadData();
    _searchCtrl.addListener(() {
      setState(() => _filter = _searchCtrl.text.trim().toLowerCase());
    });
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<_BookInfoData> _loadData() async {
    final api = context.read<RustApi>();
    final book = await api.getBook(widget.bookUrl);
    final chapters = await api.getChapters(widget.bookUrl);
    return _BookInfoData(book: book, chapters: chapters);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('书籍详情'),
        actions: [
          IconButton(
            icon: const Icon(Icons.share),
            tooltip: '分享',
            onPressed: () {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('分享功能开发中')),
              );
            },
          ),
        ],
      ),
      body: FutureBuilder<_BookInfoData>(
        future: _future,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const LoadingIndicator(message: '加载书籍信息...');
          }
          if (snapshot.hasError) {
            return ErrorView(
              message: snapshot.error.toString(),
              onRetry: () => setState(() => _future = _loadData()),
            );
          }
          final data = snapshot.data!;
          final book = data.book;
          if (book == null) {
            return const ErrorView(message: '书籍不存在');
          }
          return _buildBody(context, book, data.chapters);
        },
      ),
      bottomNavigationBar: _buildBottomBar(),
    );
  }

  Widget _buildBody(BuildContext context, Book book, List<BookChapter> chapters) {
    final filteredChapters = _filter.isEmpty
        ? chapters
        : chapters
            .where((c) => c.title.toLowerCase().contains(_filter))
            .toList();

    return RefreshIndicator(
      onRefresh: () async => setState(() => _future = _loadData()),
      child: CustomScrollView(
        slivers: [
          // 书籍信息头
          SliverToBoxAdapter(child: _buildHeader(context, book)),
          // 简介
          SliverToBoxAdapter(child: _buildIntro(context, book)),
          // 章节搜索
          SliverToBoxAdapter(child: _buildChapterSearch(context)),
          // 章节列表头
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: Text(
                '章节列表（${chapters.length}）',
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
              ),
            ),
          ),
          // 章节列表
          if (filteredChapters.isEmpty)
            const SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.all(32),
                child: Center(child: Text('暂无匹配章节')),
              ),
            )
          else
            SliverList.builder(
              itemCount: filteredChapters.length,
              itemBuilder: (context, index) {
                final chapter = filteredChapters[index];
                final isCurrentRead = chapter.index == book.durChapterIndex;
                return ListTile(
                  title: Text(
                    chapter.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontWeight:
                          isCurrentRead ? FontWeight.bold : FontWeight.normal,
                      color: isCurrentRead
                          ? Theme.of(context).colorScheme.primary
                          : null,
                    ),
                  ),
                  subtitle: chapter.wordCount != null &&
                          chapter.wordCount!.isNotEmpty
                      ? Text('${chapter.wordCount} 字')
                      : null,
                  dense: true,
                  trailing: isCurrentRead
                      ? const Icon(Icons.play_circle, size: 20)
                      : null,
                  onTap: () => _openReader(context, book, chapter.index),
                  onLongPress: () =>
                      _showChapterMenu(context, book, chapter, index),
                );
              },
            ),
          const SliverToBoxAdapter(child: SizedBox(height: 80)),
        ],
      ),
    );
  }

  Widget _buildHeader(BuildContext context, Book book) {
    final colorScheme = Theme.of(context).colorScheme;
    final lastUpdate = book.latestChapterTime > 0
        ? DateTime.fromMillisecondsSinceEpoch(book.latestChapterTime * 1000)
        : null;

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          BookCover(
            coverUrl: book.customCoverUrl ?? book.coverUrl,
            width: 100,
            height: 140,
            borderRadius: 8,
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  book.name,
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 6),
                if (book.author.isNotEmpty)
                  Text(
                    book.author,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                        ),
                  ),
                const SizedBox(height: 4),
                Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  children: [
                    if (book.originName.isNotEmpty)
                      _buildInfoChip(context, book.originName, Icons.source),
                    if (book.totalChapterNum > 0)
                      _buildInfoChip(
                          context, '${book.totalChapterNum}章', Icons.list),
                    if (book.wordCount != null && book.wordCount!.isNotEmpty)
                      _buildInfoChip(context, book.wordCount!, Icons.text_fields),
                  ],
                ),
                if (lastUpdate != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    '最后更新：${_formatDate(lastUpdate)}',
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                        ),
                  ),
                ],
                if (book.latestChapterTitle != null &&
                    book.latestChapterTitle!.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    '最新：${book.latestChapterTitle}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.labelSmall,
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildInfoChip(BuildContext context, String label, IconData icon) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.secondaryContainer.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12),
          const SizedBox(width: 3),
          Text(label, style: Theme.of(context).textTheme.labelSmall),
        ],
      ),
    );
  }

  Widget _buildIntro(BuildContext context, Book book) {
    final intro = book.customIntro ?? book.intro;
    if (intro == null || intro.isEmpty) return const SizedBox.shrink();

    return _ExpandableText(text: intro);
  }

  Widget _buildChapterSearch(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: TextField(
        controller: _searchCtrl,
        decoration: InputDecoration(
          hintText: '搜索章节...',
          prefixIcon: const Icon(Icons.search, size: 20),
          suffixIcon: _filter.isNotEmpty
              ? IconButton(
                  icon: const Icon(Icons.clear, size: 18),
                  onPressed: () {
                    _searchCtrl.clear();
                  },
                )
              : null,
          isDense: true,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
          ),
        ),
      ),
    );
  }

  Widget _buildBottomBar() {
    return FutureBuilder<_BookInfoData>(
      future: _future,
      builder: (context, snapshot) {
        if (!snapshot.hasData) return const SizedBox.shrink();
        final book = snapshot.data!.book;
        if (book == null) return const SizedBox.shrink();
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => _addToBookshelf(context, book),
                    icon: const Icon(Icons.bookmark_add, size: 18),
                    label: const Text('加入书架'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _isLoading
                        ? null
                        : () async {
                            setState(() => _isLoading = true);
                            try {
                              final api = context.read<RustApi>();
                              final chapters = await api.refreshToc(
                                book.bookUrl,
                                book.origin,
                              );
                              if (!context.mounted) return;
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                    content:
                                        Text('目录已更新，共 ${chapters.length} 章')),
                              );
                              setState(() => _future = _loadData());
                            } catch (e) {
                              if (!context.mounted) return;
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(content: Text('更新失败: $e')),
                              );
                            } finally {
                              if (mounted) {
                                setState(() => _isLoading = false);
                              }
                            }
                          },
                    icon: const Icon(Icons.refresh, size: 18),
                    label: const Text('更新目录'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => _showChangeSourceDialog(book),
                    icon: const Icon(Icons.swap_horiz, size: 18),
                    label: const Text('换源'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  flex: 2,
                  child: FilledButton.icon(
                    onPressed: () => _openReader(
                        context, book, book.durChapterIndex),
                    icon: const Icon(Icons.play_arrow, size: 20),
                    label: Text(book.durChapterIndex > 0 ? '继续阅读' : '开始阅读'),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  // ===== 操作 =====

  void _openReader(BuildContext context, Book book, int chapterIndex) {
    final readerProvider = context.read<ReaderProvider>();
    final bookToRead = chapterIndex != book.durChapterIndex
        ? book.copyWith(durChapterIndex: chapterIndex)
        : book;
    readerProvider.openBook(bookToRead);
    Navigator.pushNamed(context, AppRoutes.reader);
  }

  /// 打开换源页面，换源成功后用新的 bookUrl 重新加载详情页
  Future<void> _showChangeSourceDialog(Book book) async {
    final newBookUrl = await Navigator.pushNamed<String>(
      context,
      AppRoutes.changeSource,
      arguments: {
        'bookUrl': book.bookUrl,
        'bookName': book.name,
        'author': book.author,
        'currentSourceUrl': book.origin,
      },
    );
    if (!mounted) return;
    // 换源成功后 bookUrl 会变化，需要用新 URL 替换当前详情页
    if (newBookUrl != null && newBookUrl.isNotEmpty) {
      Navigator.pushReplacementNamed(
        context,
        AppRoutes.bookInfo,
        arguments: newBookUrl,
      );
    }
  }

  void _addToBookshelf(BuildContext context, Book book) async {
    final provider = context.read<BookshelfProvider>();
    await provider.addBook(book);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('《${book.name}》已加入书架')),
    );
  }

  Future<void> _showChapterMenu(
    BuildContext context,
    Book book,
    BookChapter chapter,
    int index,
  ) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.flag),
              title: const Text('设为阅读起点'),
              onTap: () => Navigator.pop(ctx, 'start'),
            ),
            ListTile(
              leading: const Icon(Icons.play_arrow),
              title: const Text('从此章开始阅读'),
              onTap: () => Navigator.pop(ctx, 'read'),
            ),
          ],
        ),
      ),
    );
    if (action == null) return;
    if (!context.mounted) return;
    if (action == 'start' || action == 'read') {
      _openReader(context, book, chapter.index);
    }
  }

  String _formatDate(DateTime dt) {
    return '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}';
  }
}

/// 书籍信息加载结果
class _BookInfoData {
  final Book? book;
  final List<BookChapter> chapters;

  const _BookInfoData({required this.book, required this.chapters});
}

/// 可折叠文字组件
class _ExpandableText extends StatefulWidget {
  final String text;

  const _ExpandableText({required this.text});

  @override
  State<_ExpandableText> createState() => _ExpandableTextState();
}

class _ExpandableTextState extends State<_ExpandableText> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '简介',
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
          ),
          const SizedBox(height: 4),
          AnimatedCrossFade(
            firstChild: Text(
              widget.text,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            secondChild: Text(
              widget.text,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            crossFadeState:
                _expanded ? CrossFadeState.showSecond : CrossFadeState.showFirst,
            duration: const Duration(milliseconds: 200),
          ),
          if (widget.text.length > 100)
            GestureDetector(
              onTap: () => setState(() => _expanded = !_expanded),
              child: Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  _expanded ? '收起' : '展开全部',
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.primary,
                    fontSize: 13,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
