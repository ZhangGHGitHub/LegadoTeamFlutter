import 'package:flutter/foundation.dart';

/// 定时任务模型
class AutoTask {
  final String id;
  final String name;
  final String taskType; // refreshToc, updateSources, backup
  final String cron; // cron 表达式
  final bool isEnabled;
  final String? lastRunAt;
  final String? lastResult;

  const AutoTask({
    required this.id,
    required this.name,
    required this.taskType,
    required this.cron,
    this.isEnabled = true,
    this.lastRunAt,
    this.lastResult,
  });

  /// 从 JSON 构建
  factory AutoTask.fromJson(Map<String, dynamic> json) {
    return AutoTask(
      id: json['id'] as String? ?? '',
      name: json['name'] as String? ?? '',
      taskType: json['taskType'] as String? ?? '',
      cron: json['cron'] as String? ?? '',
      isEnabled: json['isEnabled'] as bool? ?? true,
      lastRunAt: json['lastRunAt'] as String?,
      lastResult: json['lastResult'] as String?,
    );
  }

  /// 转为 JSON
  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'taskType': taskType,
        'cron': cron,
        'isEnabled': isEnabled,
        'lastRunAt': lastRunAt,
        'lastResult': lastResult,
      };

  /// 复制并修改
  AutoTask copyWith({
    String? id,
    String? name,
    String? taskType,
    String? cron,
    bool? isEnabled,
    String? lastRunAt,
    String? lastResult,
  }) {
    return AutoTask(
      id: id ?? this.id,
      name: name ?? this.name,
      taskType: taskType ?? this.taskType,
      cron: cron ?? this.cron,
      isEnabled: isEnabled ?? this.isEnabled,
      lastRunAt: lastRunAt ?? this.lastRunAt,
      lastResult: lastResult ?? this.lastResult,
    );
  }

  /// 任务类型显示名称
  String get taskTypeLabel {
    switch (taskType) {
      case 'refreshToc':
        return '刷新目录';
      case 'updateSources':
        return '更新书源';
      case 'backup':
        return '自动备份';
      default:
        return taskType;
    }
  }
}

/// 定时任务 Provider
class AutoTaskProvider extends ChangeNotifier {
  List<AutoTask> _tasks = [];
  bool _isLoading = false;
  String? _error;

  List<AutoTask> get tasks => _tasks;
  bool get isLoading => _isLoading;
  String? get error => _error;

  /// 加载所有定时任务
  Future<void> loadTasks() async {
    _isLoading = true;
    _error = null;
    notifyListeners();

    try {
      // TODO: 从 Rust FFI 加载任务列表
      // final result = await rustApi.getAutoTasks();
      // 模拟数据用于 UI 开发
      await Future.delayed(const Duration(milliseconds: 300));
      _tasks = [
        const AutoTask(
          id: '1',
          name: '每日刷新目录',
          taskType: 'refreshToc',
          cron: '0 8 * * *',
          isEnabled: true,
          lastRunAt: '2025-01-01 08:00:00',
          lastResult: '成功',
        ),
        const AutoTask(
          id: '2',
          name: '每周备份',
          taskType: 'backup',
          cron: '0 2 * * 0',
          isEnabled: true,
          lastRunAt: '2024-12-29 02:00:00',
          lastResult: '成功',
        ),
        const AutoTask(
          id: '3',
          name: '更新书源',
          taskType: 'updateSources',
          cron: '0 3 1 * *',
          isEnabled: false,
        ),
      ];
    } catch (e) {
      _error = '加载任务失败: $e';
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  /// 创建新任务
  Future<void> createTask(AutoTask task) async {
    try {
      // TODO: 调用 Rust FFI 创建任务
      await Future.delayed(const Duration(milliseconds: 200));
      _tasks = [..._tasks, task];
      notifyListeners();
    } catch (e) {
      _error = '创建任务失败: $e';
      notifyListeners();
    }
  }

  /// 切换任务启用状态
  Future<void> toggleTask(String id, bool enabled) async {
    try {
      // TODO: 调用 Rust FFI 更新任务
      await Future.delayed(const Duration(milliseconds: 100));
      _tasks = _tasks.map((t) {
        if (t.id == id) return t.copyWith(isEnabled: enabled);
        return t;
      }).toList();
      notifyListeners();
    } catch (e) {
      _error = '更新任务失败: $e';
      notifyListeners();
    }
  }

  /// 删除任务
  Future<void> deleteTask(String id) async {
    try {
      // TODO: 调用 Rust FFI 删除任务
      await Future.delayed(const Duration(milliseconds: 100));
      _tasks = _tasks.where((t) => t.id != id).toList();
      notifyListeners();
    } catch (e) {
      _error = '删除任务失败: $e';
      notifyListeners();
    }
  }

  /// 立即运行任务
  Future<void> runNow(String id) async {
    try {
      // TODO: 调用 Rust FFI 立即运行任务
      await Future.delayed(const Duration(milliseconds: 500));
      _tasks = _tasks.map((t) {
        if (t.id == id) {
          return t.copyWith(
            lastRunAt: DateTime.now().toString().substring(0, 19),
            lastResult: '成功',
          );
        }
        return t;
      }).toList();
      notifyListeners();
    } catch (e) {
      _error = '运行任务失败: $e';
      notifyListeners();
    }
  }
}
