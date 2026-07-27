import 'dart:convert';

import 'package:flutter/material.dart';

import '../bridge/rust_lib.dart' as bridge;
import '../widgets/error_view.dart';
import '../widgets/loading_indicator.dart';

/// 换源匹配结果（对应 Rust 侧 `SourceMatch`）
class SourceMatchItem {
  final String sourceUrl;
  final String sourceName;
  final String bookUrl;
  final String bookName;
  final String author;
  final String? latestChapter;
  final String? wordCount;
  final double score;

  const SourceMatchItem({
    required this.sourceUrl,
    required this.sourceName,
    required this.bookUrl,
    required this.bookName,
    required this.author,
    this.latestChapter,
    this.wordCount,
    required this.score,
  });

  /// 从 FFI 返回的 JSON 构造。
  ///
  /// Rust 侧 `SourceMatch` 使用 snake_case 字段：
  /// ```json
  /// {
  ///   "source_url": "...",
  ///   "source_name": "...",
  ///   "book_url": "...",
  ///   "book_name": "...",
  ///   "author": "...",
  ///   "latest_chapter": "...",
  ///   "word_count": "...",
  ///   "score": 87.5
  /// }
  /// ```
  factory SourceMatchItem.fromJson(Map<String, dynamic> json) {
    return SourceMatchItem(
      sourceUrl: json['source_url'] as String? ?? '',
      sourceName: json['source_name'] as String? ?? '',
      bookUrl: json['book_url'] as String? ?? '',
      bookName: json['book_name'] as String? ?? '',
      author: json['author'] as String? ?? '',
      latestChapter: json['latest_chapter'] as String?,
      wordCount: json['word_count'] as String?,
      score: (json['score'] as num?)?.toDouble() ?? 0.0,
    );
  }
}

/// 换源页面 — 搜索替代书源并切换
///
/// 通过 FFI 调用 Rust 后端的换源匹配器（`source_switch_search` /
/// `source_switch_apply`），在所有启用的书源中搜索同名书籍，
/// 按匹配度评分排序，用户选择后切换书籍来源。
class ChangeSourceScreen extends StatefulWidget {
  final String bookUrl;
  final String bookName;
  final String author;
  final String currentSourceUrl;

  const ChangeSourceScreen({
    super.key,
    required this.bookUrl,
    required this.bookName,
    required this.author,
    required this.currentSourceUrl,
  });

  @override
  State<ChangeSourceScreen> createState() => _ChangeSourceScreenState();
}

class _ChangeSourceScreenState extends State<ChangeSourceScreen> {
  List<SourceMatchItem> _results = [];
  bool _isSearching = false;
  String? _error;
  String? _applyingUrl;

  @override
  void initState() {
    super.initState();
    // 进入页面自动搜索一次
    WidgetsBinding.instance.addPostFrameCallback((_) => _search());
  }

  /// 搜索可替换书源
  Future<void> _search() async {
    if (_isSearching) return;
    setState(() {
      _isSearching = true;
      _error = null;
    });
    try {
      final jsonStr = await bridge.sourceSwitchSearch(
        bookName: widget.bookName,
        author: widget.author,
      );
      final decoded = jsonDecode(jsonStr);
      final matches = <SourceMatchItem>[];
      if (decoded is Map<String, dynamic>) {
        final list = decoded['matches'] as List? ?? [];
        for (final e in list) {
          if (e is Map<String, dynamic>) {
            matches.add(SourceMatchItem.fromJson(e));
          }
        }
      } else if (decoded is List) {
        // 兼容直接返回数组的情况
        for (final e in decoded) {
          if (e is Map<String, dynamic>) {
            matches.add(SourceMatchItem.fromJson(e));
          }
        }
      }
      // 按评分降序（Rust 侧已排序，这里兜底）
      matches.sort((a, b) => b.score.compareTo(a.score));
      if (!mounted) return;
      setState(() {
        _results = matches;
        _isSearching = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '搜索失败: $e';
        _isSearching = false;
      });
    }
  }

  /// 应用选中的书源
  Future<void> _applySource(SourceMatchItem result) async {
    if (_applyingUrl != null) return;

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

    setState(() => _applyingUrl = result.sourceUrl);
    try {
      final updatedJson = await bridge.sourceSwitchApply(
        bookUrl: widget.bookUrl,
        newSourceUrl: result.sourceUrl,
        newBookUrl: result.bookUrl,
      );
      // 解析更新后的书籍，取出新的 bookUrl 供上层刷新
      var newBookUrl = result.bookUrl;
      try {
        final decoded = jsonDecode(updatedJson);
        if (decoded is Map<String, dynamic>) {
          final url = decoded['bookUrl'] as String?;
          if (url != null && url.isNotEmpty) newBookUrl = url;
        }
      } catch (_) {
        // 解析失败时回退到候选项的 bookUrl
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已切换到「${result.sourceName}」')),
      );
      Navigator.pop(context, newBookUrl);
    } catch (e) {
      if (!mounted) return;
      setState(() => _applyingUrl = null);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('换源失败: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('换源 - ${widget.bookName}'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: '重新搜索',
            onPressed: _isSearching ? null : _search,
          ),
        ],
      ),
      body: _buildBody(),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _isSearching ? null : _search,
        icon: const Icon(Icons.search),
        label: const Text('搜索'),
      ),
    );
  }

  Widget _buildBody() {
    if (_isSearching && _results.isEmpty) {
      return const LoadingIndicator(message: '正在搜索可替换书源...');
    }
    if (_error != null && _results.isEmpty) {
      return ErrorView(message: _error!, onRetry: _search);
    }
    if (_results.isEmpty) {
      return const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.search_off, size: 64, color: Colors.grey),
            SizedBox(height: 8),
            Text('未找到可替换的书源',
                style: TextStyle(color: Colors.grey, fontSize: 16)),
            SizedBox(height: 4),
            Text('请确认已启用足够的书源后重试',
                style: TextStyle(color: Colors.grey, fontSize: 12)),
          ],
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: _search,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_isSearching) const LinearProgressIndicator(minHeight: 2),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Text(
              '找到 ${_results.length} 个匹配书源（按匹配度排序）',
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
          ),
          Expanded(
            child: ListView.separated(
              padding: const EdgeInsets.symmetric(vertical: 4),
              itemCount: _results.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (context, index) =>
                  _buildResultTile(context, _results[index]),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildResultTile(BuildContext context, SourceMatchItem item) {
    final colorScheme = Theme.of(context).colorScheme;
    final isCurrent = item.sourceUrl == widget.currentSourceUrl;
    final isApplying = _applyingUrl == item.sourceUrl;

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
      enabled: !isCurrent && _applyingUrl == null,
      onTap: () => _applySource(item),
    );
  }

  /// 根据匹配度评分返回对应颜色
  Color _scoreColor(double score) {
    if (score >= 80) return Colors.green;
    if (score >= 50) return Colors.orange;
    return Colors.grey;
  }
}
