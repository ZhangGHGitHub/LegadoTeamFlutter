import 'package:freezed_annotation/freezed_annotation.dart';

import '../../l10n/app_strings.dart';

part 'auto_task_state.freezed.dart';

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

  /// 脚本返回文本（对齐上游 `lastResult`：成功时存 FFI `message`，失败为 null）
  final String? lastResult;

  /// 错误文本（对齐上游 `lastError`：失败时存 FFI `message`，成功为 null）
  final String? lastError;

  /// 执行日志（对齐上游 `lastLog`：存 FFI `details`，形如
  /// `[OK] Elapsed: 12ms\n- xxx`）
  final String? lastLog;

  /// 最近一次运行成功标记（UI 运行时字段，不持久化、不参与 [toJson]）
  ///
  /// 按上游语义 [lastResult] 只存脚本文本，成功且脚本无返回时为空；
  /// 该标记用于 UI 在三字段皆空时仍能回退显示成功/失败文案。
  /// 从 DB/JSON 载入的历史记录无法可靠推断，保持 null（显示 unknownLabel）。
  final bool? lastSuccess;

  /// 可执行脚本 / 原始 action 载荷（与 [taskType] 展示字段分离）
  ///
  /// 书籍更新等复杂任务 script 为 JSON action；简单任务可为空，
  /// [toJson] 时按 [taskType] 生成占位脚本以兼容旧数据与服务端校验。
  final String? script;

  const AutoTask({
    required this.id,
    required this.name,
    required this.taskType,
    required this.cron,
    this.isEnabled = true,
    this.lastRunAt,
    this.lastResult,
    this.lastError,
    this.lastLog,
    this.lastSuccess,
    this.script,
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
      lastError: json['lastError'] as String?,
      lastLog: json['lastLog'] as String?,
      script: _parseScript(json['script']),
    );
  }

  /// 解析 script：空字符串视为未设置（旧数据无 script 字段时走 taskType 兜底）
  static String? _parseScript(dynamic value) {
    if (value is String && value.isNotEmpty) return value;
    return null;
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
  /// 优先输出已保存的 [script]；无 script 时按 [taskType] 生成占位脚本
  /// （兼容旧 JSON 与服务端 run 端点非空校验）。
  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'enable': isEnabled,
        'cron': cron,
        'comment': taskType,
        'script': effectiveScript,
      };

  /// 实际可执行脚本：有存盘载荷用存盘值，否则按 taskType 生成占位脚本
  String get effectiveScript => script ?? _defaultScript;

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
    String? lastError,
    String? lastLog,
    bool? lastSuccess,
    String? script,
  }) {
    return AutoTask(
      id: id ?? this.id,
      name: name ?? this.name,
      taskType: taskType ?? this.taskType,
      cron: cron ?? this.cron,
      isEnabled: isEnabled ?? this.isEnabled,
      lastRunAt: lastRunAt ?? this.lastRunAt,
      lastResult: lastResult ?? this.lastResult,
      lastError: lastError ?? this.lastError,
      lastLog: lastLog ?? this.lastLog,
      lastSuccess: lastSuccess ?? this.lastSuccess,
      script: script ?? this.script,
    );
  }

  /// 写入一次运行结果（对齐上游 `AutoTask.updateRunState`）
  ///
  /// 与 [copyWith] 不同：这里 [result]/[error]/[log] 传 null 表示**清除**该
  /// 字段（上游成功时 lastError 必须置 null、失败时 lastResult 置 null），
  /// 因此不能复用 copyWith 的“null 即保持不变”语义。
  AutoTask withRunResult({
    required String runAt,
    required bool success,
    String? result,
    String? error,
    String? log,
  }) {
    return AutoTask(
      id: id,
      name: name,
      taskType: taskType,
      cron: cron,
      isEnabled: isEnabled,
      lastRunAt: runAt,
      lastResult: result,
      lastError: error,
      lastLog: log,
      lastSuccess: success,
      script: script,
    );
  }

  /// 上次运行结果展示文本（对齐上游 `AutoTaskActivity`：`lastLog ?: lastError
  /// ?: lastResult`；三者皆空时按 [lastSuccess] 回退成功/失败文案）
  String get runResultText {
    String? nonEmpty(String? value) {
      if (value == null) return null;
      final trimmed = value.trim();
      return trimmed.isEmpty ? null : trimmed;
    }

    final log = nonEmpty(lastLog);
    if (log != null) return log;
    final error = nonEmpty(lastError);
    if (error != null) return error;
    final result = nonEmpty(lastResult);
    if (result != null) return result;
    switch (lastSuccess) {
      case true:
        return AppStrings.autoTaskRunSuccess;
      case false:
        return AppStrings.autoTaskRunFailure;
      case null:
        return AppStrings.unknownLabel;
    }
  }

  /// 任务类型显示名称
  String get taskTypeLabel {
    switch (taskType) {
      case 'refreshToc':
        return AppStrings.taskTypeRefreshToc;
      case 'updateSources':
        return AppStrings.taskTypeUpdateSources;
      case 'backup':
        return AppStrings.webdavAutoBackup;
      default:
        return taskType;
    }
  }
}

/// 定时任务页 UI 状态（immutable）
///
/// 职责边界（对齐旧 AutoTaskProvider）：
/// - [tasks]：任务列表（FFI 优先，REST 降级）
/// - [isLoading]：列表加载状态
/// - [error]：错误信息（null 表示无错误或连接类错误静默）
@freezed
class AutoTaskState with _$AutoTaskState {
  const factory AutoTaskState({
    /// 定时任务列表
    @Default([]) List<AutoTask> tasks,

    /// 是否正在加载任务列表
    @Default(false) bool isLoading,

    /// 错误信息（null 表示无错误）
    String? error,
  }) = _AutoTaskState;
}
