import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../services/book_api.dart';

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
/// 优先通过 Rust FFI 调用 auto_task_api，FFI 失败时降级到 legado-server REST API：
/// - GET    /api/auto-tasks         — 列表
/// - POST   /api/auto-tasks         — 创建
/// - PUT    /api/auto-tasks/:id     — 更新
/// - DELETE /api/auto-tasks/:id     — 删除
/// - POST   /api/auto-tasks/:id/run — 立即执行（FFI 优先）
class AutoTaskProvider extends ChangeNotifier {
  static const String _baseUrl = 'http://127.0.0.1:8080/api/auto-tasks';
  static const Duration _timeout = Duration(seconds: 5);

  final http.Client _client;
  final BookApi? _rustApi;

  AutoTaskProvider({http.Client? client, BookApi? rustApi})
      : _client = client ?? http.Client(),
        _rustApi = rustApi;

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
  ///
  /// 优先通过 Rust FFI 执行（autoTaskExecuteWithId），失败时降级到 REST。
  Future<void> runNow(String id) async {
    // 尝试 FFI 路径
    if (_rustApi != null) {
      try {
        final task = _tasks.where((t) => t.id == id).firstOrNull;
        final protocolJson = jsonEncode({
          'action': task?.taskType ?? 'noop',
          'taskId': id,
        });
        final result = await _rustApi.autoTaskExecuteWithId(
          protocolJson: protocolJson,
          taskId: id,
        );
        // FFI 执行成功，更新本地状态
        final success = result['success'] as bool? ?? false;
        _tasks = _tasks.map((t) {
          if (t.id == id) {
            return t.copyWith(
              lastRunAt: _formatNow(),
              lastResult: success ? '成功' : '失败',
            );
          }
          return t;
        }).toList();
        notifyListeners();
        return;
      } catch (_) {
        // FFI 失败，降级到 REST
      }
    }

    // REST 降级路径
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

  /// 格式化当前时间为 'yyyy-MM-dd HH:mm:ss'
  String _formatNow() {
    final dt = DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${dt.year}-${two(dt.month)}-${two(dt.day)} '
        '${two(dt.hour)}:${two(dt.minute)}:${two(dt.second)}';
  }

  // ========== FFI 新增方法（无 REST 等价物） ==========

  /// 构建书籍更新定时任务（FFI）
  ///
  /// 返回构建好的 AutoTaskRule Map，可直接用于 createTask。
  Future<Map<String, dynamic>?> buildBookUpdateTask({
    required String bookUrl,
    required String bookName,
    required String bookAuthor,
    required String name,
  }) async {
    if (_rustApi == null) return null;
    try {
      return await _rustApi.autoTaskBuildBookUpdateTask(
        bookUrl: bookUrl,
        bookName: bookName,
        bookAuthor: bookAuthor,
        name: name,
      );
    } catch (_) {
      return null;
    }
  }

  /// 批量更新 cron 表达式（FFI）
  ///
  /// 返回更新后的规则数组，失败返回 null。
  Future<List<Map<String, dynamic>>?> updateCronBatch({
    required List<Map<String, dynamic>> rules,
    required List<String> ids,
    required String cron,
  }) async {
    if (_rustApi == null) return null;
    try {
      return await _rustApi.autoTaskUpdateCronBatch(
        rulesJson: jsonEncode(rules),
        idsJson: jsonEncode(ids),
        cron: cron,
      );
    } catch (_) {
      return null;
    }
  }

  /// 准备导入任务（FFI，合并本地运行时状态）
  Future<List<Map<String, dynamic>>?> prepareImportedTasks({
    required List<Map<String, dynamic>> localTasks,
    required String importedJson,
  }) async {
    if (_rustApi == null) return null;
    try {
      return await _rustApi.autoTaskPrepareImported(
        localTasksJson: jsonEncode(localTasks),
        importedJson: importedJson,
      );
    } catch (_) {
      return null;
    }
  }

  /// 规范化脚本（FFI，去除 `@js:` 前缀或 `<js></js>` 包裹）
  Future<String?> normalizeScript(String script) async {
    if (_rustApi == null) return null;
    try {
      return await _rustApi.autoTaskNormalizeScript(script: script);
    } catch (_) {
      return null;
    }
  }

  /// 判断书籍是否允许刷新目录（FFI）
  Future<bool?> canRefreshBookToc({
    required bool canUpdate,
    required bool respectCanUpdate,
  }) async {
    if (_rustApi == null) return null;
    try {
      return await _rustApi.autoTaskCanRefreshBookToc(
        canUpdate: canUpdate,
        respectCanUpdate: respectCanUpdate,
      );
    } catch (_) {
      return null;
    }
  }

  /// 查找书籍更新任务（FFI）
  ///
  /// 优先按 ID 精确匹配，其次按书名 + 作者匹配。未找到返回 null。
  Future<Map<String, dynamic>?> findBookUpdateTask({
    required String bookUrl,
    required String bookName,
    required String bookAuthor,
  }) async {
    if (_rustApi == null) return null;
    try {
      final tasksJson = jsonEncode(_tasks.map((t) => t.toJson()).toList());
      return await _rustApi.autoTaskFindBookUpdateTask(
        tasksJson: tasksJson,
        bookUrl: bookUrl,
        bookName: bookName,
        bookAuthor: bookAuthor,
      );
    } catch (_) {
      return null;
    }
  }

  /// 解析 cron 表达式计算下次执行时间（FFI，Unix 毫秒）
  ///
  /// 无法解析时返回 -1。
  Future<int?> nextDueAt({
    required String cron,
    int? fromMs,
  }) async {
    if (_rustApi == null) return null;
    try {
      return await _rustApi.autoTaskNextDueAt(
        cron: cron,
        fromMs: fromMs ?? DateTime.now().millisecondsSinceEpoch,
      );
    } catch (_) {
      return null;
    }
  }

  /// 判断是否为连接类错误（服务端未运行 / 网络不可达）
  bool _isConnectionError(Object e) {
    return e is SocketException ||
        e is HttpException ||
        e is TimeoutException;
  }
}
