import 'package:freezed_annotation/freezed_annotation.dart';

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
  final String? lastResult;

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
      script: script ?? this.script,
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
