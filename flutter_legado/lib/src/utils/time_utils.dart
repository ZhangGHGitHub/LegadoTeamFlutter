/// 时间格式化工具（对标原版 TimeUtils.kt）
library;

import '../l10n/app_strings.dart';

/// 相对时间显示（对标 Long.toTimeAgo）
///
/// 毫秒时间戳 → 「N秒前/N分钟前/N小时前/N天前/N周前/N月前/N年前」，
/// 未来时间显示「…后」。[now] 仅用于测试注入。
String timeAgo(int millis, {DateTime? now}) {
  final curTime = now ?? DateTime.now();
  final diffMs = curTime.millisecondsSinceEpoch - millis;
  final seconds = diffMs.abs() / 1000.0;
  final end =
      diffMs >= 0 ? AppStrings.timeAgoSuffix : AppStrings.timeLaterSuffix;

  final String start;
  if (seconds < 60) {
    start = AppStrings.timeAgoSeconds(seconds.toInt());
  } else if (seconds < 3600) {
    start = AppStrings.timeAgoMinutes((seconds / 60).toInt());
  } else if (seconds < 86400) {
    start = AppStrings.timeAgoHours((seconds / 3600).toInt());
  } else if (seconds < 604800) {
    start = AppStrings.timeAgoDays((seconds / 86400).toInt());
  } else if (seconds < 2628000) {
    start = AppStrings.timeAgoWeeks((seconds / 604800).toInt());
  } else if (seconds < 31536000) {
    start = AppStrings.timeAgoMonths((seconds / 2628000).toInt());
  } else {
    start = AppStrings.timeAgoYears((seconds / 31536000).toInt());
  }
  return start + end;
}
