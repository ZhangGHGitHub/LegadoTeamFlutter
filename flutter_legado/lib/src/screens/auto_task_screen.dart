import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/auto_task_provider.dart';

/// 定时任务管理页面
class AutoTaskScreen extends StatefulWidget {
  const AutoTaskScreen({super.key});

  @override
  State<AutoTaskScreen> createState() => _AutoTaskScreenState();
}

class _AutoTaskScreenState extends State<AutoTaskScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<AutoTaskProvider>().loadTasks();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('定时任务')),
      body: Consumer<AutoTaskProvider>(
        builder: (context, provider, _) {
          if (provider.isLoading) {
            return const Center(child: CircularProgressIndicator());
          }

          if (provider.error != null) {
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.error_outline,
                      size: 48, color: Theme.of(context).colorScheme.error),
                  const SizedBox(height: 8),
                  Text(provider.error!,
                      style: TextStyle(
                          color: Theme.of(context).colorScheme.error)),
                  const SizedBox(height: 16),
                  FilledButton(
                    onPressed: () => provider.loadTasks(),
                    child: const Text('重试'),
                  ),
                ],
              ),
            );
          }

          if (provider.tasks.isEmpty) {
            return const Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.schedule, size: 64, color: Colors.grey),
                  SizedBox(height: 8),
                  Text('暂无定时任务',
                      style: TextStyle(color: Colors.grey, fontSize: 16)),
                  SizedBox(height: 4),
                  Text('点击右下角按钮添加新任务',
                      style: TextStyle(color: Colors.grey, fontSize: 12)),
                ],
              ),
            );
          }

          return RefreshIndicator(
            onRefresh: () => provider.loadTasks(),
            child: ListView.separated(
              itemCount: provider.tasks.length,
              separatorBuilder: (_, index) => const Divider(height: 1),
              itemBuilder: (context, index) {
                final task = provider.tasks[index];
                return _buildTaskTile(context, provider, task);
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
      BuildContext context, AutoTaskProvider provider, AutoTask task) {
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
              const Icon(Icons.schedule, size: 12, color: Colors.grey),
              const SizedBox(width: 4),
              Text('cron: ${task.cron}',
                  style: const TextStyle(fontSize: 12, color: Colors.grey)),
            ],
          ),
          if (task.lastRunAt != null) ...[
            const SizedBox(height: 2),
            Text('上次运行: ${task.lastRunAt} · ${task.lastResult ?? "未知"}',
                style: const TextStyle(fontSize: 12, color: Colors.grey)),
          ],
        ],
      ),
      trailing: Switch(
        value: task.isEnabled,
        onChanged: (value) => provider.toggleTask(task.id, value),
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
      await context.read<AutoTaskProvider>().createTask(result);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('已添加任务: ${result.name}')),
        );
      }
    }
  }

  /// 显示任务操作菜单
  void _showTaskOptions(
      BuildContext context, AutoTaskProvider provider, AutoTask task) {
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
                provider.runNow(task.id);
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
      await context.read<AutoTaskProvider>().deleteTask(task.id);
      if (context.mounted) {
        await context.read<AutoTaskProvider>().createTask(result);
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('已更新任务: ${result.name}')),
          );
        }
      }
    }
  }

  /// 确认删除
  void _confirmDelete(
      BuildContext context, AutoTaskProvider provider, AutoTask task) {
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
              provider.deleteTask(task.id);
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
