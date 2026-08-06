import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' hide Provider, ChangeNotifierProvider;

import '../l10n/app_strings.dart';
import '../models/models.dart';
import '../providers/providers.dart';
import '../providers/reader/reader_notifier.dart';
import '../widgets/empty_state.dart';

/// 单条正文搜索结果
class _ContentMatch {
  final int chapterIndex;
  final String chapterTitle;
  final String snippet;

  const _ContentMatch({
    required this.chapterIndex,
    required this.chapterTitle,
    required this.snippet,
  });
}

/// 正文搜索页面
///
/// 在指定书籍的全部章节正文中搜索关键词，支持高亮、搜索历史，
/// 点击结果可跳转阅读器对应章节。
class SearchContentScreen extends ConsumerStatefulWidget {
  /// 书籍对象（路由参数规范化：优先使用 Book 对象）
  final Book? book;

  /// 书籍 URL（向后兼容）
  final String bookUrl;

  /// 书名（向后兼容）
  final String bookName;

  // [UI-fix v2.0.2 | 2026-08-06] 初始查询词（阅读器长按选中文本传入，
  // 对标原版 searchContentQuery 预填 + 自动搜索） — Qoder
  final String? initialQuery;

  const SearchContentScreen({
    super.key,
    this.book,
    this.bookUrl = '',
    this.bookName = '',
    this.initialQuery,
  });

  /// 获取有效的 bookUrl
  String get effectiveBookUrl => book?.bookUrl ?? bookUrl;

  /// 获取有效的书名
  String get effectiveBookName => book?.name ?? bookName;

  @override
  ConsumerState<SearchContentScreen> createState() => _SearchContentScreenState();
}

class _SearchContentScreenState extends ConsumerState<SearchContentScreen> {
  final TextEditingController _controller = TextEditingController();
  final FocusNode _focusNode = FocusNode();

  List<_ContentMatch> _results = [];
  List<String> _history = [];
  bool _searching = false;
  String _query = '';
  int _scannedChapters = 0;
  int _totalChapters = 0;

  /// 搜索代号，用于丢弃过期搜索
  int _generation = 0;

  static const _maxResults = 200;
  static const _snippetRadius = 30;

