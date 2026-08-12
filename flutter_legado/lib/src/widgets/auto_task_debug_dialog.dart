import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;

import '../providers/auto_task/auto_task_notifier.dart';
import '../services/auto_task_scheduler.dart';

/// 定时任务调试 Dialog（对标原版 `AutoTaskDebugActivity`）
///
/// 执行一次任务并展示结果摘要；不接原版 Debug 流式日志（Flutter 侧
/// AutoTask 为简化模型，无独立 Debug.Callback 通道）。
class AutoTaskDebugDialog extends ConsumerStatefulWidget {
  final AutoTask task;

  const AutoTaskDebugDialog({super.key, required this.task});

  @override
  ConsumerState<AutoTaskDebugDialog> createState() =>
      _AutoTaskDebugDialogState();
}

class _AutoTaskDebugDialogState extends ConsumerState<AutoTaskDebugDialog> {
  final _output = StringBuffer();
  bool _running = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _run());
  }

  Future<void> _run() async {
    if (_running) return;
    setState(() {
      _running = true;
      _output.clear();
      _output.writeln('[debug] 开始执行：${widget.task.name}');
      _output.writeln(
        '[debug] type=${widget.task.taskType} cron=${widget.task.cron}',
      );
    });
    try {
      await ref
          .read(autoTaskNotifierProvider.notifier)
          .runNow(widget.task.id);
      AutoTaskScheduler.instance.refresh();
      final refreshed = ref
          .read(autoTaskNotifierProvider)
          .tasks
          .where((t) => t.id == widget.task.id)
          .firstOrNull;
      if (!mounted) return;
      setState(() {
        _output.writeln(
          '[result] ${refreshed?.lastResult ?? "完成"}'
          ' @ ${refreshed?.lastRunAt ?? "-"}',
        );
        _running = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _output.writeln('[error] $e');
        _running = false;
      });
    }
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
        height: 280,
        child: SingleChildScrollView(
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
