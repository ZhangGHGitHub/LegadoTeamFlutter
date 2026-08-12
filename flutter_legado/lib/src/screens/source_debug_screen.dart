import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' hide Provider, ChangeNotifierProvider;

import '../models/models.dart';
import '../providers/providers.dart';

/// 书源调试页面
///
/// 输入书源 URL 和搜索关键词，调用 bridge 的 webbookSearch API，
/// 实时显示调试日志输出，支持按日志级别过滤。
class SourceDebugScreen extends ConsumerStatefulWidget {
  /// 可选：从外部传入书源 URL 预填
  final String? sourceUrl;

  const SourceDebugScreen({super.key, this.sourceUrl});

  @override
  ConsumerState<SourceDebugScreen> createState() => _SourceDebugScreenState();
}

class _SourceDebugScreenState extends ConsumerState<SourceDebugScreen> {
  final _sourceUrlCtrl = TextEditingController();
  final _keywordCtrl = TextEditingController();
  final _logScrollCtrl = ScrollController();

  bool _running = false;
  final List<_DebugLogEntry> _logs = [];

  /// 当前启用的日志级别过滤（全部启用时显示所有）
  final Set<_DebugLogLevel> _enabledLevels = _DebugLogLevel.values.toSet();

  @override
  void initState() {
    super.initState();
    if (widget.sourceUrl != null) {
      _sourceUrlCtrl.text = widget.sourceUrl!;
    }
  }

  @override
  void dispose() {
    _sourceUrlCtrl.dispose();
    _keywordCtrl.dispose();
    _logScrollCtrl.dispose();
    super.dispose();
  }

