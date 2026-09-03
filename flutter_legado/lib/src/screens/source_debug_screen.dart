import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import '../widgets/legado_app_bar.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' hide Provider, ChangeNotifierProvider;

import '../providers/providers.dart';
import '../widgets/help/help_assets.dart';
import '../widgets/help/show_help.dart';

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

    _appendLog('⇒开始调试');

    StreamSubscription<Map<String, dynamic>>? sub;
    try {
      final api = ref.read(bookApiProvider);
      sub = api.debugBookSourceStream(sourceUrl, keyword).listen(
        (item) {
          if (!mounted) return;
          final state = item['state'] is int
              ? item['state'] as int
              : int.tryParse('${item['state']}') ?? 1;
          final msg = (item['msg'] ?? '').toString();
          if (msg.isEmpty) return;
          final level = state < 0
              ? _DebugLogLevel.error
              : state >= 1000
                  ? _DebugLogLevel.success
                  : _DebugLogLevel.info;
          _appendLog(msg, level: level);
        },
        onError: (Object e) {
          if (!mounted) return;
          _appendLog('异常: ${_errMsg(e)}', level: _DebugLogLevel.error);
        },
        onDone: () {
          if (!mounted) return;
          setState(() => _running = false);
        },
        cancelOnError: true,
      );
      await sub.asFuture<void>();
    } catch (e) {
      _appendLog('异常: ${_errMsg(e)}', level: _DebugLogLevel.error);
    } finally {
      await sub?.cancel();
      if (mounted) {
        setState(() => _running = false);
      }
    }
  }

  Future<void> _cancelDebug() async {
    try {
      await ref.read(bookApiProvider).cancelDebugBookSource();
    } catch (_) {}
    if (mounted) {
      setState(() => _running = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final filteredLogs = _filteredLogs;

    return Scaffold(
      appBar: LegadoAppBar(
        title: const Text('书源调试'),
        actions: [
          IconButton(
            icon: const Icon(Symbols.help_rounded),
            tooltip: '帮助',
            onPressed: () => showHelp(context, HelpAssets.debugHelp),
          ),
          // 清除日志按钮
          IconButton(
            icon: const Icon(Symbols.delete_rounded),
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
                    prefixIcon: Icon(Symbols.link_rounded),
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
                          prefixIcon: Icon(Symbols.search_rounded),
                          isDense: true,
                        ),
                        onSubmitted: (_) => _runDebug(),
                      ),
                    ),
                    const SizedBox(width: 12),
                    FilledButton.icon(
                      onPressed: _running ? _cancelDebug : _runDebug,
                      icon: _running
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Symbols.play_arrow_rounded),
                      label: Text(_running ? '停止' : '调试'),
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
                const Icon(Symbols.filter_alt_rounded, size: 18),
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
                              // 选中时背景为 tonal role（见 chipColor），白色为其 on 色
                              //（primary/tertiary/error 的 on 色均为白系），保证对比度
                              color: _enabledLevels.contains(level)
                                  // ignore: use_full_hex_values_for_flutter_colors
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
  ///
  /// [UI_MD3_ALIGNMENT_PLAN.md Batch B B1] 状态语义色走 tonal role：
  /// 成功=primary、警告=tertiary、错误=error，亮暗自适应
  Color color(ThemeData theme) {
    switch (this) {
      case _DebugLogLevel.info:
        return theme.colorScheme.onSurface;
      case _DebugLogLevel.success:
        return theme.colorScheme.primary;
      case _DebugLogLevel.warn:
        return theme.colorScheme.tertiary;
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
        return theme.colorScheme.primaryContainer.withValues(alpha: 0.4);
      case _DebugLogLevel.warn:
        return theme.colorScheme.tertiaryContainer.withValues(alpha: 0.4);
      case _DebugLogLevel.error:
        return theme.colorScheme.errorContainer.withValues(alpha: 0.4);
    }
  }

  /// 过滤芯片选中颜色
  ///
  /// [审计修复 §3.2] 作为选中背景与白色标签搭配，按亮暗选 shade 保证对比度 — Qoder
  /// [UI_MD3_ALIGNMENT_PLAN.md Batch B B1] 改走 tonal container role
  Color chipColor(ThemeData theme) {
    switch (this) {
      case _DebugLogLevel.info:
        return theme.colorScheme.outline;
      case _DebugLogLevel.success:
        return theme.colorScheme.primary;
      case _DebugLogLevel.warn:
        return theme.colorScheme.tertiary;
      case _DebugLogLevel.error:
        return theme.colorScheme.error;
    }
  }

  /// 级别图标
  IconData get icon {
    switch (this) {
      case _DebugLogLevel.info:
        return Symbols.info_rounded;
      case _DebugLogLevel.success:
        return Symbols.check_circle_rounded;
      case _DebugLogLevel.warn:
        return Symbols.warning_amber_rounded;
      case _DebugLogLevel.error:
        return Symbols.error_rounded;
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
