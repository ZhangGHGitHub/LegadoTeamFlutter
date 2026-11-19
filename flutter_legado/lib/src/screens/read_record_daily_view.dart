import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../l10n/app_strings.dart';

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
    this.pending = false,
    this.masked = false,
  });

  /// [A3] 隐私快照未就绪（首帧竞态）：不显示真实本数/时长
  final bool pending;

  /// [A3] 存在私密未授权记录：本数/时长按已剔除口径显示（调用方已算好）
  final bool masked;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final booksText = pending
        ? AppStrings.readBooksPending
        : AppStrings.readBooksCount(readBooks);
    // 文案只说「未解锁内容」而非强调私密身份：解释被剔除的口径即可
    //（锁定行本身在列表里已可见）。
    final durationText = pending
        ? AppStrings.readTotalPending
        : masked
        ? AppStrings.readTotalMasked(totalDurationText)
        : AppStrings.readTotal(totalDurationText);
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
                      booksText,
                      style: Theme.of(context)
                          .textTheme
                          .titleMedium
                          ?.copyWith(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      durationText,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                            color: cs.onSurfaceVariant,
                          ),
                    ),
                  ],
                ),
              ),
              if (onClearAll != null)
                TextButton(
                    onPressed: onClearAll, child: Text(AppStrings.clearHistory)),
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

/// 解析每日时长记录的 `date` 字段为日期（正常 `yyyy-MM-dd`，兼容 ISO 日期时间）。
///
/// 非法/空/非数字/越界值返回 null，由调用方跳过该行——避免 `int.parse`
/// 在 build 期抛 [FormatException] 影响整页渲染（P3-4）。
DateTime? parseDailyDate(String raw) {
  final value = raw.trim();
  if (value.isEmpty) return null;
  // 兼容 ISO 日期时间：只取日期部分（如 2026-11-13T00:00:00）
  final dateOnly = value.split(RegExp(r'[T ]')).first;
  final parts = dateOnly.split('-');
  if (parts.length != 3) return null;
  final year = int.tryParse(parts[0]);
  final month = int.tryParse(parts[1]);
  final day = int.tryParse(parts[2]);
  if (year == null || month == null || day == null) return null;
  final date = DateTime(year, month, day);
  // 拒绝 2026-13-40 这类越界值（DateTime 会静默进位到别的日期）
  if (date.year != year || date.month != month || date.day != day) {
    return null;
  }
  return date;
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
  final labelToday = AppStrings.dayGroupToday;
  final labelYesterday = AppStrings.dayGroupYesterday;
  final labelEarlier = AppStrings.dayGroupEarlier;
  final groups = <String, List<DailyReadEntry>>{
    labelToday: [],
    labelYesterday: [],
    labelEarlier: [],
  };
  for (final e in daily) {
    final seconds = (e['seconds'] as num?)?.toInt() ?? 0;
    if (seconds <= 0) continue;
    final d = parseDailyDate((e['date'] ?? '').toString());
    if (d == null) continue;
    final label = d == today
        ? labelToday
        : d == yesterday
            ? labelYesterday
            : labelEarlier;
    groups[label]!.add(DailyReadEntry(date: d, seconds: seconds));
  }
  for (final list in groups.values) {
    list.sort((a, b) => b.date.compareTo(a.date));
  }
  return [
    for (final label in [labelToday, labelYesterday, labelEarlier])
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

  /// [A3] 统计被私密脱敏拦截（存在私密未授权记录 → 每日时长聚合不可信）
  final bool privacyMasked;

  /// [A3] 隐私快照尚未就绪（首帧竞态 → 只显示中性占位）
  final bool privacyPending;

  const ReadRecordDailyView({
    super.key,
    required this.daily,
    required this.formatSeconds,
    this.onRetry,
    this.privacyMasked = false,
    this.privacyPending = false,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    // [A3] 首帧竞态：策略/标记未就绪时绝不先渲染真实时长（空快照会把
    // 私密书判成非私密，fail-open）；先给中性占位。
    if (privacyPending) {
      return ReadStatsPrivacyPlaceholder(
        key: const ValueKey('readRecordDailyPrivacyPending'),
        message: AppStrings.readStatsPreparing,
      );
    }
    // [A3] readRecordDaily 只有「日期 + 秒数」两列，无法从聚合值里剔除
    // 私密书贡献的秒数 → 存在私密未授权记录时整段时长不可展示
    //（fail-closed：宁可少展示，也不泄漏私密阅读时长）。
    if (privacyMasked) {
      return ReadStatsPrivacyPlaceholder(
        key: const ValueKey('readRecordDailyPrivacyMasked'),
        message: AppStrings.readStatsPrivateMasked,
      );
    }
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
            Text(AppStrings.noReadRecords),
            if (onRetry != null) ...[
              const SizedBox(height: 12),
              TextButton(
                  onPressed: onRetry, child: Text(AppStrings.reload)),
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

/// [A3] 统计区隐私占位：锁图标 + 中性说明，不渲染任何真实时长/日期
///
/// 两种用途：
/// - 首帧竞态（策略/私密标记未就绪）：不得先渲染明文统计；
/// - 已确认存在私密未授权记录：每日时长聚合不可信（无书籍维度可剔除）。
class ReadStatsPrivacyPlaceholder extends StatelessWidget {
  const ReadStatsPrivacyPlaceholder({super.key, required this.message});

  /// 中性说明文案（不得包含书名/作者/时长）
  final String message;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Symbols.lock_rounded,
            size: 36,
            color: cs.onSurfaceVariant.withValues(alpha: 0.4),
          ),
          const SizedBox(height: 12),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Text(
              message,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: cs.onSurfaceVariant,
                  ),
            ),
          ),
        ],
      ),
    );
  }
}