  void _appendLog(String message, {_DebugLogLevel level = _DebugLogLevel.info}) {
    setState(() {
      _logs.add(_DebugLogEntry(
        time: DateTime.now(),
        message: message,
        level: level,
      ));
    });
    _scrollToBottom();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_logScrollCtrl.hasClients) {
        _logScrollCtrl.jumpTo(_logScrollCtrl.position.maxScrollExtent);
      }
    });
  }

  /// 根据过滤条件获取可见日志
  List<_DebugLogEntry> get _filteredLogs {
    return _logs.where((log) => _enabledLevels.contains(log.level)).toList();
  }

  /// 提取真实错误消息：BridgeError 带 message 字段，直接内插 `$e`
  /// 只会显示 "Instance of 'BridgeError'"；取不到时回退 toString。
  String _errMsg(Object e) {
    try {
      final m = (e as dynamic).message;
      if (m is String && m.isNotEmpty) return m;
    } catch (_) {}
    return e.toString();
  }

  Future<void> _runDebug() async {
    final sourceUrl = _sourceUrlCtrl.text.trim();
    final keyword = _keywordCtrl.text.trim();

    if (sourceUrl.isEmpty) {
      _appendLog('错误：请输入书源 URL', level: _DebugLogLevel.error);
      return;
    }
    if (keyword.isEmpty) {
      _appendLog('错误：请输入搜索关键词', level: _DebugLogLevel.error);
      return;
    }

    setState(() {
      _running = true;
      _logs.clear();
    });

    final startMs = DateTime.now().millisecondsSinceEpoch;
    String stamp() {
      final elapsed = DateTime.now().millisecondsSinceEpoch - startMs;
      final m = (elapsed ~/ 60000).toString().padLeft(2, '0');
      final s = ((elapsed % 60000) ~/ 1000).toString().padLeft(2, '0');
      final ms = (elapsed % 1000).toString().padLeft(3, '0');
      return '[$m:$s.$ms]';
    }

    void step(String msg, {_DebugLogLevel level = _DebugLogLevel.info}) {
      _appendLog('${stamp()} $msg', level: level);
    }

    step('⇒开始调试');
    step('书源 URL: $sourceUrl');
    step('关键字: $keyword');

    try {
      final api = ref.read(bookApiProvider);
      final sources = await api.getBookSources();
      final source = sources.cast<BookSource?>().firstWhere(
            (s) => s!.bookSourceUrl == sourceUrl,
            orElse: () => null,
          );

      if (source == null) {
        step('错误：未找到书源 $sourceUrl', level: _DebugLogLevel.error);
        step('提示：请确认书源已导入且 URL 正确', level: _DebugLogLevel.warn);
        return;
      }

      step('书源名称: ${source.bookSourceName}', level: _DebugLogLevel.success);
      final sourceJson = jsonEncode(source.toJson());

      // 对齐 Debug.startDebug 关键字分流：绝对 URL / ::发现 / ++目录 / --正文 / 搜索
      if (keyword.startsWith('--')) {
        final chapterUrl = keyword.substring(2);
        step('⇒开始访正文页:$chapterUrl');
        await _debugContent(api, sourceJson, chapterUrl, step);
      } else if (keyword.startsWith('++')) {
        final tocUrl = keyword.substring(2);
        step('⇒开始访目录页:$tocUrl');
        await _debugTocThenContent(api, sourceJson, tocUrl, step);
      } else if (keyword.contains('::')) {
        step('⇒发现页调试暂未接线（需 exploreBook API）', level: _DebugLogLevel.warn);
        step('请使用普通关键词走搜索链路', level: _DebugLogLevel.warn);
      } else if (_looksLikeAbsUrl(keyword)) {
        step('⇒开始访问详情页:$keyword');
        await _debugInfoTocContent(api, sourceJson, keyword, step);
      } else {
        step('⇒开始搜索关键字:$keyword');
        step('︾开始解析搜索页');
        final resultJson = await api.webbookSearch(sourceJson, keyword, 1);
        final results = jsonDecode(resultJson) as List;
        if (results.isEmpty) {
          step('︽未获取到书籍', level: _DebugLogLevel.error);
          return;
        }
        step('︽搜索页解析完成', level: _DebugLogLevel.success);
        for (var i = 0; i < results.length && i < 5; i++) {
          final item = results[i] as Map<String, dynamic>;
          final name = item['book_name'] ?? item['name'] ?? '未知';
          final author = item['author'] ?? '';
          step('  [$i] $name${author.toString().isNotEmpty ? ' - $author' : ''}');
        }
        final first = results.first as Map<String, dynamic>;
        final bookUrl =
            (first['book_url'] ?? first['bookUrl'] ?? '').toString();
        if (bookUrl.isEmpty) {
          step('首条结果无 bookUrl，结束', level: _DebugLogLevel.error);
          return;
        }
        await _debugInfoTocContent(api, sourceJson, bookUrl, step);
      }

      step('=== 调试完成 ===', level: _DebugLogLevel.success);
    } catch (e) {
      step('异常: ${_errMsg(e)}', level: _DebugLogLevel.error);
    } finally {
      if (mounted) {
        setState(() => _running = false);
      }
    }
  }

  bool _looksLikeAbsUrl(String s) {
    final lower = s.toLowerCase();
    return lower.startsWith('http://') || lower.startsWith('https://');
  }

  Future<void> _debugInfoTocContent(
    dynamic api,
    String sourceJson,
    String bookUrl,
    void Function(String, {_DebugLogLevel level}) step,
  ) async {
    step('︾开始解析详情页');
    final infoJson = await api.webbookInfo(sourceJson, bookUrl);
    step('︽详情页解析完成', level: _DebugLogLevel.success);
    try {
      final info = jsonDecode(infoJson);
      if (info is Map) {
        final name = info['name'] ?? info['book_name'] ?? '';
        final author = info['author'] ?? '';
        if (name.toString().isNotEmpty) {
          step('书名: $name${author.toString().isNotEmpty ? ' / $author' : ''}');
        }
      }
    } catch (_) {
      step('详情原始: ${_preview(infoJson)}');
    }
    await _debugTocThenContent(api, sourceJson, bookUrl, step);
  }

  Future<void> _debugTocThenContent(
    dynamic api,
    String sourceJson,
    String bookUrl,
    void Function(String, {_DebugLogLevel level}) step,
  ) async {
    step('︾开始解析目录页');
    final chaptersJson = await api.webbookChapters(sourceJson, bookUrl);
    final chapters = jsonDecode(chaptersJson);
    if (chapters is! List || chapters.isEmpty) {
      step('︽未获取到目录', level: _DebugLogLevel.error);
      return;
    }
    step('︽目录解析完成，共 ${chapters.length} 章', level: _DebugLogLevel.success);
    for (var i = 0; i < chapters.length && i < 3; i++) {
      final c = chapters[i];
      if (c is Map) {
        step('  [$i] ${c['title'] ?? c['name'] ?? '章节'}');
      }
    }
    final first = chapters.first;
    if (first is! Map) {
      step('首章格式异常', level: _DebugLogLevel.error);
      return;
    }
    final chapterUrl =
        (first['url'] ?? first['chapter_url'] ?? first['link'] ?? '').toString();
    if (chapterUrl.isEmpty) {
      // 仍尝试用整章 JSON 取正文
      step('⇒开始获取正文（首章 JSON）');
      await _debugContentWithJson(
        api,
        sourceJson,
        jsonEncode(first),
        step,
      );
      return;
    }
    step('⇒开始获取正文:$chapterUrl');
    await _debugContentWithJson(api, sourceJson, jsonEncode(first), step);
  }

  Future<void> _debugContent(
    dynamic api,
    String sourceJson,
    String chapterUrl,
    void Function(String, {_DebugLogLevel level}) step,
  ) async {
    final chapterJson = jsonEncode({
      'title': '调试',
      'url': chapterUrl,
    });
    await _debugContentWithJson(api, sourceJson, chapterJson, step);
  }

  Future<void> _debugContentWithJson(
    dynamic api,
    String sourceJson,
    String chapterJson,
    void Function(String, {_DebugLogLevel level}) step,
  ) async {
    step('︾开始解析正文');
    final content = await api.webbookContent(sourceJson, chapterJson);
    final text = content.toString();
    if (text.trim().isEmpty) {
      step('︽正文为空', level: _DebugLogLevel.warn);
      return;
    }
    step('︽正文解析完成（${text.length} 字）', level: _DebugLogLevel.success);
    step(_preview(text), level: _DebugLogLevel.info);
  }

  String _preview(String text, {int max = 400}) {
    final t = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (t.length <= max) return t;
    return '${t.substring(0, max)}…';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final filteredLogs = _filteredLogs;

    return Scaffold(
      appBar: AppBar(
        title: const Text('书源调试'),
        actions: [
          // 清除日志按钮
          IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: '清空日志',
            onPressed: _logs.isEmpty
                ? null
                : () => setState(() => _logs.clear()),
          ),
        ],
      ),
      body: Column(
        children: [
          // 输入区域
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextField(
                  controller: _sourceUrlCtrl,
                  decoration: const InputDecoration(
                    labelText: '书源 URL',
                    hintText: '输入要调试的书源地址',
                    border: OutlineInputBorder(),
                    prefixIcon: Icon(Icons.link),
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _keywordCtrl,
                        decoration: const InputDecoration(
                          labelText: '搜索关键词',
                          hintText: '关键词 / URL / ++目录 / --正文',
                          border: OutlineInputBorder(),
                          prefixIcon: Icon(Icons.search),
                          isDense: true,
                        ),
                        onSubmitted: (_) => _runDebug(),
                      ),
                    ),
                    const SizedBox(width: 12),
                    FilledButton.icon(
                      onPressed: _running ? null : _runDebug,
                      icon: _running
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.play_arrow),
                      label: Text(_running ? '运行中' : '调试'),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          // 日志级别过滤栏
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: Row(
              children: [
                const Icon(Icons.filter_alt_outlined, size: 18),
                const SizedBox(width: 6),
                // 全选/取消全选按钮
                TextButton(
                  onPressed: () {
                    setState(() {
                      if (_enabledLevels.length == _DebugLogLevel.values.length) {
                        _enabledLevels.clear();
                      } else {
                        _enabledLevels
                          ..clear()
                          ..addAll(_DebugLogLevel.values);
                      }
                    });
                  },
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                  ),
                  child: Text(
                    _enabledLevels.length == _DebugLogLevel.values.length
                        ? '全不选'
                        : '全选',
                    style: theme.textTheme.labelSmall,
                  ),
                ),
                const SizedBox(width: 4),
                // 各级别过滤芯片（横向可滚动，避免窄屏右溢出）
                Expanded(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: _DebugLogLevel.values.map((level) {
                        return Padding(
                          padding: const EdgeInsets.only(right: 4),
                          child: FilterChip(
                            label: Text(level.label),
                            selected: _enabledLevels.contains(level),
                            onSelected: (selected) {
                              setState(() {
                                if (selected) {
                                  _enabledLevels.add(level);
                                } else {
                                  _enabledLevels.remove(level);
                                }
                              });
                            },
                            selectedColor: level.chipColor(theme),
                            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            visualDensity: VisualDensity.compact,
                            labelStyle: TextStyle(
                              fontSize: 11,
                              // 选中时背景为深色 shade（见 chipColor），白色保证对比度
                              color: _enabledLevels.contains(level)
                                  ? Colors.white
                                  : level.color(theme),
                            ),
                          ),
                        );
                      }).toList(),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                // 日志计数
                Text(
                  '${filteredLogs.length} / ${_logs.length} 条',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          // 日志输出区域
          Expanded(
            child: _logs.isEmpty
                ? Center(
                    child: Text(
                      '输入书源 URL 和关键词后点击"调试"开始',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  )
                : filteredLogs.isEmpty
                    ? Center(
                        child: Text(
                          '没有匹配的日志条目',
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      )
                    : ListView.builder(
                        controller: _logScrollCtrl,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 8,
                        ),
                        itemCount: filteredLogs.length,
                        itemBuilder: (context, index) {
                          final log = filteredLogs[index];
                          return _buildLogEntry(log, theme);
                        },
                      ),
          ),
        ],
      ),
    );
  }

  /// 构建单条日志条目（带左侧色条 + 背景色 + 图标）
  Widget _buildLogEntry(_DebugLogEntry log, ThemeData theme) {
    return Container(
      margin: const EdgeInsets.only(bottom: 4),
      decoration: BoxDecoration(
        color: log.level.bgColor(theme),
        borderRadius: BorderRadius.circular(6),
        border: Border(
          left: BorderSide(
            color: log.level.color(theme),
            width: 3,
          ),
        ),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 级别图标
          Icon(
            log.level.icon,
            size: 14,
            color: log.level.color(theme),
          ),
          const SizedBox(width: 8),
          // 时间戳
          Text(
            _formatTime(log.time),
            style: TextStyle(
              fontFamily: 'monospace',
              fontSize: 11,
              color: log.level.color(theme).withValues(alpha: 0.7),
            ),
          ),
          const SizedBox(width: 8),
          // 日志消息
          Expanded(
            child: SelectableText(
              log.message,
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 12,
                color: log.level.color(theme),
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _formatTime(DateTime time) {
    return '${time.hour.toString().padLeft(2, '0')}:'
        '${time.minute.toString().padLeft(2, '0')}:'
        '${time.second.toString().padLeft(2, '0')}.'
        '${time.millisecond.toString().padLeft(3, '0')}';
  }
}

/// 日志级别
enum _DebugLogLevel {
  info,
  success,
  warn,
  error;

  /// 显示标签
  String get label {
    switch (this) {
      case _DebugLogLevel.info:
        return 'INFO';
      case _DebugLogLevel.success:
        return '成功';
      case _DebugLogLevel.warn:
        return 'WARN';
      case _DebugLogLevel.error:
        return 'ERROR';
    }
  }

  /// 文字颜色
  Color color(ThemeData theme) {
    switch (this) {
      case _DebugLogLevel.info:
        return theme.colorScheme.onSurface;
      case _DebugLogLevel.success:
        return theme.brightness == Brightness.dark
            ? Colors.green.shade300
            : Colors.green.shade800;
      case _DebugLogLevel.warn:
        return theme.brightness == Brightness.dark
            ? Colors.orange.shade300
            : Colors.orange.shade800;
      case _DebugLogLevel.error:
        return theme.colorScheme.error;
    }
  }

  /// 背景颜色
  Color bgColor(ThemeData theme) {
    switch (this) {
      case _DebugLogLevel.info:
        return theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.3);
      case _DebugLogLevel.success:
        return Colors.green.withValues(alpha: 0.12);
      case _DebugLogLevel.warn:
        return Colors.orange.withValues(alpha: 0.12);
      case _DebugLogLevel.error:
        return theme.colorScheme.errorContainer.withValues(alpha: 0.4);
    }
  }

  /// 过滤芯片选中颜色
  ///
  /// [审计修复 §3.2] 作为选中背景与白色标签搭配，按亮暗选 shade 保证对比度 — Qoder
  Color chipColor(ThemeData theme) {
    final isDark = theme.brightness == Brightness.dark;
    switch (this) {
      case _DebugLogLevel.info:
        return isDark ? Colors.blueGrey.shade400 : Colors.blueGrey.shade600;
      case _DebugLogLevel.success:
        return isDark ? Colors.green.shade600 : Colors.green.shade700;
      case _DebugLogLevel.warn:
        return isDark ? Colors.orange.shade700 : Colors.orange.shade800;
      case _DebugLogLevel.error:
        return isDark ? Colors.red.shade600 : Colors.red.shade700;
    }
  }

  /// 级别图标
  IconData get icon {
    switch (this) {
      case _DebugLogLevel.info:
        return Icons.info_outline;
      case _DebugLogLevel.success:
        return Icons.check_circle_outline;
      case _DebugLogLevel.warn:
        return Icons.warning_amber_outlined;
      case _DebugLogLevel.error:
        return Icons.error_outline;
    }
  }
}

/// 调试日志条目
class _DebugLogEntry {
  final DateTime time;
  final String message;
  final _DebugLogLevel level;

  _DebugLogEntry({
    required this.time,
    required this.message,
    this.level = _DebugLogLevel.info,
  });
}
