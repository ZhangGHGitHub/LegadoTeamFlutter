// 音量键翻页语义闸门（批1b-2a）— 全栈工程师
//
// 语义基准：原版 `legado-upstream/.../ui/book/read/ReadBookActivity.kt`
// `volumeKeyPage(direction, longPress)` → `handleKeyPage`：
// - `keyPageOnLongPress == true`：每个 keydown 都翻页（含长按 repeat）；
// - false：`keyPageDebounce` 中 `longPress == true` 直接 return（忽略长按
//   repeat），非长按按 600ms 节流（leading=true：第一次立即翻，窗口内
//   后续按键不再翻；trailing=false：窗口结束不补翻）。
//
// 原版用 next/prev 两个独立 Debounce（wait=maxWait=600、leading=true、
// trailing=false），观察等价于「每个方向各自维护上次翻页时间，距上次
// 翻页 ≥600ms 才允许下一次」。本类按方向分桶实现同一语义，不使用
// Timer（无挂起回调，不会泄漏；切书/退出只需 reset 清状态）。

/// 音量键翻页节流闸门（纯逻辑，可注入时钟做单测）
class VolumeKeyPageGate {
  VolumeKeyPageGate({
    this.interval = const Duration(milliseconds: 600),
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  /// 同方向两次翻页的最小间隔（原版 `wait = 600L`）
  final Duration interval;

  /// 可注入时钟（测试用；生产为 DateTime.now）
  final DateTime Function() _clock;

  /// 每个方向的上次翻页时间（原版 nextPageDebounce / prevPageDebounce
  /// 两个独立节流器）
  final Map<String, DateTime> _lastTurnAt = <String, DateTime>{};

  /// 是否应执行翻页
  ///
  /// - [keyPageOnLongPress] true：无条件翻页（含 [longPress] repeat）；
  /// - false 且 [longPress]：忽略；
  /// - false 且非长按：距该 [direction] 上次翻页 ≥ [interval] 才翻页，
  ///   并记录本次时间（leading 节流）。
  bool shouldTurnPage({
    required String direction,
    required bool longPress,
    required bool keyPageOnLongPress,
  }) {
    if (keyPageOnLongPress) return true;
    if (longPress) return false;
    final now = _clock();
    final last = _lastTurnAt[direction];
    if (last != null && now.difference(last) < interval) return false;
    _lastTurnAt[direction] = now;
    return true;
  }

  /// 清空节流状态（退出阅读器/切书时调用，防跨书残留）
  void reset() => _lastTurnAt.clear();
}
