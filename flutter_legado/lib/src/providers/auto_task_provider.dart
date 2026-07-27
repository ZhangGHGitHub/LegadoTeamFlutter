import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

/// 定时任务模型
///
/// 与 legado-server 的 `AutoTaskRule` 结构对应。服务端字段使用
/// `enable` / `cron` / `comment` / `lastRunAt`（毫秒时间戳）等命名，
/// 这里在 [fromJson] / [toJson] 中做双向兼容：
/// - `isEnabled` ↔ `enable`
/// - `taskType`  ↔ `comment`（服务端无 taskType 字段，借用 comment 保存）
/// - `lastRunAt` 服务端返回毫秒时间戳（int），UI 展示为格式化字符串
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

  /// 从 JSON 构建（兼容 Dart 风格与服务端 AutoTaskRule 风格字段）
  factory AutoTask.fromJson(Map<String, dynamic> json) {
    return AutoTask(
      id: json['id']?.toString() ?? '',
      name: json['name'] as String? ?? '',
      taskType:
          json['taskType'] as String? ?? json['comment'] as String? ?? '',
      cron: json['cron'] as String? ?? '',
      isEnabled:
          json['isEnabled'] as bool? ?? json['enable'] as bool? ?? true,
      lastRunAt: _parseLastRunAt(json['lastRunAt']),
      lastResult: json['lastResult'] as String?,
    );
  }

  /// 解析 lastRunAt：服务端返回毫秒时间戳（int），也可能是字符串
  static String? _parseLastRunAt(dynamic value) {
    if (value is int) {
      return value > 0 ? _formatMillis(value) : null;
    }
    if (value is num) {
      return value > 0 ? _formatMillis(value.toInt()) : null;
    }
    if (value is String && value.isNotEmpty) {
      return value;
    }
    return null;
  }

  /// 毫秒时间戳格式化为 'yyyy-MM-dd HH:mm:ss'
  static String _formatMillis(int millis) {
    final dt = DateTime.fromMillisecondsSinceEpoch(millis);
    String two(int n) => n.toString().padLeft(2, '0');
    return '${dt.year}-${two(dt.month)}-${two(dt.day)} '
        '${two(dt.hour)}:${two(dt.minute)}:${two(dt.second)}';
  }

  /// 转为 JSON（服务端 AutoTaskRule 兼容格式）
  ///
  /// 服务端 run 端点要求 `script` 非空，按任务类型生成占位脚本。
  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'enable': isEnabled,
        'cron': cron,
        'comment': taskType,
        'script': _defaultScript,
      };

  /// 按任务类型生成占位脚本（服务端校验非空即视为可执行）
  String get _defaultScript {
    switch (taskType) {
      case 'refreshToc':
        return 'refreshToc()';
      case 'updateSources':
        return 'updateSources()';
      case 'backup':
        return 'backup()';
      default:
        return taskType.isEmpty ? 'noop()' : taskType;
    }
  }

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
///
/// 通过 HTTP 调用 legado-server 的 REST API（`/api/auto-tasks`）：
/// - GET    /api/auto-tasks         — 列表
/// - POST   /api/auto-tasks         — 创建
/// - PUT    /api/auto-tasks/:id     — 更新
/// - DELETE /api/auto-tasks/:id     — 删除
/// - POST   /api/auto-tasks/:id/run — 立即执行
class AutoTaskProvider extends ChangeNotifier {
  static const String _baseUrl = 'http://127.0.0.1:8080/api/auto-tasks';
  static const Duration _timeout = Duration(seconds: 5);

  final http.Client _client;

  AutoTaskProvider({http.Client? client}) : _client = client ?? http.Client();

  List<AutoTask> _tasks = [];
  bool _isLoading = false;
  String? _error;

  List<AutoTask> get tasks => _tasks;
  bool get isLoading => _isLoading;
  String? get error => _error;

  @override
  void dispose() {
    _client.close();
    super.dispose();
  }

