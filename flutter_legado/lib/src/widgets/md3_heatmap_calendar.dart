import 'package:flutter/material.dart';

/// 热力图配色模式（对齐参考仓库 HeatmapMode）
enum Md3HeatmapMode {
  /// 每日阅读时长（秒；数据源 readRecordDailyList，Rust 契约 2026-08-29）
  duration,

  /// 当日阅读书籍数（数据源记录 lastRead 落日去重）
  count,
}

/// MD3 阅读热力图日历（对齐参考仓库 HeatmapCalendar：GitHub 打卡风格，
/// 列=周、行=周一~周日，格子按 5 级配色）
///
/// - [Md3HeatmapMode.duration]：按当日阅读秒数分级（readRecordDailyList）；
/// - [Md3HeatmapMode.count]：按当日阅读书籍数分级（诚实口径 = lastRead
///   落日去重）。
class Md3HeatmapCalendar extends StatelessWidget {
  /// 时长模式数据：日 → 当日阅读秒数
  final Map<DateTime, int> dailySeconds;

  /// 计数模式数据：日 → 当日阅读书籍数
  final Map<DateTime, int> dailyCounts;

  /// 当前配色模式
  final Md3HeatmapMode mode;

  /// 结束日期（含当日，通常为今天）；向前铺满 [weeks] 周
  final DateTime endDate;

  /// 展示周数（默认 52 周一年）
  final int weeks;

  /// 基色（5 级由 primary 透明度阶梯派生）
  final Color? color;

  const Md3HeatmapCalendar({
    super.key,
    required this.dailySeconds,
    required this.dailyCounts,
    required this.mode,
    required this.endDate,
    this.weeks = 52,
    this.color,
  });

  /// 按记录列表聚合每日书籍数（lastRead 落日 + 书名去重）
  static Map<DateTime, int> aggregateDailyBookCount(
    Iterable<({String bookName, int lastRead})> records,
  ) {
    final map = <String, int>{};
    for (final r in records) {
      if (r.lastRead <= 0) continue;
      final d = DateTime.fromMillisecondsSinceEpoch(r.lastRead);
      final day = DateTime(d.year, d.month, d.day);
      final key = '${day.millisecondsSinceEpoch}:${r.bookName}';
      map[key] = (map[key] ?? 0) + 1;
    }
    final daily = <DateTime, int>{};
    for (final e in map.entries) {
      final parts = e.key.split(':');
      final day = DateTime.fromMillisecondsSinceEpoch(int.parse(parts.first));
      daily[day] = (daily[day] ?? 0) + 1;
    }
    return daily;
  }

  /// 5 级配色：0 无记录 → surfaceContainerHighest；1~4+ → primary 阶梯
  /// （level1 起点抬至 0.4，避免暗色主题下与底灰不可分）
  Color _colorForLevel(int level, ColorScheme scheme, Color base) {
    switch (level) {
      case 0:
        return scheme.surfaceContainerHighest;
      case 1:
        return base.withValues(alpha: 0.4);
      case 2:
        return base.withValues(alpha: 0.6);
      case 3:
        return base.withValues(alpha: 0.8);
      default:
        return base;
    }
  }

  /// 时长分级阈值（秒）：0 / <10min / <30min / <60min / ≥60min
  static int levelForSeconds(int seconds) {
    if (seconds <= 0) return 0;
    if (seconds < 600) return 1;
    if (seconds < 1800) return 2;
    if (seconds < 3600) return 3;
    return 4;
  }

  /// 计数分级：0 / 1 / 2 / 3~4 / ≥5 本
  static int levelForCount(int count) {
    if (count <= 0) return 0;
    if (count == 1) return 1;
    if (count == 2) return 2;
    if (count <= 4) return 3;
    return 4;
  }

  String _formatDuration(int seconds) {
    if (seconds < 60) return '$seconds 秒';
    final m = seconds ~/ 60;
    if (m < 60) return '$m 分钟';
    return '${m ~/ 60} 小时 ${m % 60} 分';
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final base = color ?? scheme.primary;

    // 结束日对齐到所在周的最后一天（周日）；从结束周向前铺 weeks 周
    final end = DateTime(
      endDate.year,
      endDate.month,
      endDate.day,
    ).add(Duration(days: 6 - (endDate.weekday - 1) % 7));
    final cells = <(DateTime, int)>[];
    for (var w = weeks - 1; w >= 0; w--) {
      final weekEnd = end.subtract(Duration(days: 7 * w));
      for (var d = 6; d >= 0; d--) {
        final day = weekEnd.subtract(Duration(days: d));
        final count = dailyCounts[day] ?? 0;
        final seconds = dailySeconds[day] ?? 0;
        final level = mode == Md3HeatmapMode.duration
            ? levelForSeconds(seconds)
            : levelForCount(count);
        cells.add((day, level));
      }
    }
    // 未来日期格子隐藏（弱化为不可见底格）
    final today = DateTime.now();
    final todayDay = DateTime(today.year, today.month, today.day);

    String tooltipFor(DateTime day, int level) {
      if (day.isAfter(todayDay)) return '';
      if (mode == Md3HeatmapMode.duration) {
        return '${day.month}/${day.day} · ${_formatDuration(dailySeconds[day] ?? 0)}';
      }
      return '${day.month}/${day.day} · ${dailyCounts[day] ?? 0} 本';
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 日历主体：横向滚动（周列）
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          reverse: true,
          padding: EdgeInsets.zero,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (var c = 0; c < cells.length / 7; c++)
                Column(
                  children: [
                    for (var r = 0; r < 7; r++)
                      Builder(
                        builder: (context) {
                          final (day, level) = cells[c * 7 + r];
                          final isFuture = day.isAfter(todayDay);
                          return Padding(
                            padding: const EdgeInsets.all(1.5),
                            child: Tooltip(
                              message: tooltipFor(day, level),
                              triggerMode: TooltipTriggerMode.tap,
                              child: Container(
                                width: 12,
                                height: 12,
                                decoration: BoxDecoration(
                                  color: isFuture
                                      ? Colors.transparent
                                      : _colorForLevel(level, scheme, base),
                                  borderRadius: BorderRadius.circular(2),
                                ),
                              ),
                            ),
                          );
                        },
                      ),
                  ],
                ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        // 图例：少 → 多
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            Text(
              '少',
              style: Theme.of(context)
                  .textTheme
                  .labelSmall
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
            for (var level = 0; level <= 4; level++)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 1.5),
                child: Container(
                  width: 10,
                  height: 10,
                  decoration: BoxDecoration(
                    color: _colorForLevel(level, scheme, base),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
            Text(
              mode == Md3HeatmapMode.duration
                  ? '多（格 = 当日阅读时长）'
                  : '多（格 = 当日阅读书籍数）',
              style: Theme.of(context)
                  .textTheme
                  .labelSmall
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ],
    );
  }
}
