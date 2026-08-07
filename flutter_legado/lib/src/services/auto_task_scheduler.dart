// [UI-fix v2.0.3 | 2026-08-08] 留项10：定时服务应用内调度器（Task #146）。
// 对齐 Kotlin 原版 service/AutoTaskScheduler + AutoTaskJobService +
// AutoTaskSchedulePolicy：refresh 触发点（启动/任务变更/开关）、executionLock
// 串行批次、jobFinished(retry) 退避重试语义。应用内 Timer 调度（非真后台
// WorkManager，进程被杀后不执行，属诚实边界）。 — QoderCN
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import 'book_api.dart';

/// 定时任务应用内调度器（全局单例，服务层无依赖注入）
///
/// 与 Kotlin 原版组件的对应关系：
/// | Kotlin 原版                            | 本实现                                |
/// |----------------------------------------|---------------------------------------|
/// | AutoTaskScheduler.refresh              | [refresh]                             |
/// | PreferKey.autoTaskService 开关         | config 键 `autoTaskService`           |
/// | AutoTaskSchedulePolicy.nextDueAt       | [_nextRunAt]（经 autoTaskNextDueAt）  |
/// | AutoTaskSchedulePolicy.dueRules        | [_dueRules]                           |
/// | FIRST_RUN_GRACE_MS（5 分钟宽限）        | [_firstRunGrace]                      |
/// | JobScheduler.setMinimumLatency         | [Timer]                               |
/// | AutoTaskJobService.executionLock       | [_running]（重复触发跳过）             |
/// | jobFinished(retry=true)+BACKOFF 60s    | [_retryBackoff] 退避重试               |
/// | AutoTaskScheduler.cancelAll            | [cancelAll]                           |
///
/// 触发点（对齐原版 refresh 调用位置）：
/// - 应用启动：app.dart 装配 [attach]
/// - 任务增删改 / 启停：auto_task_screen 操作后调用 [refresh]
/// - 设置页开关：开启 → [refresh]，关闭 → [cancelAll]（settings_screen）
/// - 应用自后台恢复：[didChangeAppLifecycleState] resumed → [refresh]
class AutoTaskScheduler with WidgetsBindingObserver {
  AutoTaskScheduler._();

  /// 全局单例（对齐 PlatformBridgeService.instance 模式）
  static final AutoTaskScheduler instance = AutoTaskScheduler._();

  /// 失败退避重试间隔（对齐 Kotlin RETRY_BACKOFF_MS = 60_000）
  static const Duration _retryBackoff = Duration(minutes: 1);

  /// 首次运行宽限期（对齐 AutoTaskSchedulePolicy.FIRST_RUN_GRACE_MS）
  static const Duration _firstRunGrace = Duration(minutes: 5);

  /// config 键：定时服务总开关（对齐 PreferKey.autoTaskService）
  static const String _prefKey = 'autoTaskService';

  BookApi? _api;

  /// 当前挂起的调度 Timer（对标 JobScheduler pending job）
  Timer? _timer;

  /// 串行执行锁（对标 executionLock Mutex）：同一时刻仅一批执行，
  /// 重复触发直接跳过。Dart 单线程事件循环保证标志位读写原子性。
  bool _running = false;

  /// 刷新代数：并发的 [refresh] 互相作废旧一代的延迟结果
  int _generation = 0;

  /// 装配入口（app.dart initState，参考 PlatformBridgeService.navigatorKey）
  ///
  /// 注入 BookApi 并注册生命周期观察（后台恢复时重算调度），
  /// 随后执行一次 [refresh]（对齐原版 App.kt 启动触发点）。
  void attach(BookApi api) {
    _api = api;
    WidgetsBinding.instance.addObserver(this);
    refresh();
  }

