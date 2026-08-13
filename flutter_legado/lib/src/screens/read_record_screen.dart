import 'package:flutter/material.dart';
import '../widgets/legado_app_bar.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;

import '../models/models.dart';
import '../providers/providers.dart';
import '../providers/read_record/read_record_notifier.dart';
import '../providers/reader/reader_notifier.dart';
import '../routes.dart';
import '../utils/book_open_utils.dart';
import '../widgets/empty_state.dart';
import '../widgets/error_view.dart';
import '../widgets/loading_indicator.dart';

/// 阅读记录页（对齐原版 `ReadRecordActivity`）
///
/// 功能：总时长、可搜索书单、按书名/时长/最后阅读排序、
/// 启用记录开关、清空单本/全部；点击进阅读或搜索。
/// UI 仅渲染与交互；数据经 [ReadRecordNotifier] → BookApi。
/// — Auto + UI
class ReadRecordScreen extends ConsumerStatefulWidget {
  const ReadRecordScreen({super.key});

  @override
  ConsumerState<ReadRecordScreen> createState() => _ReadRecordScreenState();
}

class _ReadRecordScreenState extends ConsumerState<ReadRecordScreen> {
  final _searchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(readRecordNotifierProvider.notifier).load();
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  String _formatDate(int ms) {
    if (ms <= 0) return '';
    final dt = DateTime.fromMillisecondsSinceEpoch(ms);
    String two(int v) => v.toString().padLeft(2, '0');
    return '${dt.year}-${two(dt.month)}-${two(dt.day)}';
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(readRecordNotifierProvider);
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: LegadoAppBar(
        title: TextField(
          controller: _searchController,
          textAlignVertical: TextAlignVertical.center,
          decoration: InputDecoration(
            isDense: true,
            hintText: '搜索',
            border: InputBorder.none,
            hintStyle: TextStyle(
              color: colorScheme.onSurface.withValues(alpha: 0.45),
            ),
          ),
          style: Theme.of(context).textTheme.titleMedium,
          onChanged: (q) =>
              ref.read(readRecordNotifierProvider.notifier).setSearchQuery(q),
        ),
        actions: [
          PopupMenuButton<String>(
            tooltip: '排序与设置',
            onSelected: _onMenuSelected,
            itemBuilder: (_) => [
              CheckedPopupMenuItem(
                value: 'sort_name',
                checked: state.sortMode == ReadRecordSortMode.name,
                child: const Text('按书名排序'),
              ),
              CheckedPopupMenuItem(
                value: 'sort_read_long',
                checked: state.sortMode == ReadRecordSortMode.readTime,
                child: const Text('按阅读时长'),
              ),
              CheckedPopupMenuItem(
                value: 'sort_last_read',
                checked: state.sortMode == ReadRecordSortMode.lastRead,
                child: const Text('按最后阅读'),
              ),
              const PopupMenuDivider(),
              CheckedPopupMenuItem(
                value: 'enable_record',
                checked: state.enableRecord,
                child: const Text('启用阅读记录'),
              ),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          _buildTotalHeader(context, state),
          const Divider(height: 1),
          Expanded(child: _buildBody(context, state)),
        ],
      ),
    );
  }

  Widget _buildTotalHeader(BuildContext context, ReadRecordState state) {
    final colorScheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '全部阅读时长',
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        color: colorScheme.onSurface,
                      ),
                ),
                const SizedBox(height: 4),
                Text(
                  formatDuring(state.totalReadTimeMs),
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                ),
              ],
            ),
          ),
          TextButton(
            onPressed: state.records.isEmpty && state.totalReadTimeMs == 0
                ? null
                : () => _confirmClearAll(context),
            child: const Text('清空'),
          ),
        ],
      ),
    );
  }

  Widget _buildBody(BuildContext context, ReadRecordState state) {
    if (state.isLoading && state.records.isEmpty) {
      return const LoadingIndicator(message: '加载阅读记录...');
    }
    if (state.error != null && state.records.isEmpty) {
      return ErrorView(
        message: state.error!,
        onRetry: () => ref.read(readRecordNotifierProvider.notifier).load(),
      );
    }
    if (state.records.isEmpty) {
      return EmptyState(
        icon: Icons.history,
        title: state.searchQuery.isEmpty ? '暂无阅读记录' : '未找到匹配的记录',
      );
    }
    return RefreshIndicator(
      onRefresh: () => ref.read(readRecordNotifierProvider.notifier).load(),
      child: ListView.separated(
        itemCount: state.records.length,
        separatorBuilder: (_, _) => const Divider(height: 1, indent: 16),
        itemBuilder: (context, index) {
          final item = state.records[index];
          return _ReadRecordTile(
            item: item,
            lastReadText: _formatDate(item.lastRead),
            durationText: formatDuring(item.readTime),
            onTap: () => _openRecord(context, item),
            onClear: () => _confirmDelete(context, item),
          );
        },
      ),
    );
  }

  Future<void> _onMenuSelected(String value) async {
    final notifier = ref.read(readRecordNotifierProvider.notifier);
    switch (value) {
      case 'sort_name':
        await notifier.setSortMode(ReadRecordSortMode.name);
      case 'sort_read_long':
        await notifier.setSortMode(ReadRecordSortMode.readTime);
      case 'sort_last_read':
        await notifier.setSortMode(ReadRecordSortMode.lastRead);
      case 'enable_record':
        await notifier.toggleEnableRecord();
    }
  }

  Future<void> _openRecord(BuildContext context, ReadRecordShow item) async {
    final notifier = ref.read(readRecordNotifierProvider.notifier);
    final book = await notifier.findBookByName(item.bookName);
    if (!context.mounted) return;
    if (book == null) {
      // 对齐原版：书架无书 → 带书名打开搜索
      await Navigator.pushNamed(
        context,
        AppRoutes.search,
        arguments: item.bookName,
      );
      return;
    }
    await _openBook(context, book);
  }

  /// 对齐原版 startActivityForBook
  Future<void> _openBook(BuildContext context, Book book) async {
    if (book.durChapterIndex <= 0 && book.durChapterPos <= 0) {
      await Navigator.pushNamed(context, AppRoutes.bookInfo, arguments: book);
      return;
    }
    var typeBits = BookOpenUtils.typeBitsOf(book);
    if (BookOpenUtils.isOnlineBook(book)) {
      try {
        final sources = await ref.read(bookApiProvider).getBookSources();
        String norm(String u) => u.trim().replaceAll(RegExp(r'/+$'), '');
        final o = norm(book.origin);
        for (final s in sources) {
          if (norm(s.bookSourceUrl) == o || s.bookSourceUrl == book.origin) {
            typeBits = BookOpenUtils.resolveTypeBits(typeBits, s);
            break;
          }
        }
      } catch (_) {}
    }
    if (!context.mounted) return;
    final bookToOpen =
        typeBits != 0 ? book.copyWith(bookType: typeBits) : book;
    final route = BookOpenUtils.routeForTypeBits(typeBits);
    if (BookOpenUtils.needsReaderNotifier(route)) {
      ref.read(readerNotifierProvider.notifier).openBook(bookToOpen);
      await Navigator.pushNamed(context, route);
      return;
    }
    await Navigator.pushNamed(
      context,
      route,
      arguments: BookOpenUtils.argumentsForRoute(route, bookToOpen),
    );
  }

  Future<void> _confirmDelete(
    BuildContext context,
    ReadRecordShow item,
  ) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除'),
        content: Text('确定删除「${item.bookName}」吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    if (ok == true && context.mounted) {
      await ref
          .read(readRecordNotifierProvider.notifier)
          .deleteByName(item.bookName);
    }
  }

  Future<void> _confirmClearAll(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除'),
        content: const Text('确定删除全部阅读记录吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    if (ok == true && context.mounted) {
      await ref.read(readRecordNotifierProvider.notifier).clearAll();
    }
  }
}

