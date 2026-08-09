import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide ChangeNotifierProvider;
import 'package:http/http.dart' as http;

import '../../services/book_api.dart';
import '../providers.dart';
import 'auto_task_state.dart';

export 'auto_task_state.dart';

/// 定时任务 Rust API 注入点
///
/// 生产环境由 [bookApiProvider] 提供；对齐旧 AutoTaskProvider 命名参数 `rustApi`
/// 的可空语义，测试可覆盖为 null 以验证纯 REST 降级 / FFI 缺失分支。
final autoTaskRustApiProvider =
    Provider<BookApi?>((ref) => ref.read(bookApiProvider));

/// 定时任务 REST 降级所用 HTTP 客户端注入点
///
/// 默认创建真实 http.Client，并在 Provider 释放时关闭（对齐旧实现 dispose）。
/// 测试可覆盖为 MockClient。
final autoTaskHttpClientProvider = Provider<http.Client>((ref) {
  final client = http.Client();
  ref.onDispose(client.close);
  return client;
});

/// 定时任务 Riverpod Notifier
///
/// 优先通过 Rust FFI 调用 auto_task_api，FFI 失败时降级到 legado-server REST API：
/// - GET    /api/auto-tasks         — 列表
/// - POST   /api/auto-tasks         — 创建
/// - PUT    /api/auto-tasks/:id     — 更新
/// - DELETE /api/auto-tasks/:id     — 删除
/// - POST   /api/auto-tasks/:id/run — 立即执行（FFI 优先）
class AutoTaskNotifier extends Notifier<AutoTaskState> {
  static const String _baseUrl = 'http://127.0.0.1:8080/api/auto-tasks';
  static const Duration _timeout = Duration(seconds: 5);

  @override
  AutoTaskState build() {
    // 原 AutoTaskProvider 不在构造时自动加载，由页面 initState 触发 loadTasks()
    return const AutoTaskState();
  }

  /// Rust API（可空，null 表示无 FFI，仅走 REST 降级）
  BookApi? get _rustApi => ref.read(autoTaskRustApiProvider);

  /// REST 降级所用 HTTP 客户端
  http.Client get _client => ref.read(autoTaskHttpClientProvider);

