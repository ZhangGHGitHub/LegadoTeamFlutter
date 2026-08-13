import 'package:flutter/material.dart';
import '../widgets/legado_app_bar.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;

import '../providers/providers.dart';

/// RSS 源调试页面
///
/// 对标安卓原版 RssSourceDebugActivity：输入 RSS 源 URL，经 BookApi
/// 逐步执行「查源 → 抓取文章」链路，实时输出调试日志
///（REFACTORING_REMAINING_PLAN §4.3 P2-2⑤）。
/// 架构合规（§0.2 铁律）：全部经 BookApi（getRssSources/getRssArticles），
/// 不直调 bridge。
class RssSourceDebugScreen extends ConsumerStatefulWidget {
  /// 可选：外部传入 RSS 源 URL 预填
  final String? sourceUrl;

  const RssSourceDebugScreen({super.key, this.sourceUrl});

  @override
  ConsumerState<RssSourceDebugScreen> createState() =>
      _RssSourceDebugScreenState();
}

class _RssSourceDebugScreenState extends ConsumerState<RssSourceDebugScreen> {
  final _sourceUrlCtrl = TextEditingController();
  final _logScrollCtrl = ScrollController();

  bool _running = false;
  final List<_DebugLogEntry> _logs = [];

  /// 当前启用的日志级别过滤器（全部启用时显示全部）
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
    _logScrollCtrl.dispose();
    super.dispose();
  }

  /// 按当前过滤器筛选日志
  List<_DebugLogEntry> get _filteredLogs =>
      _logs.where((log) => _enabledLevels.contains(log.level)).toList();

  void _appendLog(String message, {_DebugLogLevel level = _DebugLogLevel.info}) {
    if (!mounted) return;
    setState(() => _logs.add(_DebugLogEntry(
          time: DateTime.now(),
          message: message,
          level: level,
        )));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_logScrollCtrl.hasClients) {
        _logScrollCtrl.jumpTo(_logScrollCtrl.position.maxScrollExtent);
      }
    });
  }

  /// 执行调试链路：查源 → 抓取文章
  Future<void> _runDebug() async {
    final sourceUrl = _sourceUrlCtrl.text.trim();
    if (sourceUrl.isEmpty) {
      _appendLog('错误：请先输入 RSS 源地址', level: _DebugLogLevel.error);
      return;
    }
    setState(() => _running = true);
    _appendLog('=== 开始调试 RSS 源 ===');
    _appendLog('源地址: $sourceUrl');

    try {
      final api = ref.read(bookApiProvider);

      // 1. 查询已注册的 RSS 源
      _appendLog('[1/2] 正在查询已注册的 RSS 源...');
      final sources = await api.getRssSources();
      final source =
          sources.where((s) => s.sourceUrl == sourceUrl).firstOrNull;
      if (source == null) {
        _appendLog(
          '未在书架注册该 RSS 源，将直接按 URL 抓取',
          level: _DebugLogLevel.warn,
        );
      } else {
        _appendLog('源名称: ${source.sourceName}',
            level: _DebugLogLevel.success);
      }

      // 2. 抓取文章列表
      _appendLog('[2/2] 正在抓取文章列表...');
      final articles = await api.getRssArticles(sourceUrl);
      if (articles.isEmpty) {
        _appendLog('未获取到文章（可能需要配置规则或源不可达）',
            level: _DebugLogLevel.warn);
      } else {
        _appendLog('抓取完成，共 ${articles.length} 篇文章',
            level: _DebugLogLevel.success);
        for (var i = 0; i < articles.length && i < 10; i++) {
          final a = articles[i];
          _appendLog('  [$i] ${a.title.isEmpty ? '(无标题)' : a.title}');
          if (a.url.isNotEmpty) {
            _appendLog('      链接: ${a.url}');
          }
        }
        if (articles.length > 10) {
          _appendLog('  ...（其余 ${articles.length - 10} 篇省略）');
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
      appBar: LegadoAppBar(
        title: const Text('RSS 源调试'),
        actions: [
          IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: '清空日志',
            onPressed:
                _logs.isEmpty ? null : () => setState(() => _logs.clear()),
          ),
        ],
      ),
      body: Column(
        children: [
          // 输入区域
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _sourceUrlCtrl,
                    decoration: const InputDecoration(
                      labelText: 'RSS 源 URL',
                      hintText: '输入要调试的 RSS 源地址',
                      border: OutlineInputBorder(),
                      prefixIcon: Icon(Icons.rss_feed),
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
          ),
          const Divider(height: 1),
          // 日志级别过滤栏
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: Row(
              children: [
                const Icon(Icons.filter_alt_outlined, size: 18),
                const SizedBox(width: 6),
                for (final level in _DebugLogLevel.values)
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
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
                      visualDensity: VisualDensity.compact,
                      selectedColor:
                          level.chipColor(theme).withValues(alpha: 0.25),
                      checkmarkColor: level.chipColor(theme),
                    ),
                  ),
              ],
            ),
          ),
          const Divider(height: 1),
          // 日志输出区
          Expanded(
            child: filteredLogs.isEmpty
                ? Center(
                    child: Text(
                      _logs.isEmpty ? '点击「调试」开始执行' : '当前过滤条件下无日志',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  )
                : ListView.builder(
                    controller: _logScrollCtrl,
                    padding: const EdgeInsets.all(12),
                    itemCount: filteredLogs.length,
                    itemBuilder: (context, index) {
                      final log = filteredLogs[index];
                      final timeStr = '${_pad(log.time.hour)}:${_pad(log.time.minute)}:${_pad(log.time.second)}';
                      return Container(
                        margin: const EdgeInsets.only(bottom: 4),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: log.level.bgColor(theme),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: SelectableText.rich(
                          TextSpan(
                            children: [
                              TextSpan(
                                text: '[$timeStr] ',
                                style: TextStyle(
                                  color: theme.colorScheme.onSurfaceVariant,
                                  fontSize: 11,
                                ),
                              ),
                              TextSpan(
                                text: log.message,
                                style: TextStyle(
                                  color: log.level.color(theme),
                                  fontSize: 12,
                                  fontFamily: 'monospace',
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  /// 两位数补零
  String _pad(int v) => v.toString().padLeft(2, '0');
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
