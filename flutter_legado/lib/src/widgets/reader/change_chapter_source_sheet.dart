import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;

import '../../models/book_chapter.dart';
import '../../models/source_match.dart';
import '../../providers/providers.dart';
import '../../providers/reader/reader_notifier.dart';
import '../../services/book_api.dart';
import '../../utils/error_message.dart';

/// 单章换源（对标原版 `ChangeChapterSourceDialog`）
///
/// 流程：searchSource → 选书 → refreshToc → 选章 → fetch + getCachedChapter
/// → saveChapterContent（写入当前书当前章）→ 刷新阅读器正文。
/// 不切换整书书源（与 `ChangeSourceScreen` 互斥）。
///
/// 设计：系统底栏 Sheet + 二级列表导航，轻量无卡片（Apple UI）。
Future<void> showChangeChapterSourceSheet(
  BuildContext context, {
  required String bookUrl,
  required String bookName,
  required String author,
  required int chapterIndex,
  required String chapterTitle,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (ctx) => _ChangeChapterSourceSheet(
      bookUrl: bookUrl,
      bookName: bookName,
      author: author,
      chapterIndex: chapterIndex,
      chapterTitle: chapterTitle,
    ),
  );
}

class _ChangeChapterSourceSheet extends ConsumerStatefulWidget {
  final String bookUrl;
  final String bookName;
  final String author;
  final int chapterIndex;
  final String chapterTitle;

  const _ChangeChapterSourceSheet({
    required this.bookUrl,
    required this.bookName,
    required this.author,
    required this.chapterIndex,
    required this.chapterTitle,
  });

  @override
  ConsumerState<_ChangeChapterSourceSheet> createState() =>
      _ChangeChapterSourceSheetState();
}

