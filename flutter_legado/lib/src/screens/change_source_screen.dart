import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;

import '../models/models.dart';
import '../providers/change_source/change_source_notifier.dart';
import '../widgets/error_view.dart';
import '../widgets/loading_indicator.dart';

/// 换源页面 — 搜索替代书源并切换
///
/// 通过 [ChangeSourceNotifier] 经 BookApi 调用 Rust 后端的换源匹配器
/// （`searchSource` / `switchSource`），在所有启用的书源中搜索同名书籍，
/// 按匹配度评分排序（Rust 侧完成），用户选择后切换书籍来源。
///
/// 架构说明（对齐 UI_RESTRUCTURE_PLAN.md §0.2）：本页面不直接调用 bridge/FFI，
/// 全部经 [ChangeSourceNotifier] → BookApi 委托 Rust。
class ChangeSourceScreen extends ConsumerStatefulWidget {
  /// 书籍对象（路由参数规范化：优先使用 Book 对象）
  final Book? book;

  /// 以下字段为向后兼容保留，当未传入 Book 对象时使用
  final String bookUrl;
  final String bookName;
  final String author;
  final String currentSourceUrl;

  const ChangeSourceScreen({
    super.key,
    this.book,
    this.bookUrl = '',
    this.bookName = '',
    this.author = '',
    this.currentSourceUrl = '',
  });

  /// 获取有效的 bookUrl
  String get effectiveBookUrl => book?.bookUrl ?? bookUrl;

  /// 获取有效的书名
  String get effectiveBookName => book?.name ?? bookName;

  /// 获取有效的作者
  String get effectiveAuthor => book?.author ?? author;

  /// 获取有效的当前书源地址
  String get effectiveCurrentSourceUrl => book?.origin ?? currentSourceUrl;

  @override
  ConsumerState<ChangeSourceScreen> createState() => _ChangeSourceScreenState();
}

class _ChangeSourceScreenState extends ConsumerState<ChangeSourceScreen> {
  @override
  void initState() {
    super.initState();
    // 进入页面自动搜索一次
    WidgetsBinding.instance.addPostFrameCallback((_) => _search());
  }

  /// 搜索可替换书源
  Future<void> _search() => ref
      .read(changeSourceNotifierProvider.notifier)
      .search(widget.effectiveBookName, widget.effectiveAuthor);

  /// 应用选中的书源
  Future<void> _applySource(SourceMatch result) async {
    // 已有切换进行中时不再重复触发
    if (ref.read(changeSourceNotifierProvider).isApplying) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('切换书源'),
        content: Text('确定要将本书切换到「${result.sourceName}」吗？\n'
            '切换后将重新获取目录与章节内容。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('切换'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    try {
      final newBookUrl = await ref
          .read(changeSourceNotifierProvider.notifier)
          .applySource(result, bookUrl: widget.effectiveBookUrl);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已切换到「${result.sourceName}」')),
      );
      Navigator.pop(context, newBookUrl);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('换源失败: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(changeSourceNotifierProvider);
    return Scaffold(
      appBar: AppBar(
        title: Text('换源 - ${widget.effectiveBookName}'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: '重新搜索',
            onPressed: state.isLoading ? null : _search,
          ),
        ],
      ),
      body: _buildBody(state),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: state.isLoading ? null : _search,
        icon: const Icon(Icons.search),
        label: const Text('搜索'),
      ),
    );
  }

  Widget _buildBody(ChangeSourceState state) {
    if (state.isLoading && state.results.isEmpty) {
      return const LoadingIndicator(message: '正在搜索可替换书源...');
    }
    if (state.error != null && state.results.isEmpty) {
      return ErrorView(message: state.error!, onRetry: _search);
    }
    if (state.results.isEmpty) {
      final colorScheme = Theme.of(context).colorScheme;
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.search_off, size: 64, color: colorScheme.onSurfaceVariant),
            const SizedBox(height: 8),
            Text('未找到可替换的书源',
                style: TextStyle(color: colorScheme.onSurfaceVariant, fontSize: 16)),
            const SizedBox(height: 4),
            Text('请确认已启用足够的书源后重试',
                style: TextStyle(color: colorScheme.onSurfaceVariant, fontSize: 12)),
          ],
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: _search,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (state.isLoading) const LinearProgressIndicator(minHeight: 2),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Text(
              '找到 ${state.results.length} 个匹配书源（按匹配度排序）',
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
          ),
          Expanded(
            child: ListView.separated(
              padding: const EdgeInsets.symmetric(vertical: 4),
              itemCount: state.results.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (context, index) =>
                  _buildResultTile(context, state.results[index], state),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildResultTile(
    BuildContext context,
    SourceMatch item,
    ChangeSourceState state,
  ) {
    final colorScheme = Theme.of(context).colorScheme;
    final isCurrent = item.sourceUrl == widget.effectiveCurrentSourceUrl;
    final isApplying = state.applyingUrl == item.sourceUrl;

    return ListTile(
      leading: CircleAvatar(
        backgroundColor: _scoreColor(item.score).withValues(alpha: 0.15),
        child: Text(
          item.score.toStringAsFixed(0),
          style: TextStyle(
            color: _scoreColor(item.score),
            fontWeight: FontWeight.bold,
            fontSize: 13,
          ),
        ),
      ),
      title: Row(
        children: [
          Flexible(
            child: Text(
              item.sourceName.isEmpty ? '未知书源' : item.sourceName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontWeight: FontWeight.w600,
                color: isCurrent ? colorScheme.primary : null,
              ),
            ),
          ),
          if (isCurrent) ...[
            const SizedBox(width: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
              decoration: BoxDecoration(
                color: colorScheme.primaryContainer,
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                '当前',
                style: TextStyle(
                  fontSize: 10,
                  color: colorScheme.onPrimaryContainer,
                ),
              ),
            ),
          ],
        ],
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (item.latestChapter != null && item.latestChapter!.isNotEmpty)
            Text(
              '最新：${item.latestChapter}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12),
            ),
          if (item.wordCount != null && item.wordCount!.isNotEmpty)
            Text(
              item.wordCount!,
              style: TextStyle(fontSize: 12, color: colorScheme.outline),
            ),
        ],
      ),
      trailing: isCurrent
          ? const Icon(Icons.check_circle, size: 20)
          : isApplying
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Icon(Icons.chevron_right, color: colorScheme.outline),
      enabled: !isCurrent && !state.isApplying,
      onTap: () => _applySource(item),
    );
  }

  /// 根据匹配度评分返回对应颜色
  Color _scoreColor(double score) {
    if (score >= 80) return Colors.green;
    if (score >= 50) return Colors.orange;
    return Theme.of(context).colorScheme.onSurfaceVariant;
  }
}
