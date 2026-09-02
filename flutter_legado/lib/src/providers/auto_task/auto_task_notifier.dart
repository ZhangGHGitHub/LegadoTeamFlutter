import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide ChangeNotifierProvider;

import '../../services/book_api.dart';
import '../providers.dart';
import 'auto_task_state.dart';

export 'auto_task_state.dart';

/// 定时任务 Rust API 注入点
///
/// 生产环境由 [bookApiProvider] 提供；对齐旧 AutoTaskProvider 命名参数 `rustApi`
/// 的可空语义，测试可覆盖为 null 以验证 FFI 缺失分支（错误可见）。
final autoTaskRustApiProvider =
    Provider<BookApi?>((ref) => ref.read(bookApiProvider));

/// 定时任务 Riverpod Notifier
///
/// 数据面纯走 Rust FFI（autoTaskListRules / autoTaskCreateRule 等）。
///
/// [体检 §二.7 | 2026-09-03] 原 REST 降级路径已删除：legado-server 进程内从未
/// 启动，REST 指向 127.0.0.1:8080 永远连接失败，且连接类错误被吞成空列表
/// （UI 无感静默失败）。对齐原版"无 Web 服务则纯本地 FFI"的口径，FFI 失败
/// 一律写入 error 状态由 UI 呈现。
class AutoTaskNotifier extends Notifier<AutoTaskState> {
  @override
  AutoTaskState build() {
    // 原 AutoTaskProvider 不在构造时自动加载，由页面 initState 触发 loadTasks()
    return const AutoTaskState();
  }

  /// Rust API（可空，null 表示 FFI 不可用）
  BookApi? get _rustApi => ref.read(autoTaskRustApiProvider);

  /// 加载所有定时任务
  ///
  /// [silent] 为 true 时不触发 loading 状态（用于增删改后的静默刷新）；
  /// 成功时清除上次错误，失败时错误可见。
  Future<void> loadTasks({bool silent = false}) async {
    if (!silent) {
      state = state.copyWith(isLoading: true, error: null);
    }
    final rustApi = _rustApi;
    if (rustApi == null) {
      state = state.copyWith(
        tasks: [],
        error: 'FFI 不可用，无法加载定时任务',
        isLoading: false,
      );
      return;
    }
    try {
      final rules = await rustApi.autoTaskListRules();
      state = state.copyWith(
        tasks: rules.map((r) => AutoTask.fromJson(r)).toList(),
        error: null,
        isLoading: false,
      );
    } catch (e) {
      state = state.copyWith(
        tasks: [],
        error: '加载任务失败: $e',
        isLoading: false,
      );
    }
  }

  /// 创建新任务
  Future<void> createTask(AutoTask task) async {
    final rustApi = _rustApi;
    if (rustApi == null) {
      state = state.copyWith(error: 'FFI 不可用，无法创建任务');
      return;
    }
    try {
      await rustApi.autoTaskCreateRule(ruleJson: jsonEncode(task.toJson()));
      await loadTasks(silent: true);
    } catch (e) {
      state = state.copyWith(error: '创建任务失败: $e');
    }
  }

  /// 创建任务（保留原始规则 JSON；Task #39 §5.11-2）
  ///
  /// 适用于书籍更新任务等 script 为复杂 JSON action 的任务：
  /// 不能经 [AutoTask] 模型中转（会按 taskType 重新生成占位脚本，
  /// 丢失指向具体书籍的 refreshToc action）。
  ///
  /// [fix Task#45 | 2026-08-09] 返回 bool：成功 true / 任何失败 false，
  /// 供调用方按结果提示并决定是否重同步调度器 — Qoder
  Future<bool> createTaskRaw(String ruleJson) async {
    final rustApi = _rustApi;
    if (rustApi == null) {
      state = state.copyWith(error: 'FFI 不可用，无法创建任务');
      return false;
    }
    try {
      await rustApi.autoTaskCreateRule(ruleJson: ruleJson);
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
  /// script 等其余字段原样保留。
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
    final rustApi = _rustApi;
    if (rustApi == null) {
      state = state.copyWith(error: 'FFI 不可用，无法更新任务');
      return false;
    }
    try {
      await rustApi.autoTaskUpdateRule(ruleJson: ruleJson);
      await loadTasks(silent: true);
      return true;
    } catch (e) {
      state = state.copyWith(error: '更新任务失败: $e');
      return false;
    }
  }

  /// 切换任务启用状态
  ///
  /// 乐观更新，失败时回滚。
  Future<void> toggleTask(String id, bool enabled) async {
    final previous = state.tasks;
    state = state.copyWith(
      tasks: state.tasks.map((t) {
        if (t.id == id) return t.copyWith(isEnabled: enabled);
        return t;
      }).toList(),
    );

    final rustApi = _rustApi;
    if (rustApi == null) {
      state = state.copyWith(tasks: previous, error: 'FFI 不可用，无法更新任务');
      return;
    }
    try {
      final task = state.tasks.firstWhere((t) => t.id == id);
      await rustApi.autoTaskUpdateRule(
        ruleJson: jsonEncode(task.toJson()),
      );
      await loadTasks(silent: true);
    } catch (e) {
      state = state.copyWith(tasks: previous, error: '更新任务失败: $e');
    }
  }

  /// 删除任务
  Future<void> deleteTask(String id) async {
    final rustApi = _rustApi;
    if (rustApi == null) {
      state = state.copyWith(error: 'FFI 不可用，无法删除任务');
      return;
    }
    try {
      await rustApi.autoTaskDeleteRule(id: id);
      await loadTasks(silent: true);
    } catch (e) {
      state = state.copyWith(error: '删除任务失败: $e');
    }
  }

  /// 立即运行任务（FFI autoTaskExecuteWithId）
  Future<void> runNow(String id) async {
    final rustApi = _rustApi;
    if (rustApi == null) {
      state = state.copyWith(error: 'FFI 不可用，无法运行任务');
      return;
    }
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
  /// [fix Task#45 | 2026-08-09] 匹配输入改为从 DB 读全量规则；
  /// list 失败时退化为 state.tasks 序列化（[AutoTask] 已保存 script，
  /// toJson 保留真实 action，书名+作者匹配可用）— Qoder
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