/// 时长格式化（对齐原版 formatDuring，单位毫秒）
String formatDuring(int mss) {
  if (mss <= 0) return '0秒';
  final days = mss ~/ (1000 * 60 * 60 * 24);
  final hours = (mss % (1000 * 60 * 60 * 24)) ~/ (1000 * 60 * 60);
  final minutes = (mss % (1000 * 60 * 60)) ~/ (1000 * 60);
  final seconds = (mss % (1000 * 60)) ~/ 1000;
  final buf = StringBuffer();
  if (days > 0) buf.write('$days天');
  if (hours > 0) buf.write('$hours小时');
  if (minutes > 0) buf.write('$minutes分钟');
  if (seconds > 0) buf.write('$seconds秒');
  final time = buf.toString();
  return time.isEmpty ? '0秒' : time;
}

class _ReadRecordTile extends StatelessWidget {
  final ReadRecordShow item;
  final String durationText;
  final String lastReadText;
  final VoidCallback onTap;
  final VoidCallback onClear;

  const _ReadRecordTile({
    required this.item,
    required this.durationText,
    required this.lastReadText,
    required this.onTap,
    required this.onClear,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final secondary = colorScheme.onSurfaceVariant;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.bookName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '阅读时长：$durationText',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: secondary,
                        ),
                  ),
                  if (lastReadText.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      '最后阅读：$lastReadText',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: secondary,
                          ),
                    ),
                  ],
                ],
              ),
            ),
            TextButton(
              onPressed: onClear,
              child: const Text('清空'),
            ),
          ],
        ),
      ),
    );
  }
}