  @override
  void initState() {
    super.initState();
    _loadHistory();
    // 初始查询词：预填输入框并在首帧后自动触发搜索
    final q = widget.initialQuery;
    if (q != null && q.trim().isNotEmpty) {
      _controller.text = q;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_search(q));
      });
    }
  }

  @override
  void dispose() {
    _generation++; // 使所有进行中的搜索失效
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  Future<void> _loadHistory() async {
    try {
      final api = ref.read(bookApiProvider);
      final list = await api.getSearchHistory(limit: 20);
      if (!mounted) return;
      setState(() => _history = list.map((e) => e.word).toList());
    } catch (_) {
      // 历史加载失败不影响搜索
    }
  }

  Future<void> _search(String raw) async {
    final query = raw.trim();
    if (query.isEmpty) return;

    final api = ref.read(bookApiProvider);
    final gen = ++_generation;

    setState(() {
      _query = query;
      _searching = true;
      _results = [];
      _scannedChapters = 0;
      _totalChapters = 0;
    });
    _focusNode.unfocus();

    // 记录搜索历史
    api.addSearchKeyword(query, widget.effectiveBookName).catchError((_) {});

    try {
      final chapters = await api.getChapters(widget.effectiveBookUrl);
      if (gen != _generation || !mounted) return;
      setState(() => _totalChapters = chapters.length);

      final lowerQuery = query.toLowerCase();
      for (var i = 0; i < chapters.length; i++) {
        if (gen != _generation) return; // 已被新搜索/退出取消
        final chapter = chapters[i];
        try {
          // 内容搜索使用不应用替换规则的正文（与 Android 搜索默认对齐），
          // 避免被替换/删除的词搜不到
          final content =
              await api.getChapterContentRaw(widget.effectiveBookUrl, chapter.index);
          if (gen != _generation) return;

          final lowerContent = content.toLowerCase();
          var from = 0;
          var found = lowerContent.indexOf(lowerQuery, from);
          while (found != -1 && _results.length < _maxResults) {
            final start = found > _snippetRadius ? found - _snippetRadius : 0;
            var end = found + query.length + _snippetRadius;
            if (end > content.length) end = content.length;
            var snippet = content.substring(start, end).replaceAll('\n', ' ');
            if (start > 0) snippet = '…$snippet';
            if (end < content.length) snippet = '$snippet…';
            _results.add(_ContentMatch(
              chapterIndex: chapter.index,
              chapterTitle: chapter.title,
              snippet: snippet,
            ));
            from = found + query.length;
            found = lowerContent.indexOf(lowerQuery, from);
          }
        } catch (_) {
          // 单章获取失败，跳过
        }
        if (gen != _generation || !mounted) return;
        setState(() => _scannedChapters = i + 1);
        if (_results.length >= _maxResults) break;
      }
    } catch (_) {
      // 目录加载失败
    } finally {
      if (gen == _generation && mounted) {
        setState(() => _searching = false);
      }
    }
  }

  void _cancelSearch() {
    _generation++;
    if (mounted) setState(() => _searching = false);
  }

  void _jumpToResult(_ContentMatch match) {
    final container = ProviderScope.containerOf(context);
    container.read(readerNotifierProvider.notifier).goToChapter(match.chapterIndex);
    Navigator.of(context).pop();
  }

  /// 构造带高亮的富文本
  InlineSpan _highlight(String text, String query) {
    if (query.isEmpty) return TextSpan(text: text);
    final lower = text.toLowerCase();
    final lowerQuery = query.toLowerCase();
    final spans = <TextSpan>[];
    var from = 0;
    var found = lower.indexOf(lowerQuery, from);
    final highlightStyle = TextStyle(
      color: Theme.of(context).colorScheme.primary,
      fontWeight: FontWeight.bold,
      backgroundColor: Theme.of(context).colorScheme.primaryContainer.withValues(alpha: 0.6),
    );
    while (found != -1) {
      if (found > from) spans.add(TextSpan(text: text.substring(from, found)));
      spans.add(TextSpan(text: text.substring(found, found + query.length), style: highlightStyle));
      from = found + query.length;
      found = lower.indexOf(lowerQuery, from);
    }
    if (from < text.length) spans.add(TextSpan(text: text.substring(from)));
    return TextSpan(children: spans);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('搜索正文', style: Theme.of(context).textTheme.titleMedium),
        actions: [
          if (_searching)
            IconButton(icon: const Icon(Icons.close), onPressed: _cancelSearch),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(56),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: TextField(
              controller: _controller,
              focusNode: _focusNode,
              autofocus: true,
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                isDense: true,
                hintText: '在《${widget.effectiveBookName}》中搜索...',
                prefixIcon: const Icon(Icons.search, size: 20),
                suffixIcon: _controller.text.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.clear, size: 18),
                        onPressed: () {
                          _controller.clear();
                          setState(() {
                            _query = '';
                            _results = [];
                          });
                        },
                      ),
                border: const OutlineInputBorder(),
              ),
              onChanged: (_) => setState(() {}),
              onSubmitted: _search,
            ),
          ),
        ),
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    // 未搜索时展示搜索历史
    if (_query.isEmpty && !_searching) {
      return _buildHistory();
    }
    if (_searching && _results.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 16),
            Text(_totalChapters == 0
                ? AppStrings.searching
                : '扫描章节 $_scannedChapters / $_totalChapters ...'),
          ],
        ),
      );
    }
    if (_results.isEmpty) {
      return EmptyState(
        icon: Icons.search_off,
        title: AppStrings.noResults,
        subtitle: '未找到「$_query」相关内容',
      );
    }
    return Column(
      children: [
        if (_searching)
          LinearProgressIndicator(
            value: _totalChapters == 0 ? null : _scannedChapters / _totalChapters,
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Row(
            children: [
              Text('共 ${_results.length} 处匹配',
                  style: Theme.of(context).textTheme.labelMedium),
              if (_results.length >= _maxResults)
                Text('（已截断）',
                    style: Theme.of(context).textTheme.labelSmall),
            ],
          ),
        ),
        Expanded(
          child: ListView.builder(
            itemCount: _results.length,
            itemBuilder: (context, i) => _buildResultTile(_results[i]),
          ),
        ),
      ],
    );
  }

  Widget _buildResultTile(_ContentMatch match) {
    return ListTile(
      title: Text(
        match.chapterTitle,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontWeight: FontWeight.w600),
      ),
      subtitle: Text.rich(
        _highlight(match.snippet, _query),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: const Icon(Icons.chevron_right, size: 18),
      onTap: () => _jumpToResult(match),
    );
  }

  Widget _buildHistory() {
    if (_history.isEmpty) {
      return EmptyState(
        icon: Icons.history,
        title: AppStrings.searchHistory,
        subtitle: '输入关键词开始搜索正文',
      );
    }
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Row(
          children: [
            Text(AppStrings.searchHistory,
                style: Theme.of(context).textTheme.titleSmall),
            const Spacer(),
            TextButton(
              onPressed: _clearHistory,
              child: Text(AppStrings.clearHistory),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final word in _history)
              ActionChip(
                avatar: const Icon(Icons.history, size: 16),
                label: Text(word),
                onPressed: () {
                  _controller.text = word;
                  _search(word);
                },
              ),
          ],
        ),
      ],
    );
  }

  Future<void> _clearHistory() async {
    try {
      final api = ref.read(bookApiProvider);
      await api.clearSearchHistory();
      if (mounted) setState(() => _history = []);
    } catch (_) {
      // 忽略
    }
  }
}
