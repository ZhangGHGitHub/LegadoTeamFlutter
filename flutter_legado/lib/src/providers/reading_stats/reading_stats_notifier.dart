import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;

import '../../bridge/ffi.dart';
import '../../services/rust_api.dart';
import '../providers.dart';
import 'reading_stats_state.dart';

export 'reading_stats_state.dart';

/// 阅读统计 Riverpod Notifier
///
/// 职责严格限定（对齐原 ReadingStatsProvider）：
/// - 调用 BookApi → 接收纯数据 → 更新 immutable State
/// - 管理 UI 状态（loading/error/data）
/// - 管理统计周期切换（周/月）
class ReadingStatsNotifier extends Notifier<ReadingStatsState> {
  @override
  ReadingStatsState build() {
    // 忠实还原：原构造函数不自动加载，加载由页面首帧回调触发
    return const ReadingStatsState();
  }

  /// 切换周期并重新加载
  void setPeriod(StatsPeriod period) {
    if (state.period == period) return;
    state = state.copyWith(period: period);
    loadStats();
  }

  /// 加载全部统计数据
  Future<void> loadStats() async {
    state = state.copyWith(loading: true, error: null);

    try {
      final api = ref.read(bookApiProvider);
      final days = state.period == StatsPeriod.week ? 7 : 30;
      final results = await Future.wait([
        api.getTodayReadingStats(),
        api.getDailyReadingStats(days: days),
        api.getBookReadingStats(),
        api.getReadingHeatmap(days: 30),
      ]);
      state = state.copyWith(
        today: results[0] as ReadingStatsToday,
        dailyStats: results[1] as Map<String, int>,
        bookStats: results[2] as Map<String, int>,
        heatmap: results[3] as Map<String, int>,
        loading: false,
      );
    } catch (e) {
      state = state.copyWith(
        error: e is BridgeError ? e.message : e.toString(),
        loading: false,
      );
    }
  }
}

/// 阅读统计 Notifier 全局 Provider
///
/// 使用方式：
/// ```dart
/// final state = ref.watch(readingStatsNotifierProvider);
/// ref.read(readingStatsNotifierProvider.notifier).loadStats();
/// ```
final readingStatsNotifierProvider =
    NotifierProvider<ReadingStatsNotifier, ReadingStatsState>(
  ReadingStatsNotifier.new,
);
