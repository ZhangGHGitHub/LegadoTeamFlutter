import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

/// 阅读记录「按天」视图与成就卡（差异清单 C5，低优增强）
///
/// 参考版形态：累计成就卡 + 按天时间线（今天/昨天/更早分组，每行=日期+当日时长）。
/// 本文件只做呈现（UI 层职责边界）；数据由页面注入（readRecordDailyList 既有契约）。
/// — Qoder UI ｜ 2026-09-11
class ReadAchievementCard extends StatelessWidget {
  /// 已读本数（记录中时长 > 0 的条目数）
  final int readBooks;

  /// 累计时长展示文本（由页面格式化，与既有 formatDuring 同源）
  final String totalDurationText;

  /// 清空入口（沿用页面既有确认流程；为 null 时隐藏）
  final VoidCallback? onClearAll;

  const ReadAchievementCard({
    super.key,
    required this.readBooks,
    required this.totalDurationText,
    this.onClearAll,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Card(
        elevation: 0,
        color: cs.surfaceContainerLow,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 8, 14),
          child: Row(
            children: [
              Icon(Symbols.local_library_rounded, size: 28, color: cs.primary),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '已读 $readBooks 本',
                      style: Theme.of(context)
                          .textTheme
                          .titleMedium
                          ?.copyWith(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '累计 $totalDurationText',
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                            color: cs.onSurfaceVariant,
                          ),
                    ),
                  ],
                ),
              ),
              if (onClearAll != null)
                TextButton(onPressed: onClearAll, child: const Text('清空')),
            ],
          ),
        ),
      ),
    );
  }
}

/// 按天分组条目（日期 + 当日秒数）
@immutable
class DailyReadEntry {
  final DateTime date;
  final int seconds;

  const DailyReadEntry({required this.date, required this.seconds});
}

/// 每日时长 → 分组（今天 / 昨天 / 更早），各组内按日期倒序；空秒数条目剔除。
///
/// 纯函数便于单测；[now] 可注入便于测试。
List<({String label, List<DailyReadEntry> entries})> groupDailyByDay(
  List<Map<String, dynamic>> daily,
  DateTime now,
) {
  final today = DateTime(now.year, now.month, now.day);
  final yesterday = today.subtract(const Duration(days: 1));
  final groups = <String, List<DailyReadEntry>>{'今天': [], '昨天': [], '更早': []};
  for (final e in daily) {
    final seconds = (e['seconds'] as num?)?.toInt() ?? 0;
    if (seconds <= 0) continue;
    final date = (e['date'] ?? '').toString();
    final parts = date.split('-');
    if (parts.length != 3) continue;
    final d = DateTime(
      int.parse(parts[0]),
      int.parse(parts[1]),
      int.parse(parts[2]),
    );
    final label = d == today
        ? '今天'
        : d == yesterday
            ? '昨天'
            : '更早';
    groups[label]!.add(DailyReadEntry(date: d, seconds: seconds));
  }
  for (final list in groups.values) {
    list.sort((a, b) => b.date.compareTo(a.date));
  }
  return [
    for (final label in ['今天', '昨天', '更早'])
      if (groups[label]!.isNotEmpty) (label: label, entries: groups[label]!),
  ];
}

/// 按天视图（时间线：分组头 + 日期行）
class ReadRecordDailyView extends StatelessWidget {
  /// 每日时长原始数据（readRecordDailyList 结果；null=加载中）
  final List<Map<String, dynamic>>? daily;

  /// 格式化当日秒数（复用页面 formatDuring 口径）
  final String Function(int seconds) formatSeconds;

  /// 加载失败时的重试（为 null 时显示空态）
  final VoidCallback? onRetry;

  const ReadRecordDailyView({
    super.key,
    required this.daily,
    required this.formatSeconds,
    this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final data = daily;
    if (data == null) {
      return const Center(child: CircularProgressIndicator());
    }
    final groups = groupDailyByDay(data, DateTime.now());
    if (groups.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('(╮_╰)',
                style: TextStyle(fontSize: 40, color: cs.outline)),
            const SizedBox(height: 16),
            const Text('暂无阅读记录'),
            if (onRetry != null) ...[
              const SizedBox(height: 12),
              TextButton(onPressed: onRetry, child: const Text('重新加载')),
            ],
          ],
        ),
      );
    }
    final rows = <Widget>[];
    for (final group in groups) {
      rows.add(Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
        child: Text(
          group.label,
          style: Theme.of(context).textTheme.titleSmall?.copyWith(
                color: cs.primary,
                fontWeight: FontWeight.w600,
              ),
        ),
      ));
      for (final entry in group.entries) {
        rows.add(ListTile(
          dense: true,
          leading: Icon(Symbols.calendar_today_rounded,
              size: 20, color: cs.onSurfaceVariant),
          title: Text(
            '${entry.date.year}-'
            '${entry.date.month.toString().padLeft(2, '0')}-'
            '${entry.date.day.toString().padLeft(2, '0')}',
          ),
          trailing: Text(
            formatSeconds(entry.seconds),
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  color: cs.onSurfaceVariant,
                ),
          ),
        ));
      }
    }
    return ListView(
      padding: const EdgeInsets.only(bottom: 24),
      children: rows,
    );
  }
}
