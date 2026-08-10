import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' hide Provider, ChangeNotifierProvider;

import '../providers/providers.dart';
import '../widgets/loading_indicator.dart';

/// 缓存下载队列页（对齐原版 CacheActivity 进度列表）
///
/// 轮询 [BookApi.cacheDownloadList] 展示批量缓存下载任务：
/// 任务状态（下载中/已完成/已取消/失败）、已完成/总数进度条、取消按钮。
/// [UI-fix v2.0.16 | 2026-08-10] 此前无下载队列页，且阅读页缓存按钮仅登记
/// 内存任务不执行下载 — Reasonix
class CacheDownloadScreen extends ConsumerStatefulWidget {
  const CacheDownloadScreen({super.key});

  @override
  ConsumerState<CacheDownloadScreen> createState() => _CacheDownloadScreenState();
}

/// 单个缓存下载任务（camelCase 对齐 Rust CacheDownloadTask 快照）
class _DownloadTask {
  final int taskId;
  final String bookUrl;
  final String status;
  final int total;
  final int completed;
  final int failed;

  const _DownloadTask({
    required this.taskId,
    required this.bookUrl,
    required this.status,
    required this.total,
    required this.completed,
    required this.failed,
  });

  factory _DownloadTask.fromJson(Map<String, dynamic> json) => _DownloadTask(
        taskId: (json['taskId'] as num?)?.toInt() ?? 0,
        bookUrl: json['bookUrl'] as String? ?? '',
        status: json['status'] as String? ?? 'unknown',
        total: (json['total'] as num?)?.toInt() ?? 0,
        completed: (json['completed'] as num?)?.toInt() ?? 0,
        failed: (json['failed'] as num?)?.toInt() ?? 0,
      );

  bool get isRunning => status == 'running';

  String get statusLabel => switch (status) {
        'running' => '下载中',
        'completed' => '已完成',
        'cancelled' => '已取消',
        'failed' => '失败',
        'notFound' => '已失效',
        _ => status,
      };
}

class _CacheDownloadScreenState extends ConsumerState<CacheDownloadScreen> {
  List<_DownloadTask> _tasks = [];
  bool _loading = true;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _refresh();
    // 任务轮询（2s，页面可见期间保持实时；原版经 EventBus 实时刷新，
    // 重构版无事件总线，以轻量本地查询轮询等价实现）
    _timer = Timer.periodic(const Duration(seconds: 2), (_) => _refresh());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    try {
      final api = ref.read(bookApiProvider);
      final json = await api.cacheDownloadList();
      final decoded = jsonDecode(json);
      final tasks = <_DownloadTask>[];
      if (decoded is List) {
        for (final item in decoded) {
          if (item is Map<String, dynamic>) {
            tasks.add(_DownloadTask.fromJson(item));
          }
        }
      }
      if (!mounted) return;
      setState(() {
        _tasks = tasks;
        _loading = false;
      });
    } catch (_) {
      // 轮询失败（如任务表未初始化）静默保留旧列表
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  Future<void> _cancel(int taskId) async {
    try {
      final api = ref.read(bookApiProvider);
      await api.cacheDownloadCancel(taskId);
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('取消失败')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('缓存下载队列'),
        actions: [
          IconButton(
            tooltip: '刷新',
            icon: const Icon(Icons.refresh),
            onPressed: _refresh,
          ),
        ],
      ),
      body: _loading
          ? const LoadingIndicator()
          : _tasks.isEmpty
              ? _buildEmpty(cs)
              : RefreshIndicator(
                  onRefresh: () async => _refresh(),
                  child: ListView.separated(
                    itemCount: _tasks.length,
                    separatorBuilder: (_, _) => Divider(
                        height: 1,
                        color: cs.outlineVariant.withValues(alpha: 0.3)),
                    itemBuilder: (context, index) =>
                        _buildTaskTile(_tasks[index]),
                  ),
                ),
    );
  }

  Widget _buildEmpty(ColorScheme cs) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.download_done, size: 64, color: cs.outlineVariant),
          const SizedBox(height: 12),
          const Text('暂无缓存下载任务'),
          const SizedBox(height: 4),
          Text(
            '阅读页顶栏「缓存」按钮可发起批量缓存下载',
            style: TextStyle(color: cs.onSurfaceVariant, fontSize: 13),
          ),
        ],
      ),
    );
  }

  Widget _buildTaskTile(_DownloadTask task) {
    final cs = Theme.of(context).colorScheme;
    final progress = task.total > 0 ? task.completed / task.total : 0.0;
    final color = switch (task.status) {
      'running' => cs.primary,
      'completed' => Colors.green,
      'cancelled' => cs.onSurfaceVariant,
      'failed' => cs.error,
      _ => cs.outline,
    };
    return ListTile(
      leading: Icon(
        task.isRunning ? Icons.cloud_download : Icons.cloud_done,
        color: color,
      ),
      title: Text(
        task.bookUrl,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 14),
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 4),
          LinearProgressIndicator(
            value: progress,
            minHeight: 4,
            backgroundColor: cs.surfaceContainerHighest,
          ),
          const SizedBox(height: 4),
          Text(
            '${task.statusLabel} · ${task.completed}/${task.total}'
            '${task.failed > 0 ? ' · 失败 ${task.failed}' : ''}',
            style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
          ),
        ],
      ),
      trailing: task.isRunning
          ? TextButton(
              onPressed: () => _cancel(task.taskId),
              child: const Text('取消'),
            )
          : null,
    );
  }
}
