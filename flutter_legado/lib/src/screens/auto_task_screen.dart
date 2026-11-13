import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import '../widgets/app_scaffold.dart';
import '../widgets/legado_app_bar.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;

import '../providers/auto_task/auto_task_notifier.dart';
import '../providers/providers.dart';
import '../services/bridge_http.dart';
import '../services/auto_task_scheduler.dart';
import '../services/source_share_passphrase.dart';
import '../widgets/auto_task_debug_dialog.dart';
import '../widgets/custom_refresh_indicator.dart';
import '../widgets/export_file_sheet.dart';
import '../widgets/help/help_assets.dart';
import '../widgets/help/show_help.dart';
import '../widgets/passphrase_import.dart';
import '../utils/error_message.dart';

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
    // [GLOBALCOMP B4] 页壳统一：AppScaffold（行为等价直通 Scaffold）
    return AppScaffold(
      topBar: LegadoAppBar(
        title: const Text('定时任务'),
        // [UI-fix v2.0.3 | 2026-08-06] 溢出菜单（对标原版 AutoTaskActivity
        // menu_import_local / menu_import_on_line / menu_export / menu_help）
        // — Qoder
        actions: [
          PopupMenuButton<String>(
            onSelected: (value) async {
              switch (value) {
                case 'import_local':
                  _importLocal(context);
                  break;
                case 'import_online':
                  _showImportOnlineDialog(context);
                  break;
                case 'import_passphrase':
                  await importPassphraseFromClipboard(context);
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
              PopupMenuItem(value: 'import_passphrase', child: Text('口令导入')),
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
                  Icon(Symbols.error_rounded,
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
                  Icon(Symbols.schedule_rounded, size: 64,
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

          // [LAYOUT_PLAN P4 收尾] 下拉 M3 化：裸 RefreshIndicator → CustomRefreshIndicator
          return CustomRefreshIndicator(
            onRefresh: () => notifier.loadTasks(),
            child: ListView.separated(
              // [LAYOUT_PLAN P3] 页面水平边距 16dp；纵向留白 8dp
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              itemCount: state.tasks.length,
              // [LAYOUT_PLAN P3] 分隔线走 tonal 舍 outlineVariant（对齐 file_manage/offline_cache 样板）
              separatorBuilder: (_, index) => Divider(
                height: 1,
                indent: 16,
                endIndent: 16,
              ),
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
        child: const Icon(Symbols.add_rounded),
      ),
    );
  }

  Widget _buildTaskTile(
      BuildContext context, AutoTaskNotifier provider, AutoTask task) {
    final IconData icon;
    switch (task.taskType) {
      case 'refreshToc':
        icon = Symbols.refresh_rounded;
        break;
      case 'updateSources':
        icon = Symbols.update_rounded;
        break;
      case 'backup':
        icon = Symbols.backup_rounded;
        break;
      default:
        icon = Symbols.schedule_rounded;
    }

    return ListTile(
      // [LAYOUT_PLAN P3] 组内行 vertical12/horizontal8
      contentPadding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
      leading: Icon(icon, color: Theme.of(context).colorScheme.primary),
      title: Text(
        task.name,
        // [LAYOUT_PLAN P3] 列表行标题走 titleSmall
        style: Theme.of(context).textTheme.titleSmall,
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 2),
          Row(
            children: [
              Icon(Symbols.schedule_rounded, size: 12,
                  color: Theme.of(context).colorScheme.onSurfaceVariant),
              const SizedBox(width: 4),
              Text('cron: ${task.cron}',
                  // [LAYOUT_PLAN P3] 列表行字级走 M3 Type Scale
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant)),
            ],
          ),
          if (task.lastRunAt != null) ...[
            const SizedBox(height: 2),
            Text('上次运行: ${task.lastRunAt} · ${task.lastResult ?? "未知"}',
                // [LAYOUT_PLAN P3] 列表行字级走 M3 Type Scale
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
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
          // [LAYOUT_PLAN P3] Dialog 容器 surfaceContainer 圆角 28dp（全局标尺，对齐 dialogTheme）
          backgroundColor: Theme.of(ctx).colorScheme.surfaceContainer,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(28),
          ),
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
                  ),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: taskType,
                  decoration: const InputDecoration(
                    labelText: '任务类型',
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
              // [LAYOUT_PLAN P3] 组内行 vertical12/horizontal8
              contentPadding:
                  const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
              leading: const Icon(Symbols.play_arrow_rounded),
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
              // [LAYOUT_PLAN P3] 组内行 vertical12/horizontal8
              contentPadding:
                  const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
              leading: const Icon(Symbols.bug_report_rounded),
              title: const Text('调试'),
              subtitle: const Text('执行并查看结果日志'),
              onTap: () {
                Navigator.pop(ctx);
                _openTaskDebug(context, task);
              },
            ),
            ListTile(
              // [LAYOUT_PLAN P3] 组内行 vertical12/horizontal8
              contentPadding:
                  const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
              leading: const Icon(Symbols.edit_rounded),
              title: const Text('编辑任务'),
              onTap: () {
                Navigator.pop(ctx);
                _showEditTaskDialog(context, task);
              },
            ),
            ListTile(
              // [LAYOUT_PLAN P3] 组内行 vertical12/horizontal8
              contentPadding:
                  const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
              leading: Icon(Symbols.delete_rounded, color: Theme.of(context).colorScheme.error),
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
          // [LAYOUT_PLAN P3] Dialog 容器 surfaceContainer 圆角 28dp（全局标尺，对齐 dialogTheme）
          backgroundColor: Theme.of(ctx).colorScheme.surfaceContainer,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(28),
          ),
          title: const Text('编辑定时任务'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: nameController,
                  decoration: const InputDecoration(
                    labelText: '任务名称',
                  ),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: taskType,
                  decoration: const InputDecoration(
                    labelText: '任务类型',
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
      if (context.mounted) _snack(context, '读取文件失败: ${errorMessage(e)}');
    }
  }

  /// 线上导入对话框（URL，对标 menu_import_on_line）
  void _showImportOnlineDialog(BuildContext context) {
    final ctrl = TextEditingController();
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        // [LAYOUT_PLAN P3] Dialog 容器 surfaceContainer 圆角 28dp（全局标尺，对齐 dialogTheme）
        backgroundColor: Theme.of(dialogContext).colorScheme.surfaceContainer,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(28),
        ),
        title: const Text('导入线上任务'),
        content: TextField(
          controller: ctrl,
          decoration: const InputDecoration(
            labelText: 'URL',
            hintText: 'https://example.com/autoTask.json',
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
      final api = ref.read(bookApiProvider);
      final resp = await bridgeHttpGet(
        api,
        url,
        timeout: const Duration(seconds: 15),
      );
      if (!resp.isSuccess) {
        if (context.mounted) {
          _snack(context, '下载失败: HTTP ${resp.statusCode}');
        }
        return;
      }
      if (context.mounted) {
        await _importFromRaw(context, resp.body, '线上');
      }
    } catch (e) {
      if (context.mounted) _snack(context, '下载失败: ${errorMessage(e)}');
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
    // P1-3 / P2-3 / P2-4：调用 FFI 前完成校验与 id 预生成。
    // - 空 id 条目在 Rust 合并中会被跳过 → 先补 id（混合批不再静默丢失）；
    // - cron 空白回退默认值、不可解析明确失败（对齐 validateImportedTask）；
    // - script 归一（去 @js:/<js>）后为空明确失败。
    final baseId = DateTime.now().microsecondsSinceEpoch;
    final errors = <String>[];
    final normalized = <Map<String, dynamic>>[];
    for (var i = 0; i < imported.length; i++) {
      final task = Map<String, dynamic>.of(imported[i]);
      final name = (task['name']?.toString() ?? '').trim();
      if (name.isEmpty) {
        errors.add('缺少任务名称');
        continue;
      }
      task['name'] = name;
      if ((task['id']?.toString() ?? '').trim().isEmpty) {
        task['id'] = '${baseId}_$i';
      }
      final cron = (task['cron']?.toString() ?? '').trim();
      final effectiveCron = cron.isEmpty ? '*/30 * * * *' : cron;
      task['cron'] = effectiveCron;
      final due = await notifier.nextDueAt(cron: effectiveCron);
      final cronValid = due == null ? _isFiveFieldCron(effectiveCron) : due != -1;
      if (!cronValid) {
        errors.add('「$name」请输入有效的五段 Cron 计划');
        continue;
      }
      final rawScript = task['script']?.toString() ?? '';
      final normalizedScript = await notifier.normalizeScript(rawScript);
      final script = (normalizedScript ?? rawScript).trim();
      if (script.isEmpty) {
        errors.add('「$name」请输入 JavaScript 任务脚本');
        continue;
      }
      task['script'] = normalizedScript ?? rawScript;
      normalized.add(task);
    }
    if (normalized.isEmpty) {
      if (!context.mounted) return;
      _snack(
        context,
        errors.isEmpty ? '导入失败：任务数据无效' : '导入失败：${errors.join('；')}',
      );
      return;
    }

    // FFI 合并（合并本地运行时状态）；不可用时退化为已归一结果
    final merged = await notifier.prepareImportedTasks(
      localTasks: localTasks,
      importedJson: jsonEncode(normalized),
    );
    final newTasks = <Map<String, dynamic>>[];
    for (final item in merged ?? normalized) {
      final task = Map<String, dynamic>.from(item);
      if ((task['name']?.toString() ?? '').trim().isEmpty) continue;
      if ((task['id']?.toString() ?? '').trim().isEmpty) {
        task['id'] = '${baseId}_m${newTasks.length}';
      }
      newTasks.add(task);
    }
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

    // [P2-8] 写入失败必须与「解析阶段无效任务」分开计数并展示原因；
    // createTaskRaw 失败时返回 false（不抛异常），旧实现只 catch 异常，
    // 导致 DB 写入失败被完全静默。
    final writeResult = await writeImportedAutoTasks(
      tasks: newTasks,
      create: notifier.createTaskRaw,
      lastError: () => ref.read(autoTaskNotifierProvider).error,
    );
    _resyncScheduler();
    if (context.mounted) {
      _snack(
        context,
        importTasksResultMessage(
          count: writeResult.count,
          parseErrors: errors.length,
          writeFailures: writeResult.failures,
        ),
      );
    }
  }

  /// 五段 cron 基础校验（FFI 不可用时的降级口径）
  bool _isFiveFieldCron(String cron) =>
      cron.split(RegExp(r'\s+')).where((p) => p.isNotEmpty).length == 5;

  /// 导出任务（批16e：接入统一导出目标 Sheet）
  ///
  /// 对齐原版 `AutoTaskActivity.kt:201-211`（menu_export →
  /// `AutoTask.exportJson()` → HandleFileContract.EXPORT），文件名
  /// `exportAutoTask.json`、`application/json`。
  ///
  /// 注：原版另有「选中导出」（`exportAutoTaskSelection.json`，见
  /// AutoTaskActivity.kt:324-334），本项目定时任务页尚无批量选择模式，
  /// 故本次只接入全部导出。
  Future<void> _exportTasks(BuildContext context) async {
    final tasks = ref.read(autoTaskNotifierProvider).tasks;
    if (tasks.isEmpty) {
      _snack(context, '暂无任务可导出');
      return;
    }
    final json = jsonEncode(tasks.map((t) => t.toJson()).toList());
    final result = await showExportFileSheet(
      context,
      content: json,
      fileName: 'exportAutoTask.json',
      subject: '导出定时任务',
      passphraseType: SourcePassphraseType.autoTask,
    );
    if (!context.mounted || result == null) return;
    _snack(context, result.message);
  }

  /// 帮助对话框（对标 menu_help → autoTaskHelp）
  void _showHelpDialog(BuildContext context) {
    showHelp(context, HelpAssets.autoTaskHelp);
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

/// [P2-8] 逐条写入导入任务，返回成功数与失败明细（`任务名：原因`）
///
/// `create` 返回 false 表示写入失败（[AutoTaskNotifier.createTaskRaw] 的
/// 契约是失败不抛异常，只写 error 状态并返回 false）；`lastError` 用于
/// 取回该状态里的可读原因。抽为顶层函数便于单测直接覆盖「部分写入失败
/// 不再静默」。
Future<({int count, List<String> failures})> writeImportedAutoTasks({
  required List<Map<String, dynamic>> tasks,
  required Future<bool> Function(String ruleJson) create,
  required String? Function() lastError,
}) async {
  var count = 0;
  final failures = <String>[];
  for (final task in tasks) {
    final name = (task['name']?.toString() ?? '').trim();
    final label = name.isEmpty ? '未命名任务' : name;
    try {
      if (await create(jsonEncode(task))) {
        count++;
        continue;
      }
      final reason = lastError()?.trim();
      failures.add(
        '$label：${reason == null || reason.isEmpty ? '写入失败' : reason}',
      );
    } catch (e) {
      failures.add('$label：${errorMessage(e)}');
    }
  }
  return (count: count, failures: failures);
}

/// [P2-8] 批量导入结果文案：成功数 / 解析无效数 / 写入失败数分列
///
/// 与压缩包导入同范式：失败只展开首条明细，其余汇总条数。
String importTasksResultMessage({
  required int count,
  required int parseErrors,
  required List<String> writeFailures,
}) {
  final parts = <String>[count == 0 ? '未导入任何任务' : '已导入 $count 个任务'];
  if (parseErrors > 0) {
    parts.add('跳过 $parseErrors 个无效任务');
  }
  if (writeFailures.isNotEmpty) {
    final more =
        writeFailures.length > 1 ? '（另有 ${writeFailures.length - 1} 个）' : '';
    parts.add('${writeFailures.length} 个写入失败：${writeFailures.first}$more');
  }
  return parts.join('，');
}