  /// 加载所有定时任务
  ///
  /// [silent] 为 true 时不触发 loading 状态（用于增删改后的静默刷新）。
  /// 若服务端未运行（连接失败），使用空列表而不报错。
  Future<void> loadTasks({bool silent = false}) async {
    if (!silent) {
      _isLoading = true;
      _error = null;
      notifyListeners();
    }

    try {
      final response =
          await _client.get(Uri.parse(_baseUrl)).timeout(_timeout);
      if (response.statusCode == 200) {
        _tasks = _parseTaskList(response.body);
        _error = null;
      } else {
        _tasks = [];
        _error = '加载任务失败: HTTP ${response.statusCode}';
      }
    } catch (e) {
      // 服务端未运行或网络不可达时，回退为空列表
      _tasks = [];
      _error = _isConnectionError(e) ? null : '加载任务失败: $e';
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  /// 解析任务列表响应
  ///
  /// 服务端返回 `{ "tasks": [...], "total": n }`，兼容直接返回数组的情况。
  List<AutoTask> _parseTaskList(String body) {
    final decoded = jsonDecode(body);
    List<dynamic> list;
    if (decoded is Map && decoded['tasks'] is List) {
      list = decoded['tasks'] as List;
    } else if (decoded is List) {
      list = decoded;
    } else {
      list = const [];
    }
    return list
        .whereType<Map<String, dynamic>>()
        .map(AutoTask.fromJson)
        .toList();
  }

  /// 创建新任务
  Future<void> createTask(AutoTask task) async {
    try {
      final response = await _client
          .post(
            Uri.parse(_baseUrl),
            headers: const {'Content-Type': 'application/json'},
            body: jsonEncode(task.toJson()),
          )
          .timeout(_timeout);
      if (response.statusCode != 200 && response.statusCode != 201) {
        throw HttpException('HTTP ${response.statusCode}');
      }
      await loadTasks(silent: true);
    } catch (e) {
      _error = '创建任务失败: $e';
      notifyListeners();
    }
  }

  /// 切换任务启用状态
  Future<void> toggleTask(String id, bool enabled) async {
    // 乐观更新，失败时回滚
    final previous = _tasks;
    _tasks = _tasks.map((t) {
      if (t.id == id) return t.copyWith(isEnabled: enabled);
      return t;
    }).toList();
    notifyListeners();

    try {
      final response = await _client
          .put(
            Uri.parse('$_baseUrl/$id'),
            headers: const {'Content-Type': 'application/json'},
            body: jsonEncode({'enable': enabled}),
          )
          .timeout(_timeout);
      if (response.statusCode != 200) {
        throw HttpException('HTTP ${response.statusCode}');
      }
      await loadTasks(silent: true);
    } catch (e) {
      _tasks = previous;
      _error = '更新任务失败: $e';
      notifyListeners();
    }
  }

  /// 删除任务
  Future<void> deleteTask(String id) async {
    try {
      final response =
          await _client.delete(Uri.parse('$_baseUrl/$id')).timeout(_timeout);
      if (response.statusCode != 200) {
        throw HttpException('HTTP ${response.statusCode}');
      }
      await loadTasks(silent: true);
    } catch (e) {
      _error = '删除任务失败: $e';
      notifyListeners();
    }
  }

  /// 立即运行任务
  Future<void> runNow(String id) async {
    try {
      final response = await _client
          .post(Uri.parse('$_baseUrl/$id/run'))
          .timeout(_timeout);
      if (response.statusCode != 200) {
        throw HttpException('HTTP ${response.statusCode}');
      }
      // 服务端会更新 lastRunAt / lastResult，重新拉取以同步状态
      await loadTasks(silent: true);
    } catch (e) {
      _error = '运行任务失败: $e';
      notifyListeners();
    }
  }

  /// 判断是否为连接类错误（服务端未运行 / 网络不可达）
  bool _isConnectionError(Object e) {
    return e is SocketException ||
        e is HttpException ||
        e is TimeoutException;
  }
}
