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
import '../providers/providers.dart';
import '../services/auto_task_scheduler.dart';
import '../widgets/auto_task_debug_dialog.dart';

/// 定时任务管理页面
class AutoTaskScreen extends ConsumerStatefulWidget {
  /// 待编辑任务 ID（路由参数 Map {'editTaskId': String} 传入；
  /// [Task #39 §5.11-2] 书籍详情页「创建书籍更新任务」已存在时定位编辑）
  final String? initialEditTaskId;

  /// 待新建的默认任务（路由参数 Map {'newTask': Map} 传入，完整
  /// AutoTaskRule JSON，由 buildBookUpdateTask 构建）
  final Map<String, dynamic>? initialNewTask;

  const AutoTaskScreen({
    super.key,
    this.initialEditTaskId,
    this.initialNewTask,
  });

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
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await ref.read(autoTaskNotifierProvider.notifier).loadTasks();
      if (!mounted) return;
      // [Task #39 §5.11-2] 列表就绪后处理路由参数意图（编辑/新建） — Qoder
      await _handleInitialIntent();
    });
  }

  /// 处理路由参数意图（仅首帧后执行一次）
  Future<void> _handleInitialIntent() async {
    final editId = widget.initialEditTaskId;
    if (editId != null && editId.isNotEmpty) {
      await _openEditForTaskId(editId);
      return;
    }
    final newTask = widget.initialNewTask;
    if (newTask != null && newTask.isNotEmpty) {
      await _showBookUpdateTaskDialog(
        Map<String, dynamic>.from(newTask),
        isNew: true,
      );
    }
  }

  /// 按任务 ID 定位并进入编辑（[Task #39 §5.11-2]）
  ///
  /// 从 DB 读完整规则 JSON（保留 script 中的书籍更新 action）。
  /// [fix Task#45 | 2026-08-09] raw 缺失时不再退化到模型化编辑：
  /// 该路径经 deleteTask+createTask(AutoTask) 会用占位脚本覆盖真实
  /// script，改为提示稍后重试；任务不存在时照常提示 — Qoder
  Future<void> _openEditForTaskId(String taskId) async {
    Map<String, dynamic>? raw;
    var listFailed = false;
    try {
      final rules = await ref.read(bookApiProvider).autoTaskListRules();
      raw = rules.where((r) => r['id']?.toString() == taskId).firstOrNull;
    } catch (_) {
      // FFI 不可用：标记读取失败，不走模型化编辑避免洗掉 script
      listFailed = true;
    }
    if (!mounted) return;
    if (raw != null) {
      await _showBookUpdateTaskDialog(raw, isNew: false);
      return;
    }
    final exists = ref
        .read(autoTaskNotifierProvider)
        .tasks
        .any((t) => t.id == taskId);
    if (exists || listFailed) {
      if (mounted) _snack(context, '暂时无法编辑该任务，请稍后重试');
    } else if (mounted) {
      _snack(context, '未找到对应的定时任务');
    }
  }

  /// 书籍更新任务创建/编辑对话框（[Task #39 §5.11-2]，对齐原版
  /// AutoTaskEditActivity 核心字段：任务名 + cron 表达式）
  ///
  /// [rule] 为完整 AutoTaskRule JSON（script 含指向具体书籍的
  /// refreshToc action）；保存时仅回写 name/cron，其余字段原样保留，
  /// 避免经 [AutoTask] 模型中转丢失更新动作。
  ///
  /// [Task #54 | 2026-08-10] 缺陷②修复：对话框提取为自持 StatefulWidget
  /// （_BookUpdateTaskDialog），controller 在 State 内创建/dispose 中释放，
  /// 确认回传值而非 controller，消除退场动画期间 dispose 引发的
  /// 框架断言红屏；保留任务名非空与 cron 合法性校验（errorText 回显） — Qoder
  Future<void> _showBookUpdateTaskDialog(
    Map<String, dynamic> rule, {
    required bool isNew,
  }) async {
    // [fix Task#45 | 2026-08-09] 确认时校验 cron（Med1）：非法时
    // 阻止关闭对话框并经 errorText 提示 — Qoder
    final confirmed = await showDialog<_BookUpdateTaskDialogResult>(
      context: context,
      builder: (_) => _BookUpdateTaskDialog(
        initialName: (rule['name'] ?? '').toString(),
        initialCron: (rule['cron'] ?? '').toString(),
        isNew: isNew,
        cronValidator: _isCronValid,
      ),
    );
    if (confirmed == null || !mounted) return;
    // 仅回写 name/cron，script 等其余字段原样保留
    final updated = Map<String, dynamic>.from(rule)
      ..['name'] = confirmed.name
      ..['cron'] = confirmed.cron;
    // [fix Task#45 | 2026-08-09] 按 Raw 返回值提示（M6）：失败时
    // 不再误报成功，且不重同步调度器 — Qoder
    final notifier = ref.read(autoTaskNotifierProvider.notifier);
    final ok = isNew
        ? await notifier.createTaskRaw(jsonEncode(updated))
        : await notifier.updateTaskRaw(jsonEncode(updated));
    if (!mounted) return;
    if (ok) {
      _resyncScheduler();
      if (mounted) {
        _snack(context, isNew ? '已创建任务: ${confirmed.name}' : '已更新任务: ${confirmed.name}');
      }
    } else if (mounted) {
      _snack(context, '保存失败');
    }
  }

  /// cron 合法性校验（[fix Task#45 | 2026-08-09] Med1）
  ///
  /// 优先复用 notifier.nextDueAt：FFI 返回非 -1 即合法；FFI 不可用
  /// （返回 null）时退化为 5 段非空基础校验 — Qoder
  Future<bool> _isCronValid(String cron) async {
    if (cron.isEmpty) return false;
    final due = await ref
        .read(autoTaskNotifierProvider.notifier)
        .nextDueAt(cron: cron);
    if (due != null) return due != -1;
    final parts = cron.split(RegExp(r'\s+'));
    return parts.length == 5 && parts.every((p) => p.isNotEmpty);
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
            // P2-7：调试（对标原版 AutoTaskDebugActivity）
            ListTile(
              leading: const Icon(Icons.bug_report_outlined),
              title: const Text('调试'),
              subtitle: const Text('执行并查看结果日志'),
              onTap: () {
                Navigator.pop(ctx);
                _openTaskDebug(context, task);
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

  /// P2-7：最小调试屏（对标 AutoTaskDebugActivity）
  Future<void> _openTaskDebug(BuildContext context, AutoTask task) async {
    await showDialog<void>(
      context: context,
      builder: (_) => AutoTaskDebugDialog(task: task),
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

/// 书籍更新任务对话框确认结果（回传值而非 controller）
/// [Task #54 | 2026-08-10] — Qoder
class _BookUpdateTaskDialogResult {
  final String name;
  final String cron;

  const _BookUpdateTaskDialogResult({required this.name, required this.cron});
}

/// 书籍更新任务编辑/创建对话框（自持 StatefulWidget，照
/// source_screen._TextPromptDialog 模式）：controller 在 State 内创建、
/// dispose 中随子树卸载统一释放，避免 Navigator.pop 后立即 dispose
/// 在退场动画期间触发 framework.dart _dependents.isEmpty 断言红屏。
/// [Task #54 | 2026-08-10] — Qoder
class _BookUpdateTaskDialog extends StatefulWidget {
  final String initialName;
  final String initialCron;
  final bool isNew;

  /// cron 合法性异步校验（由页面传入，复用 _isCronValid）
  final Future<bool> Function(String cron) cronValidator;

  const _BookUpdateTaskDialog({
    required this.initialName,
    required this.initialCron,
    required this.isNew,
    required this.cronValidator,
  });

  @override
  State<_BookUpdateTaskDialog> createState() => _BookUpdateTaskDialogState();
}

class _BookUpdateTaskDialogState extends State<_BookUpdateTaskDialog> {
  late final TextEditingController _nameController =
      TextEditingController(text: widget.initialName);
  late final TextEditingController _cronController =
      TextEditingController(text: widget.initialCron);

  /// cron 校验错误回显（[fix Task#45] Med1）
  String? _cronError;

  /// 防重复提交（cron 校验为异步 FFI）
  bool _validating = false;

  @override
  void dispose() {
    _nameController.dispose();
    _cronController.dispose();
    super.dispose();
  }

  Future<void> _onConfirm() async {
    // 任务名非空校验：为空时不关闭对话框
    if (_nameController.text.trim().isEmpty) return;
    if (_validating) return;
    setState(() => _validating = true);
    final cronText = _cronController.text.trim();
    final valid = await widget.cronValidator(cronText);
    if (!mounted) return;
    if (!valid) {
      setState(() {
        _validating = false;
        _cronError = 'Cron 表达式无效，请检查格式';
      });
      return;
    }
    Navigator.pop(
      context,
      _BookUpdateTaskDialogResult(
        name: _nameController.text.trim(),
        cron: cronText,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.isNew ? '创建书籍更新任务' : '编辑书籍更新任务'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '到期后自动刷新该书目录并提示更新',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _nameController,
              decoration: const InputDecoration(
                labelText: '任务名称',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _cronController,
              onChanged: (_) {
                if (_cronError != null) {
                  setState(() => _cronError = null);
                }
              },
              decoration: InputDecoration(
                labelText: 'Cron 表达式',
                hintText: '*/30 * * * *',
                border: const OutlineInputBorder(),
                helperText: '标准5位 cron 表达式（分 时 日 月 周）',
                errorText: _cronError,
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _validating ? null : _onConfirm,
          child: Text(widget.isNew ? '创建' : '保存'),
        ),
      ],
    );
  }
}
