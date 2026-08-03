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

    _appendLog('=== 开始调试 ===');
    _appendLog('书源 URL: $sourceUrl');
    _appendLog('搜索关键词: $keyword');

    try {
      // 1. 获取书源 JSON
      _appendLog('[1/3] 正在获取书源信息...');
      final api = ref.read(bookApiProvider);
      final sources = await api.getBookSources();
      final source = sources.cast<BookSource?>().firstWhere(
            (s) => s!.bookSourceUrl == sourceUrl,
            orElse: () => null,
          );

      if (source == null) {
        _appendLog('错误：未找到书源 $sourceUrl', level: _DebugLogLevel.error);
        _appendLog('提示：请确认书源已导入且 URL 正确', level: _DebugLogLevel.warn);
        return;
      }

      _appendLog('书源名称: ${source.bookSourceName}', level: _DebugLogLevel.success);
      _appendLog('书源类型: ${source.bookSourceType}');

      // 2. 执行搜索
      _appendLog('[2/3] 正在执行搜索...');
      final sourceJson = jsonEncode(source.toJson());
      final resultJson = await api.webbookSearch(sourceJson, keyword, 1);

      final results = jsonDecode(resultJson) as List;
      _appendLog('搜索完成，返回 ${results.length} 条结果', level: _DebugLogLevel.success);

      // 3. 显示结果
      _appendLog('[3/3] 搜索结果：');
      if (results.isEmpty) {
        _appendLog('  (无结果)', level: _DebugLogLevel.warn);
      } else {
        for (var i = 0; i < results.length && i < 10; i++) {
          final item = results[i] as Map<String, dynamic>;
          final name = item['bookName'] ?? item['name'] ?? '未知';
          final author = item['author'] ?? '';
          final bookUrl = item['bookUrl'] ?? '';
          _appendLog('  [$i] $name ${author.toString().isNotEmpty ? '- $author' : ''}');
          _appendLog('      URL: $bookUrl');
        }
        if (results.length > 10) {
          _appendLog('  ... 还有 ${results.length - 10} 条结果');
        }
      }

      _appendLog('=== 调试完成 ===', level: _DebugLogLevel.success);
    } catch (e) {
      _appendLog('异常: $e', level: _DebugLogLevel.error);
    } finally {
      if (mounted) {
        setState(() => _running = false);
      }
    }
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
                          hintText: '输入测试关键词',
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
                // 各级别过滤芯片
                ..._DebugLogLevel.values.map((level) {
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
                        color: _enabledLevels.contains(level)
                            ? Colors.white
                            : level.color(theme),
                      ),
                    ),
                  );
                }),
                const Spacer(),
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
  Color chipColor(ThemeData theme) {
    switch (this) {
      case _DebugLogLevel.info:
        return Colors.blueGrey;
      case _DebugLogLevel.success:
        return Colors.green;
      case _DebugLogLevel.warn:
        return Colors.orange;
      case _DebugLogLevel.error:
        return Colors.red;
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
