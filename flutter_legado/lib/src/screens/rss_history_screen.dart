import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;

import '../models/models.dart';
import '../providers/rss_history/rss_history_notifier.dart';
import '../widgets/empty_state.dart';
import '../widgets/error_view.dart';
import '../widgets/loading_indicator.dart';

/// RSS 历史页面
///
/// 展示已读 RSS 文章记录（按阅读时间降序），支持清空历史。
/// 对标安卓原版 RSS 历史入口（REFACTORING_REMAINING_PLAN §4.3 P1-2）。
class RssHistoryScreen extends ConsumerStatefulWidget {
  const RssHistoryScreen({super.key});

  @override
  ConsumerState<RssHistoryScreen> createState() => _RssHistoryScreenState();
}

class _RssHistoryScreenState extends ConsumerState<RssHistoryScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(rssHistoryNotifierProvider.notifier).load();
    });
  }

  Future<void> _confirmClear() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('清空历史'),
        content: const Text('确定要清空所有 RSS 阅读历史吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      await ref.read(rssHistoryNotifierProvider.notifier).clear();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final state = ref.watch(rssHistoryNotifierProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('RSS 历史'),
        actions: [
          IconButton(
            icon: const Icon(Icons.delete_sweep_outlined),
            tooltip: '清空历史',
            onPressed:
                (state.records.isEmpty || state.isClearing) ? null : _confirmClear,
          ),
        ],
      ),
      body: _buildBody(theme, state),
    );
  }

  Widget _buildBody(ThemeData theme, RssHistoryState state) {
    if (state.isLoading || state.isClearing) {
      return const LoadingIndicator();
    }
    if (state.error != null) {
      return ErrorView(
        message: state.error!,
        onRetry: () => ref.read(rssHistoryNotifierProvider.notifier).load(),
      );
    }
    if (state.records.isEmpty) {
      return const EmptyState(
        icon: Icons.history,
        title: '暂无阅读历史',
        subtitle: '阅读过的 RSS 文章会显示在这里',
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: state.records.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, index) =>
          _buildItem(theme, state.records[index]),
    );
  }

  Widget _buildItem(ThemeData theme, RssReadRecordRow record) {
    final colorScheme = theme.colorScheme;
    return ListTile(
      leading: Icon(
        Icons.article_outlined,
        color: colorScheme.onSurfaceVariant,
      ),
      title: Text(
        record.title.isEmpty ? '(无标题)' : record.title,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        '${_formatOrigin(record.origin)}  ·  ${_formatTime(record.readTime)}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodySmall?.copyWith(
          color: colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }

  /// 来源 URL 简化显示（仅保留主机名）
  String _formatOrigin(String origin) {
    final uri = Uri.tryParse(origin);
    return uri?.host.isNotEmpty == true ? uri!.host : origin;
  }

  /// 阅读时间格式化
  String _formatTime(int millis) {
    if (millis <= 0) return '';
    final dt = DateTime.fromMillisecondsSinceEpoch(millis);
    return '${dt.year}-${_pad(dt.month)}-${_pad(dt.day)} '
        '${_pad(dt.hour)}:${_pad(dt.minute)}';
  }

  /// 两位数补零
  String _pad(int v) => v.toString().padLeft(2, '0');
}
