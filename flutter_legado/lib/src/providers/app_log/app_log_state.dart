/// 应用日志页不可变状态与日志条目模型
///
/// [审计修复 §1.2 第二批] 承接契约 §2.38 appLog* 五方法的 UI 状态层 — Qoder
///
/// 对齐 Android 原版 AppLogDialog：message / crash / http 三级日志分页展示。
library;

/// 单条应用日志（字段对齐 Rust log_api 返回：timestamp/level/message）
class AppLogEntry {
  /// 时间戳（毫秒）
  final int timestamp;

  /// 日志级别：`message` / `crash` / `http`
  final String level;

  /// 日志内容
  final String message;

  const AppLogEntry({
    required this.timestamp,
    required this.level,
    required this.message,
  });

  /// 从 Rust 返回的 JSON 对象解析（字段缺失时容错）
  factory AppLogEntry.fromJson(Map<String, dynamic> json) {
    return AppLogEntry(
      timestamp: (json['timestamp'] as num?)?.toInt() ?? 0,
      level: (json['level'] as String?) ?? 'message',
      message: (json['message'] as String?) ?? '',
    );
  }

  /// 时间显示（HH:mm:ss.SSS）
  String get timeText {
    final dt = DateTime.fromMillisecondsSinceEpoch(timestamp);
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(dt.hour)}:${two(dt.minute)}:${two(dt.second)}.'
        '${dt.millisecond.toString().padLeft(3, '0')}';
  }
}

/// 应用日志页状态（不可变，copyWith 更新）
class AppLogState {
  /// 当前选中级别
  final String currentLevel;

  /// 当前级别的日志列表（最新在前，与 Rust 返回顺序一致）
  final List<AppLogEntry> logs;

  /// 是否正在加载
  final bool isLoading;

  /// 错误信息（null 表示无错误）
  final String? error;

  const AppLogState({
    this.currentLevel = 'message',
    this.logs = const [],
    this.isLoading = false,
    this.error,
  });

  AppLogState copyWith({
    String? currentLevel,
    List<AppLogEntry>? logs,
    bool? isLoading,
    String? error,
    bool clearError = false,
  }) {
    return AppLogState(
      currentLevel: currentLevel ?? this.currentLevel,
      logs: logs ?? this.logs,
      isLoading: isLoading ?? this.isLoading,
      error: clearError ? null : (error ?? this.error),
    );
  }
}
