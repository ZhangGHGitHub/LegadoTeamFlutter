import 'package:flutter/material.dart';

/// MD3 阅读热力图日历（对齐参考仓库 HeatmapCalendar 的 counts 模式：
/// GitHub 打卡风格，列=周、行=周一~周日，格子按当日阅读书籍数分 5 级配色）
///
/// 数据语义（诚实口径）：值为「当日有阅读记录的书籍数」（按记录
/// lastRead 落日去重计数）；「每日时长」语义需 Rust 侧日聚合契约，
/// 登记为跨轨待办，当前不做。
class Md3HeatmapCalendar extends StatelessWidget {
  /// 日 → 当日阅读书籍数
  final Map<DateTime, int> dailyCounts;

  /// 结束日期（含当日，通常为今天）；向前铺满 [weeks] 周
  final DateTime endDate;

  /// 展示周数（默认 52 周一年）
  final int weeks;

  /// 基色（5 级由 primary 透明度阶梯派生）
  final Color? color;

  const Md3HeatmapCalendar({
    super.key,
    required this.dailyCounts,
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
  Color _colorForLevel(int level, ColorScheme scheme, Color base) {
    switch (level) {
      case 0:
        return scheme.surfaceContainerHighest;
      case 1:
        return base.withValues(alpha: 0.25);
      case 2:
        return base.withValues(alpha: 0.45);
      case 3:
        return base.withValues(alpha: 0.7);
      default:
        return base;
    }
  }

  static int levelForCount(int count) {
    if (count <= 0) return 0;
    if (count == 1) return 1;
    if (count == 2) return 2;
    if (count <= 4) return 3;
    return 4;
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
        cells.add((day, dailyCounts[day] ?? 0));
      }
    }
    // 未来日期格子隐藏（弱化为不可见底格）
    final today = DateTime.now();
    final todayDay = DateTime(today.year, today.month, today.day);

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
                          final (day, count) = cells[c * 7 + r];
                          final isFuture = day.isAfter(todayDay);
                          final level = levelForCount(count);
                          return Padding(
                            padding: const EdgeInsets.all(1.5),
                            child: Tooltip(
                              message: isFuture
                                  ? ''
                                  : '${day.month}/${day.day}'
                                      ' · $count 本',
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
              '多（格 = 当日阅读书籍数）',
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
