import 'package:freezed_annotation/freezed_annotation.dart';

import '../../models/models.dart';

part 'reading_stats_state.freezed.dart';

/// 统计周期
enum StatsPeriod { week, month }

/// 阅读统计 UI 状态（immutable）
///
/// 职责边界（对齐原 ReadingStatsProvider）：
/// - [today]：今日阅读统计（Rust API 返回）
/// - [dailyStats]：每日阅读时长（日期 → 秒）
/// - [bookStats]：各书籍阅读时长（书名 → 秒）
/// - [heatmap]：阅读热力图（日期 → 时长）
/// - [period]：统计周期（周/月）
/// - [loading] / [error]：API 调用状态
@freezed
class ReadingStatsState with _$ReadingStatsState {
  const factory ReadingStatsState({
    /// 今日阅读统计
    @Default(ReadingStatsToday()) ReadingStatsToday today,

    /// 每日阅读时长（日期 → 秒）
    @Default(<String, int>{}) Map<String, int> dailyStats,

    /// 各书籍阅读时长（书名 → 秒）
    @Default(<String, int>{}) Map<String, int> bookStats,

    /// 阅读热力图（日期 → 时长）
    @Default(<String, int>{}) Map<String, int> heatmap,

    /// 当前统计周期（默认周）
    @Default(StatsPeriod.week) StatsPeriod period,

    /// 是否正在加载
    @Default(false) bool loading,

    /// 错误信息（null 表示无错误）
    String? error,
  }) = _ReadingStatsState;
}

/// 阅读统计派生扩展 —— 纯展示层变换，不改变数据内容
extension ReadingStatsDerived on ReadingStatsState {
  /// 书籍统计总时长（秒）
  int get totalBookDuration {
    return bookStats.values.fold(0, (sum, v) => sum + v);
  }
}