  /// 加载所有定时任务
  ///
  /// [silent] 为 true 时不触发 loading 状态（用于增删改后的静默刷新）。
  /// 优先通过 Rust FFI 读取本地数据库，失败时降级到 REST API。
  Future<void> loadTasks({bool silent = false}) async {
    if (!silent) {
      state = state.copyWith(isLoading: true, error: null);
    }

    // FFI 优先路径
    final rustApi = _rustApi;
    if (rustApi != null) {
      try {
        final rules = await rustApi.autoTaskListRules();
        state = state.copyWith(
          tasks: rules.map((r) => AutoTask.fromJson(r)).toList(),
          error: null,
          isLoading: false,
        );
        return;
      } catch (_) {
        // FFI 失败，降级到 REST
      }
    }

    // REST 降级路径
    try {
      final response =
          await _client.get(Uri.parse(_baseUrl)).timeout(_timeout);
      if (response.statusCode == 200) {
        state = state.copyWith(
          tasks: _parseTaskList(response.body),
          error: null,
          isLoading: false,
        );
      } else {
        state = state.copyWith(
          tasks: [],
          error: '加载任务失败: HTTP ${response.statusCode}',
          isLoading: false,
        );
      }
    } catch (e) {
      // 服务端未运行或网络不可达时，回退为空列表
      state = state.copyWith(
        tasks: [],
        error: _isConnectionError(e) ? null : '加载任务失败: $e',
        isLoading: false,
      );
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
  ///
  /// 优先通过 Rust FFI 写入本地数据库，失败时降级到 REST API。
  Future<void> createTask(AutoTask task) async {
    // FFI 优先路径
    final rustApi = _rustApi;
    if (rustApi != null) {
      try {
        await rustApi.autoTaskCreateRule(ruleJson: jsonEncode(task.toJson()));
        await loadTasks(silent: true);
        return;
      } catch (_) {
        // FFI 失败，降级到 REST
      }
    }

    // REST 降级路径
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
      state = state.copyWith(error: '创建任务失败: $e');
    }
  }

  /// 创建任务（保留原始规则 JSON；Task #39 §5.11-2）
  ///
  /// 适用于书籍更新任务等 script 为复杂 JSON action 的任务：
  /// 不能经 [AutoTask] 模型中转（会按 taskType 重新生成占位脚本，
  /// 丢失指向具体书籍的 refreshToc action）。优先 FFI，降级 REST。
  ///
  /// [fix Task#45 | 2026-08-09] 返回 bool：成功 true / 任何失败 false，
  /// 供调用方按结果提示并决定是否重同步调度器 — Qoder
  Future<bool> createTaskRaw(String ruleJson) async {
    // FFI 优先路径
    final rustApi = _rustApi;
    if (rustApi != null) {
      try {
        await rustApi.autoTaskCreateRule(ruleJson: ruleJson);
        await loadTasks(silent: true);
        return true;
      } catch (_) {
        // FFI 失败，降级到 REST
      }
    }

    // REST 降级路径
    try {
      final response = await _client
          .post(
            Uri.parse(_baseUrl),
            headers: const {'Content-Type': 'application/json'},
            body: ruleJson,
          )
          .timeout(_timeout);
      if (response.statusCode != 200 && response.statusCode != 201) {
        throw HttpException('HTTP ${response.statusCode}');
      }
      await loadTasks(silent: true);
      return true;
    } catch (e) {
      state = state.copyWith(error: '创建任务失败: $e');
      return false;
    }
  }

  /// 更新任务（保留原始规则 JSON；Task #39 §5.11-2）
  ///
  /// 与 [createTaskRaw] 同理，保存时仅回写调用方修改过的字段，
  /// script 等其余字段原样保留。优先 FFI，降级 REST。
  ///
  /// [fix Task#45 | 2026-08-09] 返回 bool：成功 true / 任何失败 false；
  /// jsonDecode 挪入 try/catch（Med3）：解码失败或 id 缺失时写 error
  /// 状态并返回 false，不再裸抛 FormatException — Qoder
  Future<bool> updateTaskRaw(String ruleJson) async {
    String id;
    try {
      final decoded = jsonDecode(ruleJson);
      id = decoded is Map ? decoded['id']?.toString() ?? '' : '';
    } catch (e) {
      state = state.copyWith(error: '更新任务失败: 规则 JSON 无效: $e');
      return false;
    }
    if (id.isEmpty) {
      state = state.copyWith(error: '更新任务失败: 缺少任务 id');
      return false;
    }
    // FFI 优先路径
    final rustApi = _rustApi;
    if (rustApi != null) {
      try {
        await rustApi.autoTaskUpdateRule(ruleJson: ruleJson);
        await loadTasks(silent: true);
        return true;
      } catch (_) {
        // FFI 失败，降级到 REST
      }
    }

    // REST 降级路径
    try {
      final response = await _client
          .put(
            Uri.parse('$_baseUrl/$id'),
            headers: const {'Content-Type': 'application/json'},
            body: ruleJson,
          )
          .timeout(_timeout);
      if (response.statusCode != 200) {
        throw HttpException('HTTP ${response.statusCode}');
      }
      await loadTasks(silent: true);
      return true;
    } catch (e) {
      state = state.copyWith(error: '更新任务失败: $e');
      return false;
    }
  }

  /// 切换任务启用状态
  ///
  /// 乐观更新，失败时回滚。优先 FFI，降级 REST。
  Future<void> toggleTask(String id, bool enabled) async {
    // 乐观更新，失败时回滚
    final previous = state.tasks;
    state = state.copyWith(
      tasks: state.tasks.map((t) {
        if (t.id == id) return t.copyWith(isEnabled: enabled);
        return t;
      }).toList(),
    );

    // FFI 优先路径
    final rustApi = _rustApi;
    if (rustApi != null) {
      try {
        final task = state.tasks.firstWhere((t) => t.id == id);
        await rustApi.autoTaskUpdateRule(
          ruleJson: jsonEncode(task.toJson()),
        );
        await loadTasks(silent: true);
        return;
      } catch (_) {
        // FFI 失败，降级到 REST
      }
    }

    // REST 降级路径
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
      state = state.copyWith(tasks: previous, error: '更新任务失败: $e');
    }
  }

