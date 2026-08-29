import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../services/crash_log_service.dart';

/// 崩溃日志弹窗组件
///
/// 应用启动时检测到上次运行存在崩溃记录时弹出，
/// 展示崩溃时间与错误摘要，支持展开完整堆栈信息。
class CrashLogDialog extends StatefulWidget {
  /// 完整崩溃日志文本
  final String crashLog;

  const CrashLogDialog({super.key, required this.crashLog});

  /// 便捷显示方法
  static Future<void> show(BuildContext context, String crashLog) {
    return showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => CrashLogDialog(crashLog: crashLog),
    );
  }

  @override
  State<CrashLogDialog> createState() => _CrashLogDialogState();
}

class _CrashLogDialogState extends State<CrashLogDialog> {
  /// 是否展开完整堆栈信息
  bool _showDetails = false;

  /// 从日志中提取的崩溃时间
  String get _crashTime {
    for (final line in widget.crashLog.split('\n')) {
      if (line.startsWith('时间: ') || line.startsWith('时间:')) {
        return line.replaceFirst(RegExp(r'^时间:\s*'), '').trim();
      }
    }
    return '未知时间';
  }

  /// 从日志中提取的错误摘要
  String get _errorSummary {
    for (final line in widget.crashLog.split('\n')) {
      if (line.startsWith('错误: ') || line.startsWith('错误:')) {
        return line.replaceFirst(RegExp(r'^错误:\s*'), '').trim();
      }
    }
    return '未知错误';
  }

  /// 提取堆栈信息部分（"----- 堆栈信息 -----" 之后的内容）
  String get _stackTrace {
    final lines = widget.crashLog.split('\n');
    final idx = lines.indexWhere((l) => l.contains('堆栈信息'));
    if (idx == -1 || idx + 1 >= lines.length) return '';
    return lines
        .sublist(idx + 1)
        .where((l) => !l.contains('日志结束'))
        .join('\n')
        .trim();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final stackTrace = _stackTrace;

    return AlertDialog(
      icon: Icon(
        Symbols.error_rounded,
        color: colorScheme.error,
        size: 32,
      ),
      title: const Text('上次运行发生崩溃'),
      content: SizedBox(
        width: double.maxFinite,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 崩溃时间
              Row(
                children: [
                  Icon(
                    Symbols.schedule_rounded,
                    size: 16,
                    color: colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    '崩溃时间: $_crashTime',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              // 错误摘要
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: colorScheme.errorContainer.withValues(alpha: 0.4),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: SelectableText(
                  _errorSummary,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colorScheme.onErrorContainer,
                    fontFamily: 'monospace',
                  ),
                ),
              ),
              // 可展开的完整堆栈信息
              if (stackTrace.isNotEmpty) ...[
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    onPressed: () {
                      setState(() => _showDetails = !_showDetails);
                    },
                    icon: Icon(
                      _showDetails
                          ? Symbols.expand_less_rounded
                          : Symbols.expand_more_rounded,
                      size: 18,
                    ),
                    label: Text(_showDetails ? '收起详情' : '查看详情'),
                  ),
                ),
                if (_showDetails)
                  Container(
                    width: double.infinity,
                    constraints: const BoxConstraints(maxHeight: 300),
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: colorScheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: SingleChildScrollView(
                      child: SelectableText(
                        stackTrace,
                        style: const TextStyle(
                          fontSize: 11,
                          fontFamily: 'monospace',
                          height: 1.4,
                        ),
                      ),
                    ),
                  ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () {
            Navigator.of(context).pop();
            // 用户确认后清除崩溃日志，避免重复提示
            CrashLogService.instance.clearCrashLog();
          },
          child: const Text('确定'),
        ),
      ],
    );
  }
}
