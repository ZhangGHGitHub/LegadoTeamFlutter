import 'package:flutter/material.dart';

import '../services/rust_api.dart';
import '../bridge/ffi.dart';

/// 统计周期
enum StatsPeriod { week, month }

/// 阅读统计状态管理
class ReadingStatsProvider extends ChangeNotifier {
  final RustApi _api;

  ReadingStatsProvider(this._api);

  // ===== 状态 =====
  ReadingStatsToday _today = const ReadingStatsToday();
  Map<String, int> _dailyStats = {};
  Map<String, int> _bookStats = {};
  Map<String, int> _heatmap = {};
  StatsPeriod _period = StatsPeriod.week;
  bool _loading = false;
  String? _error;

  // ===== Getters =====

  ReadingStatsToday get today => _today;
  Map<String, int> get dailyStats => _dailyStats;
  Map<String, int> get bookStats => _bookStats;
  Map<String, int> get heatmap => _heatmap;
  StatsPeriod get period => _period;
  bool get loading => _loading;
  String? get error => _error;

  /// 书籍统计总时长（秒）
  int get totalBookDuration {
    return _bookStats.values.fold(0, (sum, v) => sum + v);
  }

  // ===== 操作 =====

  /// 切换周期并重新加载
  void setPeriod(StatsPeriod period) {
    if (_period == period) return;
    _period = period;
    loadStats();
  }

  /// 加载全部统计数据
  Future<void> loadStats() async {
    _loading = true;
    _error = null;
    notifyListeners();

    try {
      final days = _period == StatsPeriod.week ? 7 : 30;
      final results = await Future.wait([
        _api.getTodayReadingStats(),
        _api.getDailyReadingStats(days: days),
        _api.getBookReadingStats(),
        _api.getReadingHeatmap(days: 30),
      ]);
      _today = results[0] as ReadingStatsToday;
      _dailyStats = results[1] as Map<String, int>;
      _bookStats = results[2] as Map<String, int>;
      _heatmap = results[3] as Map<String, int>;
    } catch (e) {
      if (e is BridgeError) {
        _error = e.message;
      } else {
        _error = e.toString();
      }
    } finally {
      _loading = false;
      notifyListeners();
    }
  }
}
