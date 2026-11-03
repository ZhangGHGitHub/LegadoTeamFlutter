import 'dart:ui' show Size;

/// 多栏布局模式（键 `multiPaneMode`，键名与取值逐字对齐参考版
/// `PreferKey.multiPaneMode` / `MultiPaneMode`）。
///
/// 判定只依赖**当前窗口尺寸**，不依赖设备类型/屏幕方向锁定：同一台平板在
/// 自由窗口里缩到手机宽度时，多栏必须让位给单栏（参考版
/// `AppAdaptiveNavigation.kt:56-85`、`MainAdaptiveLayout.kt:150-181`）。
enum MultiPaneMode {
  /// 自动：窗口宽 ≥840dp 时启用（参考版 Expanded 断点，默认值）
  auto,

  /// 横屏：窗口宽 > 高且宽 ≥840dp 时启用
  landscape,

  /// 始终：窗口宽 ≥744dp（左 360 + 间距 24 + 右 360）时启用
  always,

  /// 关闭：永不启用
  off;

  /// 持久化字符串解析（未知/空值回退 [auto]，对齐参考版
  /// `MultiPaneMode.parse` 的 auto 兜底）
  static MultiPaneMode fromName(String? name) {
    for (final mode in MultiPaneMode.values) {
      if (mode.name == name) return mode;
    }
    return MultiPaneMode.auto;
  }
}

/// 自动/横屏模式的宽度断点（dp，参考版 WindowSizeClass Expanded 下界）
const double kMultiPaneExpandedBreakpoint = 840;

/// 「始终」模式的宽度断点（dp，参考版 `shouldUseListDetail` 的 744）
const double kMultiPaneAlwaysBreakpoint = 744;

/// 左栏最小/默认宽度（dp）。参考版容器左栏在含导航栏时取 420dp；
/// 我方 Rail 在 PageView 外层、左栏内容区不含 Rail，故统一 360dp
///（差异已登记，见批次说明）。
const double kMultiPaneLeftWidth = 360;

/// 右栏最小/默认宽度（dp）
const double kMultiPaneRightWidth = 360;

/// 两栏间距（dp，Material 列表-详情规范值）
const double kMultiPaneGap = 24;

/// 可用高度下限（dp）：过矮窗口即使够宽也不分栏
const double kMultiPaneMinHeight = 320;

/// 判定当前窗口是否应切换为双栏。
///
/// 语义（对齐参考版 `shouldUseListDetail` + `paneLayout`）：
/// - [MultiPaneMode.off]：false；
/// - 可用高度 < [minHeight]：false；
/// - 可用宽度 < leftWidth + gap + rightWidth：false（两栏都放不下，
///   即使模式为 always 也不启用）；
/// - auto：窗口宽 ≥840；
/// - landscape：窗口宽 > 高且宽 ≥840；
/// - always：窗口宽 ≥744。
///
/// [available] 是**扣掉导航 Rail 后**的实际窗格区域（LayoutBuilder 约束），
/// 用于左右最小宽度/高度判定；[windowSize] 是完整窗口尺寸（不扣 Rail），
/// 用于模式阈值与横屏方向。两者分开是必须的：默认 auto 下 840dp 窗口
/// 扣掉 Rail 后窗格约 760dp，若拿窗格宽比 840 会永远不分栏。
/// [windowSize] 为空时回落 [available]（无 Rail 场景/纯函数单测）。
///
/// [leftWidth]/[rightWidth]/[gap]/[minHeight] 可覆盖：参考版容器左栏
/// （含导航栏）按 420dp 计算时，744dp 的「始终」下限会被最小尺寸检查
/// 抬到 804dp——本函数保持同样的「先看模式阈值、再看最小尺寸」口径。
bool resolveMultiPane(
  MultiPaneMode mode,
  Size available, {
  Size? windowSize,
  double leftWidth = kMultiPaneLeftWidth,
  double rightWidth = kMultiPaneRightWidth,
  double gap = kMultiPaneGap,
  double minHeight = kMultiPaneMinHeight,
}) {
  if (mode == MultiPaneMode.off) return false;
  if (!available.width.isFinite || !available.height.isFinite) return false;
  final window = windowSize ?? available;
  if (!window.width.isFinite || !window.height.isFinite) return false;
  if (available.height < minHeight) return false;
  if (available.width < leftWidth + gap + rightWidth) return false;
  return switch (mode) {
    MultiPaneMode.auto => window.width >= kMultiPaneExpandedBreakpoint,
    MultiPaneMode.landscape =>
      window.width > window.height &&
          window.width >= kMultiPaneExpandedBreakpoint,
    MultiPaneMode.always => window.width >= kMultiPaneAlwaysBreakpoint,
    MultiPaneMode.off => false,
  };
}
