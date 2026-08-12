import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;

import '../providers/auto_task/auto_task_notifier.dart';
import '../providers/providers.dart';
import '../services/auto_task_scheduler.dart';

/// 定时任务调试 Dialog（对标原版 `AutoTaskDebugActivity` + `Debug.Callback`）
///
/// 以 Stream 逐行追加日志（对齐 `printLog` 流式观感）；执行走既有
/// `autoTaskExecuteWithId`，无新 FFI StreamSink（协议动作非 Rhino 中途回调）。
class AutoTaskDebugDialog extends ConsumerStatefulWidget {
  final AutoTask task;

  const AutoTaskDebugDialog({super.key, required this.task});

  @override
  ConsumerState<AutoTaskDebugDialog> createState() =>
      _AutoTaskDebugDialogState();
}

class _AutoTaskDebugDialogState extends ConsumerState<AutoTaskDebugDialog> {
  final _output = StringBuffer();
  final _scroll = ScrollController();
  bool _running = false;
  int _runGen = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _run());
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _append(String line) {
    if (!mounted) return;
    setState(() => _output.writeln(line));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      }
    });
  }

  Future<void> _run() async {
    if (_running) return;
    final gen = ++_runGen;
    setState(() {
      _running = true;
      _output.clear();
    });

    final startMs = DateTime.now().millisecondsSinceEpoch;
    String stamp(String msg) {
      final elapsed = DateTime.now().millisecondsSinceEpoch - startMs;
      final m = (elapsed ~/ 60000).toString().padLeft(2, '0');
      final s = ((elapsed % 60000) ~/ 1000).toString().padLeft(2, '0');
      final ms = (elapsed % 1000).toString().padLeft(3, '0');
      return '[$m:$s.$ms] $msg';
    }

    void emit(String msg) {
      if (gen != _runGen || !mounted) return;
      _append(stamp(msg));
    }

    emit('Running ${widget.task.name}');
    emit(
      'type=${widget.task.taskType} cron=${widget.task.cron}',
    );

    try {
      final api = ref.read(bookApiProvider);
      Map<String, dynamic>? rule;
      try {
        rule = await api.autoTaskFindRuleById(id: widget.task.id);
      } catch (_) {}
      if (gen != _runGen) return;

      final script = rule?['script']?.toString() ?? '';
      if (script.isNotEmpty) {
        final preview = script.length > 120
            ? '${script.substring(0, 120)}…'
            : script;
        emit('script: $preview');
      }

      final protocolJson = _buildProtocolJson(widget.task, rule);
      emit('Executing…');

      final result = await api.autoTaskExecuteWithId(
        protocolJson: protocolJson,
        taskId: widget.task.id,
      );
      if (gen != _runGen) return;

      final success = result['success'] as bool? ?? false;
      final message = result['message']?.toString() ?? '';
      final duration = result['duration_ms'] ?? result['durationMs'];
      final details = result['details']?.toString();

      if (success) {
        emit('Task completed');
      } else {
        emit(message.isEmpty ? 'Task failed' : message);
      }

      // 对齐 AutoTaskDebugActivity：追加 result.log 分行（流式写入 UI）
      final logBody = (details != null && details.isNotEmpty)
          ? details
          : '[${success ? 'OK' : 'FAIL'}] Elapsed: ${duration ?? '-'}ms'
              '${message.isEmpty ? '' : '\n- $message'}';
      for (final line in logBody.split('\n')) {
        if (line.trim().isEmpty) continue;
        await Future<void>.delayed(const Duration(milliseconds: 16));
        if (gen != _runGen) return;
        _append(line);
      }

      // 同步列表摘要（persist=false 语义：调试不强制写库，但刷新展示）
      try {
        await ref.read(autoTaskNotifierProvider.notifier).loadTasks(silent: true);
      } catch (_) {}
      AutoTaskScheduler.instance.refresh();
    } catch (e) {
      if (gen == _runGen) emit('error: $e');
    } finally {
      if (mounted && gen == _runGen) {
        setState(() => _running = false);
      }
    }
  }

  /// 构建 TaskProtocol JSON（对齐 Rust `TaskAction` 外部标签）
  String _buildProtocolJson(AutoTask task, Map<String, dynamic>? rule) {
    final script = rule?['script']?.toString().trim() ?? '';
    if (script.startsWith('{')) {
      try {
        final map = jsonDecode(script);
        if (map is Map && map.containsKey('action')) {
          // 已是协议或含 action 的脚本 JSON
          if (map['params'] is Map || map['action'] is Map || map['action'] is String) {
            // 若仅有 Kotlin 风格业务 JSON，仍尝试原样交给执行器
            return script;
          }
        }
      } catch (_) {}
    }

    switch (task.taskType) {
      case 'refreshToc':
        return jsonEncode({
          'action': 'RefreshToc',
          'params': _paramsFromScript(script),
        });
      case 'updateSources':
        return jsonEncode({'action': 'UpdateSources', 'params': {}});
      case 'backup':
        return jsonEncode({'action': 'Backup', 'params': {}});
      default:
        final js = script.isNotEmpty ? script : task.taskType;
        return jsonEncode({
          'action': {'Custom': js},
          'params': {},
        });
    }
  }

  Map<String, String> _paramsFromScript(String script) {
    if (!script.startsWith('{')) return {};
    try {
      final map = jsonDecode(script);
      if (map is! Map) return {};
      final bookUrl = map['bookUrl'] ?? map['book_url'];
      if (bookUrl != null && bookUrl.toString().isNotEmpty) {
        return {'bookUrl': bookUrl.toString()};
      }
    } catch (_) {}
    return {};
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: Row(
        children: [
          Expanded(child: Text('调试：${widget.task.name}')),
          if (_running)
            const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
        ],
      ),
      content: SizedBox(
        width: double.maxFinite,
        height: 320,
        child: SingleChildScrollView(
          controller: _scroll,
          child: SelectableText(
            _output.isEmpty ? '准备中…' : _output.toString(),
            style: const TextStyle(
              fontFamily: 'monospace',
              fontSize: 13,
              height: 1.35,
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _running ? null : _run,
          child: const Text('重新运行'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('关闭'),
        ),
      ],
    );
  }
}