class _ChangeChapterSourceSheetState
    extends ConsumerState<_ChangeChapterSourceSheet> {
  bool _loading = true;
  String? _error;
  List<SourceMatch> _matches = const [];
  String _filter = '';

  SourceMatch? _selected;
  List<BookChapter> _toc = const [];
  bool _tocLoading = false;
  String? _tocError;
  bool _applying = false;

  BookApi get _api => ref.read(bookApiProvider);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _search());
  }

  Future<void> _search() async {
    setState(() {
      _loading = true;
      _error = null;
      _selected = null;
      _toc = const [];
    });
    try {
      final raw = await _api.searchSource(widget.bookName, widget.author);
      final matches = raw
          .map((e) => SourceMatch.fromJson(Map<String, dynamic>.from(e)))
          .where((m) => m.bookUrl.isNotEmpty && m.sourceUrl.isNotEmpty)
          .toList();
      if (!mounted) return;
      setState(() {
        _matches = matches;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = errorMessage(e);
        _loading = false;
      });
    }
  }

  List<SourceMatch> get _filtered {
    final q = _filter.trim().toLowerCase();
    if (q.isEmpty) return _matches;
    return _matches
        .where(
          (m) =>
              m.sourceName.toLowerCase().contains(q) ||
              m.bookName.toLowerCase().contains(q) ||
              m.latestChapter?.toLowerCase().contains(q) == true,
        )
        .toList();
  }

  Future<void> _openToc(SourceMatch match) async {
    setState(() {
      _selected = match;
      _tocLoading = true;
      _tocError = null;
      _toc = const [];
    });
    try {
      final toc = await _api.refreshToc(match.bookUrl, match.sourceUrl);
      if (!mounted) return;
      setState(() {
        _toc = toc;
        _tocLoading = false;
      });
      // 滚到近似当前章（标题优先，否则索引）
      final target = _matchChapterIndex(toc);
      if (target >= 0 && toc.isNotEmpty) {
        // 视觉定位交给 ListView；此处仅记录
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _tocError = e.toString();
        _tocLoading = false;
      });
    }
  }

  int _matchChapterIndex(List<BookChapter> toc) {
    if (toc.isEmpty) return -1;
    final title = widget.chapterTitle.trim();
    if (title.isNotEmpty) {
      final exact = toc.indexWhere((c) => c.title.trim() == title);
      if (exact >= 0) return exact;
      final soft = toc.indexWhere((c) => c.title.contains(title) || title.contains(c.title));
      if (soft >= 0) return soft;
    }
    final idx = widget.chapterIndex;
    if (idx >= 0 && idx < toc.length) return idx;
    return 0;
  }

  Future<void> _applyChapter(BookChapter chapter) async {
    final match = _selected;
    if (match == null || _applying) return;
    setState(() => _applying = true);
    try {
      await _api.fetchChapterContent(
        match.bookUrl,
        chapter.url,
        match.sourceUrl,
      );
      // 取候选章原始缓存（fetch 写入 raw），再落到当前书当前章
      var raw = await _api.getCachedChapter(match.bookUrl, chapter.index);
      if (raw.trim().isEmpty) {
        // 兜底：用已净化正文（仍优于无法换章）
        raw = await _api.fetchChapterContent(
          match.bookUrl,
          chapter.url,
          match.sourceUrl,
        );
      }
      if (raw.trim().isEmpty) {
        throw StateError('未获取到章节正文');
      }
      await _api.saveChapterContent(
        bookUrl: widget.bookUrl,
        chapterIndex: widget.chapterIndex,
        title: widget.chapterTitle,
        content: raw,
      );
      if (!mounted) return;
      await ref.read(readerNotifierProvider.notifier).reloadChapterContent();
      if (!mounted) return;
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已替换本章正文（${match.sourceName}）')),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _applying = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('单章换源失败：$e')),
      );
    }
  }

  void _backToSources() {
    setState(() {
      _selected = null;
      _toc = const [];
      _tocError = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final height = MediaQuery.sizeOf(context).height * 0.88;
    return SizedBox(
      height: height,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 12, 8),
            child: Row(
              children: [
                if (_selected != null)
                  IconButton(
                    tooltip: '返回书源列表',
                    onPressed: _applying ? null : _backToSources,
                    icon: const Icon(Icons.arrow_back_ios_new, size: 18),
                  ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _selected == null ? '单章换源' : '选择章节',
                        style: Theme.of(context).textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        _selected == null
                            ? widget.chapterTitle
                            : _selected!.sourceName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: '刷新',
                  onPressed: (_loading || _applying)
                      ? null
                      : () {
                          if (_selected != null) {
                            _openToc(_selected!);
                          } else {
                            _search();
                          }
                        },
                  icon: const Icon(Icons.refresh),
                ),
              ],
            ),
          ),
          if (_selected == null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: TextField(
                onChanged: (v) => setState(() => _filter = v),
                decoration: InputDecoration(
                  hintText: '筛选书源 / 书名',
                  isDense: true,
                  prefixIcon: const Icon(Icons.search, size: 20),
                  filled: true,
                  fillColor: scheme.surfaceContainerHighest.withValues(alpha: 0.45),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
            ),
          Expanded(child: _buildBody(scheme)),
          if (_applying)
            const LinearProgressIndicator(minHeight: 2),
        ],
      ),
    );
  }

  Widget _buildBody(ColorScheme scheme) {
    if (_selected != null) return _buildToc(scheme);
    if (_loading) {
      return const Center(child: CircularProgressIndicator.adaptive());
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(_error!, textAlign: TextAlign.center),
              const SizedBox(height: 12),
              TextButton(onPressed: _search, child: const Text('重试')),
            ],
          ),
        ),
      );
    }
    final list = _filtered;
    if (list.isEmpty) {
      return Center(
        child: Text(
          '没有可用书源',
          style: TextStyle(color: scheme.onSurfaceVariant),
        ),
      );
    }
    return ListView.separated(
      itemCount: list.length,
      separatorBuilder: (_, _) => Divider(
        height: 1,
        indent: 16,
        endIndent: 16,
        color: scheme.outlineVariant.withValues(alpha: 0.5),
      ),
      itemBuilder: (context, i) {
        final m = list[i];
        return ListTile(
          title: Text(m.sourceName.isEmpty ? m.sourceUrl : m.sourceName),
          subtitle: Text(
            [
              if (m.latestChapter != null && m.latestChapter!.isNotEmpty)
                m.latestChapter!,
              '匹配 ${m.score.toStringAsFixed(0)}',
            ].join(' · '),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => _openToc(m),
        );
      },
    );
  }

  Widget _buildToc(ColorScheme scheme) {
    if (_tocLoading) {
      return const Center(child: CircularProgressIndicator.adaptive());
    }
    if (_tocError != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(_tocError!, textAlign: TextAlign.center),
              const SizedBox(height: 12),
              TextButton(
                onPressed: () => _openToc(_selected!),
                child: const Text('重试'),
              ),
            ],
          ),
        ),
      );
    }
    if (_toc.isEmpty) {
      return Center(
        child: Text('目录为空', style: TextStyle(color: scheme.onSurfaceVariant)),
      );
    }
    final highlight = _matchChapterIndex(_toc);
    return ListView.builder(
      itemCount: _toc.length,
      itemBuilder: (context, i) {
        final ch = _toc[i];
        if (ch.isVolume) {
          return Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Text(
              ch.title,
              style: Theme.of(context).textTheme.labelLarge?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
            ),
          );
        }
        final selected = i == highlight;
        return ListTile(
          selected: selected,
          title: Text(ch.title),
          trailing: selected
              ? Icon(Icons.my_location, size: 18, color: scheme.primary)
              : null,
          onTap: _applying ? null : () => _applyChapter(ch),
        );
      },
    );
  }
}
