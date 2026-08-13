import '../../models/models.dart';

/// 阅读记录排序（对齐原版 LocalConfig `readRecordSort`）
///
/// - [name]：按书名（默认）
/// - [readTime]：按阅读时长降序
/// - [lastRead]：按最后阅读时间降序
enum ReadRecordSortMode {
  name,
  readTime,
  lastRead,
}

/// 阅读记录页状态（对齐原版 ReadRecordActivity）
class ReadRecordState {
  /// 当前展示列表（已按搜索/排序过滤）
  final List<ReadRecordShow> records;

  /// 全部阅读时长合计（毫秒，对齐原版 allTime）
  final int totalReadTimeMs;

  /// 搜索关键词
  final String searchQuery;

  /// 排序模式
  final ReadRecordSortMode sortMode;

  /// 是否启用阅读时长记录（对齐 AppConfig.enableReadRecord）
  final bool enableRecord;

  /// 加载中
  final bool isLoading;

  /// 错误信息
  final String? error;

  const ReadRecordState({
    this.records = const [],
    this.totalReadTimeMs = 0,
    this.searchQuery = '',
    this.sortMode = ReadRecordSortMode.name,
    this.enableRecord = true,
    this.isLoading = false,
    this.error,
  });

  ReadRecordState copyWith({
    List<ReadRecordShow>? records,
    int? totalReadTimeMs,
    String? searchQuery,
    ReadRecordSortMode? sortMode,
    bool? enableRecord,
    bool? isLoading,
    String? error,
    bool clearError = false,
  }) {
    return ReadRecordState(
      records: records ?? this.records,
      totalReadTimeMs: totalReadTimeMs ?? this.totalReadTimeMs,
      searchQuery: searchQuery ?? this.searchQuery,
      sortMode: sortMode ?? this.sortMode,
      enableRecord: enableRecord ?? this.enableRecord,
      isLoading: isLoading ?? this.isLoading,
      error: clearError ? null : (error ?? this.error),
    );
  }
}
