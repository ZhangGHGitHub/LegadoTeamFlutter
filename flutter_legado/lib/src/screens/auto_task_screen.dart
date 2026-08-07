import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../providers/auto_task/auto_task_notifier.dart';
import '../services/auto_task_scheduler.dart';

/// 定时任务管理页面
class AutoTaskScreen extends ConsumerStatefulWidget {
  const AutoTaskScreen({super.key});

  @override
  ConsumerState<AutoTaskScreen> createState() => _AutoTaskScreenState();
}

class _AutoTaskScreenState extends ConsumerState<AutoTaskScreen> {
  // [UI-fix v2.0.3 | 2026-08-08] 任务增删改后通知应用内调度器重算
  //（Task #146，对齐原版 AutoTask.save/delete/updateEnabled 后 refresh） — Qoder
  void _resyncScheduler() => AutoTaskScheduler.instance.refresh();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(autoTaskNotifierProvider.notifier).loadTasks();
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(autoTaskNotifierProvider);
    final notifier = ref.read(autoTaskNotifierProvider.notifier);
    return Scaffold(
      appBar: AppBar(
        title: const Text('定时任务'),
        // [UI-fix v2.0.3 | 2026-08-06] 溢出菜单（对标原版 AutoTaskActivity
        // menu_import_local / menu_import_on_line / menu_export / menu_help）
        // — Qoder
        actions: [
          PopupMenuButton<String>(
            onSelected: (value) {
              switch (value) {
                case 'import_local':
                  _importLocal(context);
                  break;
                case 'import_online':
                  _showImportOnlineDialog(context);
                  break;
                case 'export':
                  _exportTasks(context);
                  break;
                case 'help':
                  _showHelpDialog(context);
                  break;
              }
            },
            itemBuilder: (context) => const [
              PopupMenuItem(value: 'import_local', child: Text('导入本地任务')),
              PopupMenuItem(value: 'import_online', child: Text('导入线上任务')),
              PopupMenuItem(value: 'export', child: Text('导出任务')),
              PopupMenuItem(value: 'help', child: Text('帮助')),
            ],
          ),
        ],
      ),
      body: Builder(
        builder: (context) {
          if (state.isLoading) {
            return const Center(child: CircularProgressIndicator());
          }

          if (state.error != null) {
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.error_outline,
                      size: 48, color: Theme.of(context).colorScheme.error),
                  const SizedBox(height: 8),
                  Text(state.error!,
                      style: TextStyle(
                          color: Theme.of(context).colorScheme.error)),
                  const SizedBox(height: 16),
                  FilledButton(
                    onPressed: () => notifier.loadTasks(),
                    child: const Text('重试'),
                  ),
                ],
              ),
            );
          }

          if (state.tasks.isEmpty) {
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.schedule, size: 64,
                      color: Theme.of(context).colorScheme.onSurfaceVariant),
                  const SizedBox(height: 8),
                  Text('暂无定时任务',
                      style: TextStyle(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                          fontSize: 16)),
                  const SizedBox(height: 4),
                  Text('点击右下角按钮添加新任务',
                      style: TextStyle(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                          fontSize: 12)),
                ],
              ),
            );
          }

          return RefreshIndicator(
            onRefresh: () => notifier.loadTasks(),
            child: ListView.separated(
              itemCount: state.tasks.length,
              separatorBuilder: (_, index) => const Divider(height: 1),
              itemBuilder: (context, index) {
                final task = state.tasks[index];
                return _buildTaskTile(context, notifier, task);
              },
            ),
          );
        },
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _showAddTaskDialog(context),
        child: const Icon(Icons.add),
      ),
    );
  }

  Widget _buildTaskTile(
      BuildContext context, AutoTaskNotifier provider, AutoTask task) {
    final IconData icon;
    switch (task.taskType) {
      case 'refreshToc':
        icon = Icons.refresh;
        break;
      case 'updateSources':
        icon = Icons.update;
        break;
      case 'backup':
        icon = Icons.backup;
        break;
      default:
        icon = Icons.schedule;
    }

    return ListTile(
      leading: Icon(icon, color: Theme.of(context).colorScheme.primary),
      title: Text(task.name),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 2),
          Row(
            children: [
              Icon(Icons.schedule, size: 12,
                  color: Theme.of(context).colorScheme.onSurfaceVariant),
              const SizedBox(width: 4),
              Text('cron: ${task.cron}',
                  style: TextStyle(fontSize: 12,
                      color: Theme.of(context).colorScheme.onSurfaceVariant)),
            ],
          ),
          if (task.lastRunAt != null) ...[
            const SizedBox(height: 2),
            Text('上次运行: ${task.lastRunAt} · ${task.lastResult ?? "未知"}',
                style: TextStyle(fontSize: 12,
                    color: Theme.of(context).colorScheme.onSurfaceVariant)),
          ],
        ],
      ),
      trailing: Switch(
        value: task.isEnabled,
        onChanged: (value) =>
            provider.toggleTask(task.id, value).then((_) => _resyncScheduler()),
      ),
      onLongPress: () => _showTaskOptions(context, provider, task),
      isThreeLine: task.lastRunAt != null,
    );
  }

  /// 显示添加任务对话框
  Future<void> _showAddTaskDialog(BuildContext context) async {
    final nameController = TextEditingController();
    String taskType = 'refreshToc';
    final cronController = TextEditingController(text: '0 8 * * *');

    final result = await showDialog<AutoTask>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('添加定时任务'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: nameController,
                  decoration: const InputDecoration(
                    labelText: '任务名称',
                    hintText: '例如：每日刷新',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: taskType,
                  decoration: const InputDecoration(
                    labelText: '任务类型',
                    border: OutlineInputBorder(),
                  ),
                  items: const [
                    DropdownMenuItem(
                        value: 'refreshToc', child: Text('刷新目录')),
                    DropdownMenuItem(
                        value: 'updateSources', child: Text('更新书源')),
                    DropdownMenuItem(value: 'backup', child: Text('自动备份')),
                  ],
                  onChanged: (val) {
                    setDialogState(() => taskType = val ?? 'refreshToc');
                  },
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: cronController,
                  decoration: const InputDecoration(
                    labelText: 'Cron 表达式',
                    hintText: '0 8 * * *',
                    border: OutlineInputBorder(),
                    helperText: '标准5位 cron 表达式（分 时 日 月 周）',
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () {
                if (nameController.text.isEmpty) return;
                Navigator.pop(
                  ctx,
                  AutoTask(
                    id: DateTime.now().millisecondsSinceEpoch.toString(),
                    name: nameController.text,
                    taskType: taskType,
                    cron: cronController.text,
                    isEnabled: true,
                  ),
                );
              },
              child: const Text('添加'),
            ),
          ],
        ),
      ),
    );

    if (result != null && context.mounted) {
      await ref.read(autoTaskNotifierProvider.notifier).createTask(result);
      _resyncScheduler();
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('已添加任务: ${result.name}')),
        );
      }
    }
  }

  /// 显示任务操作菜单
  void _showTaskOptions(
      BuildContext context, AutoTaskNotifier provider, AutoTask task) {
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.play_arrow),
              title: const Text('立即运行'),
              subtitle: Text(task.name),
              onTap: () {
                Navigator.pop(ctx);
                provider.runNow(task.id).then((_) => _resyncScheduler());
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('正在运行: ${task.name}')),
                );
              },
            ),
            ListTile(
              leading: const Icon(Icons.edit),
              title: const Text('编辑任务'),
              onTap: () {
                Navigator.pop(ctx);
                _showEditTaskDialog(context, task);
              },
            ),
            ListTile(
              leading: Icon(Icons.delete, color: Theme.of(context).colorScheme.error),
              title: Text('删除任务',
                  style: TextStyle(color: Theme.of(context).colorScheme.error)),
              onTap: () {
                Navigator.pop(ctx);
                _confirmDelete(context, provider, task);
              },
            ),
          ],
        ),
      ),
    );
  }

  /// 编辑任务对话框
  Future<void> _showEditTaskDialog(BuildContext context, AutoTask task) async {
    final nameController = TextEditingController(text: task.name);
    String taskType = task.taskType;
    final cronController = TextEditingController(text: task.cron);

    final result = await showDialog<AutoTask>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('编辑定时任务'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: nameController,
                  decoration: const InputDecoration(
                    labelText: '任务名称',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: taskType,
                  decoration: const InputDecoration(
                    labelText: '任务类型',
                    border: OutlineInputBorder(),
                  ),
                  items: const [
                    DropdownMenuItem(
                        value: 'refreshToc', child: Text('刷新目录')),
                    DropdownMenuItem(
                        value: 'updateSources', child: Text('更新书源')),
                    DropdownMenuItem(value: 'backup', child: Text('自动备份')),
                  ],
                  onChanged: (value) {
                    setDialogState(() => taskType = value ?? 'refreshToc');
                  },
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: cronController,
                  decoration: const InputDecoration(
                    labelText: 'Cron 表达式',
                    border: OutlineInputBorder(),
                    helperText: '标准5位 cron 表达式（分 时 日 月 周）',
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () {
                if (nameController.text.isEmpty) return;
                Navigator.pop(
                  ctx,
                  task.copyWith(
                    name: nameController.text,
                    taskType: taskType,
                    cron: cronController.text,
                  ),
                );
              },
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );

    if (result != null && context.mounted) {
      await ref.read(autoTaskNotifierProvider.notifier).deleteTask(task.id);
      if (context.mounted) {
        await ref.read(autoTaskNotifierProvider.notifier).createTask(result);
        _resyncScheduler();
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('已更新任务: ${result.name}')),
          );
        }
      }
    }
  }

  // ===== [UI-fix v2.0.3 | 2026-08-06] 导入/导出/帮助（对标原版
  // AutoTaskActivity 菜单） — Qoder =====

  void _snack(BuildContext context, String msg) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg)));
  }

  /// 导入本地任务文件（txt/json，对标 menu_import_local）
  Future<void> _importLocal(BuildContext context) async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['txt', 'json'],
      );
      final path = result?.files.single.path;
      if (path == null) return;
      final raw = await File(path).readAsString();
      if (context.mounted) {
        await _importFromRaw(context, raw, '本地文件');
      }
    } catch (e) {
      if (context.mounted) _snack(context, '读取文件失败: $e');
    }
  }

  /// 线上导入对话框（URL，对标 menu_import_on_line）
  void _showImportOnlineDialog(BuildContext context) {
    final ctrl = TextEditingController();
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('导入线上任务'),
        content: TextField(
          controller: ctrl,
          decoration: const InputDecoration(
            labelText: 'URL',
            hintText: 'https://example.com/autoTask.json',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              final url = ctrl.text.trim();
              Navigator.pop(dialogContext);
              if (url.isEmpty) return;
              _importOnline(context, url);
            },
            child: const Text('导入'),
          ),
        ],
      ),
    );
  }

  /// 线上导入（对标 ImportAutoTaskDialog 网络分支）
  Future<void> _importOnline(BuildContext context, String url) async {
    _snack(context, '正在获取任务配置…');
    try {
      final resp = await http.get(Uri.parse(url)).timeout(
            const Duration(seconds: 15),
          );
      if (resp.statusCode != 200) {
        if (context.mounted) {
          _snack(context, '下载失败: HTTP ${resp.statusCode}');
        }
        return;
      }
      if (context.mounted) {
        await _importFromRaw(context, resp.body, '线上');
      }
    } catch (e) {
      if (context.mounted) _snack(context, '下载失败: $e');
    }
  }

  /// 解析导入 JSON → 经 FFI 合并（autoTaskPrepareImported）→ 确认后入库
  Future<void> _importFromRaw(
    BuildContext context,
    String raw,
    String source,
  ) async {
    List<Map<String, dynamic>> imported;
    try {
      final decoded = jsonDecode(raw);
      final list = decoded is List ? decoded : [decoded];
      imported = list
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
    } catch (_) {
      _snack(context, '导入失败：JSON 格式无效');
      return;
    }
    if (imported.isEmpty) {
      _snack(context, '导入失败：未找到任务数据');
      return;
    }

    final notifier = ref.read(autoTaskNotifierProvider.notifier);
    final localTasks = ref
        .read(autoTaskNotifierProvider)
        .tasks
        .map((t) => t.toJson())
        .toList();
    // FFI 合并（合并本地运行时状态）；不可用时退化为原始解析结果
    final merged = await notifier.prepareImportedTasks(
      localTasks: localTasks,
      importedJson: raw,
    );
    // [UI-fix v2.0.2 | 2026-08-06] 空 id 补充拼接循环下标，避免同一循环内
    // microsecondsSinceEpoch 重复导致 id 碰撞 — Qoder
    final validTasks = (merged ?? imported)
        .map(AutoTask.fromJson)
        .where((t) => t.name.isNotEmpty)
        .toList();
    final baseId = DateTime.now().microsecondsSinceEpoch;
    final newTasks = <AutoTask>[
      for (var i = 0; i < validTasks.length; i++)
        validTasks[i].id.isEmpty
            ? validTasks[i].copyWith(id: '${baseId}_$i')
            : validTasks[i],
    ];
    if (newTasks.isEmpty) {
      if (!context.mounted) return;
      _snack(context, '导入失败：任务数据无效');
      return;
    }

    if (!context.mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('导入任务'),
        content: Text('从$source发现 ${newTasks.length} 个任务，是否导入？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('导入'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    var count = 0;
    for (final task in newTasks) {
      try {
        await notifier.createTask(task);
        count++;
      } catch (_) {
        // 单条失败不阻断整体导入
      }
    }
    _resyncScheduler();
    if (context.mounted) _snack(context, '已导入 $count 个任务');
  }

  /// 导出任务（对标 menu_export → exportAutoTask.json）
  Future<void> _exportTasks(BuildContext context) async {
    final tasks = ref.read(autoTaskNotifierProvider).tasks;
    if (tasks.isEmpty) {
      _snack(context, '暂无任务可导出');
      return;
    }
    final json = jsonEncode(tasks.map((t) => t.toJson()).toList());
    try {
      // 优先让用户选择保存位置（桌面/移动端支持）
      final savePath = await FilePicker.platform.saveFile(
        dialogTitle: '导出定时任务',
        fileName: 'exportAutoTask.json',
      );
      if (savePath != null) {
        await File(savePath).writeAsString(json);
        if (context.mounted) _snack(context, '已导出到: $savePath');
        return;
      }
      // 平台不支持保存对话框：写入文档目录并走系统分享
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/exportAutoTask.json');
      await file.writeAsString(json);
      await Share.shareXFiles([XFile(file.path)], subject: '导出定时任务');
    } catch (e) {
      if (context.mounted) _snack(context, '导出失败: $e');
    }
  }

  /// 帮助对话框（对标 menu_help → autoTaskHelp）
  void _showHelpDialog(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('定时任务帮助'),
        content: const SingleChildScrollView(
          child: Text(
            '• 支持三种任务：刷新目录、更新书源、自动备份\n'
            '• cron 表达式为标准 5 位格式：分 时 日 月 周\n'
            '  例：0 8 * * *（每天 8:00）、0 */6 * * *（每 6 小时）\n'
            '• 开关可随时通过列表项右侧切换\n'
            '• 长按任务可立即运行、编辑或删除\n'
            '• 可通过菜单导入本地/线上任务文件（txt/json），'
            '或导出全部任务备份',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }

  /// 确认删除
  void _confirmDelete(
      BuildContext context, AutoTaskNotifier provider, AutoTask task) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除任务'),
        content: Text('确定要删除任务「${task.name}」吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(ctx);
              provider.deleteTask(task.id).then((_) => _resyncScheduler());
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('已删除任务: ${task.name}')),
              );
            },
            child: const Text('删除'),
          ),
        ],
      ),
    );
  }
}
