import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/models.dart';
import '../services/book_api.dart';
import '../widgets/empty_state.dart';
import '../widgets/error_view.dart';
import '../widgets/loading_indicator.dart';

/// RSS 收藏页面
///
/// 展示已收藏的 RSS 文章，按来源分组，支持取消收藏与打开原文。
class RssFavoritesScreen extends StatefulWidget {
  const RssFavoritesScreen({super.key});

  @override
  State<RssFavoritesScreen> createState() => _RssFavoritesScreenState();
}

class _RssFavoritesScreenState extends State<RssFavoritesScreen> {
  List<RssStar> _stars = [];
  Map<String, String> _sourceNames = {};
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final api = context.read<BookApi>();
      final stars = await api.getRssStars();
      final sources = await api.getRssSources();
      if (!mounted) return;
      setState(() {
        _stars = stars;
        _sourceNames = {
          for (final s in sources) s.sourceUrl: s.sourceName,
        };
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  /// 按来源分组
  Map<String, List<RssStar>> get _grouped {
    final map = <String, List<RssStar>>{};
    for (final star in _stars) {
      map.putIfAbsent(star.origin, () => []).add(star);
    }
    return map;
  }

  String _displayName(String origin) =>
      _sourceNames[origin] ?? (origin.isEmpty ? '未知来源' : origin);

  Future<void> _unstar(RssStar star) async {
    // 先从本地移除，提升响应速度
    setState(() => _stars.removeWhere((s) => s.link == star.link));
    final messenger = ScaffoldMessenger.of(context);
    try {
      await context.read<BookApi>().deleteRssStar(star.link);
      messenger.showSnackBar(
        const SnackBar(
          content: Text('已取消收藏'),
          duration: Duration(seconds: 1),
        ),
      );
    } catch (e) {
      // 失败时恢复
      setState(() => _stars.add(star));
      messenger.showSnackBar(SnackBar(content: Text('操作失败：$e')));
    }
  }

  Future<void> _openLink(String link) async {
    if (link.isEmpty) return;
    final uri = Uri.parse(link);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('RSS 收藏'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: '刷新',
            onPressed: _load,
          ),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const LoadingIndicator(message: '加载收藏...');
    }
    if (_error != null) {
      return ErrorView(message: _error!, onRetry: _load);
    }
    if (_stars.isEmpty) {
      return const EmptyState(
        icon: Icons.star_outline_rounded,
        title: '暂无收藏文章',
        subtitle: '浏览 RSS 文章时点亮星标即可收藏',
      );
    }

    final grouped = _grouped;
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          for (final entry in grouped.entries) ...[
            _buildGroupHeader(entry.key, entry.value.length),
            for (final star in entry.value) _buildStarTile(star),
            const SizedBox(height: 8),
          ],
        ],
      ),
    );
  }

  Widget _buildGroupHeader(String origin, int count) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 6),
      child: Row(
        children: [
          Container(
            width: 4,
            height: 16,
            decoration: BoxDecoration(
              color: colorScheme.secondary,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              _displayName(origin),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w700,
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(
              color: colorScheme.secondaryContainer,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(
              '$count',
              style: theme.textTheme.labelSmall?.copyWith(
                color: colorScheme.onSecondaryContainer,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStarTile(RssStar star) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => _openLink(star.link),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      star.title.isEmpty ? '（无标题）' : star.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (star.description != null &&
                        star.description!.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        star.description!,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                    if (star.pubDate != null && star.pubDate!.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Row(
                        children: [
                          Icon(Icons.schedule,
                              size: 14, color: colorScheme.outline),
                          const SizedBox(width: 4),
                          Text(
                            star.pubDate!,
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: colorScheme.outline,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 8),
              IconButton(
                icon: Icon(Icons.star_rounded, color: colorScheme.secondary),
                tooltip: '取消收藏',
                onPressed: () => _unstar(star),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
