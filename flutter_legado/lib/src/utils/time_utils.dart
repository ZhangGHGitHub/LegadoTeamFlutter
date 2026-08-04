/// 时间格式化工具（对标原版 TimeUtils.kt）
library;

/// 相对时间显示（对标 Long.toTimeAgo）
///
/// 毫秒时间戳 → 「N秒前/N分钟前/N小时前/N天前/N周前/N月前/N年前」，
/// 未来时间显示「…后」。[now] 仅用于测试注入。
String timeAgo(int millis, {DateTime? now}) {
  final curTime = now ?? DateTime.now();
  final diffMs = curTime.millisecondsSinceEpoch - millis;
  final seconds = diffMs.abs() / 1000.0;
  final end = diffMs >= 0 ? '前' : '后';

  final String start;
  if (seconds < 60) {
    start = '${seconds.toInt()}秒';
  } else if (seconds < 3600) {
    start = '${(seconds / 60).toInt()}分钟';
  } else if (seconds < 86400) {
    start = '${(seconds / 3600).toInt()}小时';
  } else if (seconds < 604800) {
    start = '${(seconds / 86400).toInt()}天';
  } else if (seconds < 2628000) {
    start = '${(seconds / 604800).toInt()}周';
  } else if (seconds < 31536000) {
    start = '${(seconds / 2628000).toInt()}月';
  } else {
    start = '${(seconds / 31536000).toInt()}年';
  }
  return start + end;
}
