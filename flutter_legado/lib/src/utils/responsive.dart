/// 响应式断点与网格计算工具
///
/// 四断点定义（对齐 Material Design 3 窗口尺寸类 + UI_RESTRUCTURE_PLAN.md §六）：
/// - compact <600dp：手机（2-3 列）
/// - medium 600-840dp：平板竖屏（4 列）
/// - expanded 840-1200dp：平板横屏/小桌面（4 列）
/// - large >1200dp：桌面（6 列）
class Responsive {
  Responsive._();

  // ===== 断点常量 =====

  /// 手机小屏上限（dp）—— 2 列
  static const double compactSmallMax = 400;

  /// compact 上限（dp）—— 3 列
  static const double compactMax = 600;

  /// medium 上限（dp）—— 4 列
  static const double mediumMax = 840;

  /// expanded 上限（dp）—— 4 列（宽间距）
  static const double expandedMax = 1200;

  // ===== 窗口尺寸类判断 =====

  /// 是否为 compact 窗口（手机）
  static bool isCompact(double width) => width < compactMax;

  /// 是否为 medium 窗口（平板竖屏）
  static bool isMedium(double width) => width >= compactMax && width < mediumMax;

  /// 是否为 expanded 窗口（平板横屏/小桌面）
  static bool isExpanded(double width) => width >= mediumMax && width < expandedMax;

  /// 是否为 large 窗口（桌面）
  static bool isLarge(double width) => width >= expandedMax;

  // ===== 网格列数计算 =====

  /// 根据可用宽度计算书架网格列数
  ///
  /// <400dp → 2 列 / 400-600dp → 3 列 / 600-1200dp → 4 列 / >1200dp → 6 列
  static int gridColumnsForWidth(double width) {
    if (width < compactSmallMax) return 2;
    if (width < compactMax) return 3;
    if (width < expandedMax) return 4;
    return 6;
  }

  /// 书架网格子项宽高比
  ///
  /// 手机竖卡（0.65），平板/桌面横卡（0.75），参考安卓原版
  static double bookGridChildAspectRatio(double width) {
    return width < compactMax ? 0.65 : 0.75;
  }

  /// RSS 源网格子项宽高比（保持安卓端 item_rss.xml 竖卡比例）
  static double rssGridChildAspectRatio(double width) {
    return width < compactMax ? 0.62 : 0.75;
  }

  // ===== 导航适配 =====

  /// 是否使用侧边导航栏（NavigationRail）
  ///
  /// medium 及以上使用 NavigationRail，compact 使用底部 NavigationBar
  static bool useNavigationRail(double width) => width >= compactMax;

  /// 内容区域最大宽度限制（桌面端居中显示）
  ///
  /// large 窗口时内容不超过 1080dp，避免过度拉伸
  static double? contentMaxWidth(double width) {
    return isLarge(width) ? 1080.0 : null;
  }
}