  /// 应用自后台恢复：Timer 在挂起期间可能已过期，重算一次调度
  ///（对齐原版「启动时 refresh」的最接近应用内等价物）。
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) refresh();
  }

  /// 是否处于开启状态（读持久化开关，对齐 getPrefBoolean(autoTaskService)）
  Future<bool> _isEnabled() async {
    final api = _api;
    if (api == null) return false;
    try {
      return await api.getConfig(_prefKey) == 'true';
    } catch (_) {
      return false;
    }
  }

  /// 取消全部挂起调度（对标 AutoTaskScheduler.cancelAll）
  Future<void> cancelAll() async {
    _generation++;
    _timer?.cancel();
    _timer = null;
  }

  /// 重算调度（对标 AutoTaskScheduler.refresh）
  ///
  /// [afterBatch] 为 true 时以当前时间为基准计算下次执行
  ///（对标 nextAfterBatchAt），否则以各任务 lastRunAt / 宽限期为基准
  ///（对标 nextDueAt）。开关关闭或无可调度任务时取消挂起 Timer。
  Future<void> refresh({bool afterBatch = false}) async {
    final api = _api;
    if (api == null) return;
    final generation = ++_generation;
    try {
      if (!await _isEnabled()) {
        _timer?.cancel();
        _timer = null;
        return;
      }
      final rules = await api.autoTaskListRules();
      if (generation != _generation) return; // 已被更新的 refresh 取代
      final now = DateTime.now().millisecondsSinceEpoch;
      final runAt = await _nextRunAt(
        api,
        rules,
        now,
        afterBatch: afterBatch,
      );
      if (generation != _generation) return;
      _timer?.cancel();
      _timer = null;
      if (runAt == null) return;
      final delay = Duration(milliseconds: (runAt - now).clamp(0, 1 << 62));
      _timer = Timer(delay, _onTimer);
      debugPrint(
        '[AutoTaskScheduler] 下次执行：${DateTime.fromMillisecondsSinceEpoch(runAt)}'
        '（${delay.inSeconds}s 后）',
      );
    } catch (e) {
      // FFI 暂不可用（引擎未就绪等）不抛出；开关/任务变更会再次触发
      debugPrint('[AutoTaskScheduler] refresh 失败: $e');
    }
  }

  /// 计算最近一次到期时间（对标 nextDueAt / nextAfterBatchAt）
  ///
  /// 逐任务经 autoTaskNextDueAt(cron, base) 计算，base 取：
  /// - afterBatch：当前时间（严格在 now 之后的下次触发）
  /// - 常规：lastRunAt > 0 时取 lastRunAt，否则 now - 宽限期（首次运行）
  /// 返回 null 表示无可调度任务（全部禁用 / cron 无效）。
  Future<int?> _nextRunAt(
    BookApi api,
    List<Map<String, dynamic>> rules,
    int now, {
    required bool afterBatch,
  }) async {
    int? min;
    for (final rule in rules) {
      if (!_ruleEnabled(rule)) continue;
      final cron = (rule['cron'] as String? ?? '').trim();
      if (cron.isEmpty) continue;
      final base = afterBatch ? now : _baseTime(rule, now);
      int nextDue;
      try {
        nextDue = await api.autoTaskNextDueAt(cron: cron, fromMs: base);
      } catch (_) {
        continue;
      }
      if (nextDue < 0) continue; // cron 无法解析
      final candidate = nextDue < now ? now : nextDue; // coerceAtLeast(now)
      if (min == null || candidate < min) min = candidate;
    }
    return min;
  }

  /// 筛出到期任务（对标 AutoTaskSchedulePolicy.dueRules）
  ///
  /// 判定：nextTimeAfter(base) <= now，base 规则同 [_nextRunAt] 常规分支。
  Future<List<Map<String, dynamic>>> _dueRules(
    BookApi api,
    List<Map<String, dynamic>> rules,
    int now,
  ) async {
    final due = <Map<String, dynamic>>[];
    for (final rule in rules) {
      if (!_ruleEnabled(rule)) continue;
      final cron = (rule['cron'] as String? ?? '').trim();
      if (cron.isEmpty) continue;
      int nextDue;
      try {
        nextDue = await api.autoTaskNextDueAt(
          cron: cron,
          fromMs: _baseTime(rule, now),
        );
      } catch (_) {
        continue;
      }
      if (nextDue >= 0 && nextDue <= now) due.add(rule);
    }
    return due;
  }

  /// 基准时间（对标 baseTime：lastRunAt>0 取之，否则 now - 宽限期）
  int _baseTime(Map<String, dynamic> rule, int now) {
    final raw = rule['lastRunAt'] ?? rule['last_run_at'] ?? 0;
    final lastRunAt = raw is int ? raw : int.tryParse('$raw') ?? 0;
    return lastRunAt > 0
        ? lastRunAt
        : now - _firstRunGrace.inMilliseconds;
  }

  /// 任务启用判定（兼容 isEnabled / enable 两种字段风格）
  bool _ruleEnabled(Map<String, dynamic> rule) {
    final enabled = rule['isEnabled'] ?? rule['enable'] ?? true;
    return enabled == true;
  }

  /// Timer 到点回调：执行一批到期任务（对标 onStartJob）
  Future<void> _onTimer() async {
    // executionLock 语义：已有批次执行中则跳过本次触发
    if (_running) return;
    final api = _api;
    if (api == null) return;
    _running = true;
    try {
      if (!await _isEnabled()) return;
      final rules = await api.autoTaskListRules();
      final now = DateTime.now().millisecondsSinceEpoch;
      final due = await _dueRules(api, rules, now);
      if (due.isEmpty) {
        // 无到期任务：按批次后策略重排下一轮（对标 shouldRetry 分支）
        await refresh(afterBatch: true);
        return;
      }
      for (final rule in due) {
        // 单任务失败不影响整批（对标 runTask 逐任务 try/catch 持久化）
        try {
          final id = (rule['id'] ?? '').toString();
          final protocolJson = jsonEncode({
            'action': rule['comment'] ?? 'noop',
            'taskId': id,
          });
          await api.autoTaskExecuteWithId(
            protocolJson: protocolJson,
            taskId: id,
          );
          debugPrint('[AutoTaskScheduler] 任务执行完成: ${rule['name']}');
        } catch (e) {
          debugPrint(
            '[AutoTaskScheduler] 任务执行失败: ${rule['name']} — $e',
          );
        }
      }
      // 批次完成：以当前时间为基准调度下一轮（对标 refresh(afterBatch=true)）
      await refresh(afterBatch: true);
    } catch (e) {
      // 批次级失败（FFI 异常等）：退避重试（对标 jobFinished(retry=true)
      // + BACKOFF_POLICY_LINEAR 60s）
      debugPrint('[AutoTaskScheduler] 批次执行失败，${_retryBackoff.inSeconds}s 后重试: $e');
      _generation++;
      _timer?.cancel();
      _timer = Timer(_retryBackoff, _onTimer);
    } finally {
      _running = false;
    }
  }
}