  /// 删除任务
  ///
  /// 优先通过 Rust FFI 删除，失败时降级到 REST API。
  Future<void> deleteTask(String id) async {
    // FFI 优先路径
    final rustApi = _rustApi;
    if (rustApi != null) {
      try {
        await rustApi.autoTaskDeleteRule(id: id);
        await loadTasks(silent: true);
        return;
      } catch (_) {
        // FFI 失败，降级到 REST
      }
    }

    // REST 降级路径
    try {
      final response =
          await _client.delete(Uri.parse('$_baseUrl/$id')).timeout(_timeout);
      if (response.statusCode != 200) {
        throw HttpException('HTTP ${response.statusCode}');
      }
      await loadTasks(silent: true);
    } catch (e) {
      state = state.copyWith(error: '删除任务失败: $e');
    }
  }

  /// 立即运行任务
  ///
  /// 优先通过 Rust FFI 执行（autoTaskExecuteWithId），失败时降级到 REST。
  Future<void> runNow(String id) async {
    // 尝试 FFI 路径
    final rustApi = _rustApi;
    if (rustApi != null) {
      try {
        final task = state.tasks.where((t) => t.id == id).firstOrNull;
        final protocolJson = jsonEncode({
          'action': task?.taskType ?? 'noop',
          'taskId': id,
        });
        final result = await rustApi.autoTaskExecuteWithId(
          protocolJson: protocolJson,
          taskId: id,
        );
        // FFI 执行成功，更新本地状态
        final success = result['success'] as bool? ?? false;
        state = state.copyWith(
          tasks: state.tasks.map((t) {
            if (t.id == id) {
              return t.copyWith(
                lastRunAt: _formatNow(),
                lastResult: success ? '成功' : '失败',
              );
            }
            return t;
          }).toList(),
        );
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
      state = state.copyWith(error: '运行任务失败: $e');
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
    final rustApi = _rustApi;
    if (rustApi == null) return null;
    try {
      return await rustApi.autoTaskBuildBookUpdateTask(
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
    final rustApi = _rustApi;
    if (rustApi == null) return null;
    try {
      return await rustApi.autoTaskUpdateCronBatch(
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
    final rustApi = _rustApi;
    if (rustApi == null) return null;
    try {
      return await rustApi.autoTaskPrepareImported(
        localTasksJson: jsonEncode(localTasks),
        importedJson: importedJson,
      );
    } catch (_) {
      return null;
    }
  }

  /// 规范化脚本（FFI，去除 `@js:` 前缀或 `<js></js>` 包裹）
  Future<String?> normalizeScript(String script) async {
    final rustApi = _rustApi;
    if (rustApi == null) return null;
    try {
      return await rustApi.autoTaskNormalizeScript(script: script);
    } catch (_) {
      return null;
    }
  }

  /// 判断书籍是否允许刷新目录（FFI）
  Future<bool?> canRefreshBookToc({
    required bool canUpdate,
    required bool respectCanUpdate,
  }) async {
    final rustApi = _rustApi;
    if (rustApi == null) return null;
    try {
      return await rustApi.autoTaskCanRefreshBookToc(
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
  ///
  /// [fix Task#45 | 2026-08-09] 匹配输入改为从 DB 读全量规则：
  /// AutoTask 模型不保存 script，toJson 按 taskType 生成占位脚本，
  /// Rust 侧 generated_book_identity 要求带 generatedBy 标记的真实
  /// action，占位脚本永远解析失败导致「书名+作者」分支恒失效
  /// （换源后 bookUrl 变化时会重复建任务）。list 失败时退化为模型
  /// 序列化输入，至少保留 ID 精确匹配分支可用 — Qoder
  Future<Map<String, dynamic>?> findBookUpdateTask({
    required String bookUrl,
    required String bookName,
    required String bookAuthor,
  }) async {
    final rustApi = _rustApi;
    if (rustApi == null) return null;
    List<Map<String, dynamic>> rules;
    try {
      rules = await rustApi.autoTaskListRules();
    } catch (_) {
      // list 失败降级：保留 ID 匹配分支可用
      rules = state.tasks.map((t) => t.toJson()).toList();
    }
    try {
      final tasksJson = jsonEncode(rules);
      return await rustApi.autoTaskFindBookUpdateTask(
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
    final rustApi = _rustApi;
    if (rustApi == null) return null;
    try {
      return await rustApi.autoTaskNextDueAt(
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

/// 定时任务 Notifier 全局 Provider
///
/// 使用方式：
/// ```dart
/// final state = ref.watch(autoTaskNotifierProvider);
/// ref.read(autoTaskNotifierProvider.notifier).loadTasks();
/// ```
final autoTaskNotifierProvider =
    NotifierProvider<AutoTaskNotifier, AutoTaskState>(
  AutoTaskNotifier.new,
);
