/// 响应式断点与网格计算工具
///
/// 统一断点定义（对齐 UI_CONSISTENCY_FIX_PLAN.md §1.1）：
/// - 手机 <400dp：2 列
/// - 中大屏 400-600dp：3 列
/// - 平板 >=600dp：4 列
class Responsive {
  Responsive._();

  /// 手机断点上限（dp）
  static const double phoneMaxWidth = 400;

  /// 平板断点下限（dp）
  static const double tabletMinWidth = 600;

  /// 根据可用宽度计算网格列数
  ///
  /// 手机 <400dp → 2 列 / 中大屏 400-600dp → 3 列 / 平板 >=600dp → 4 列
  static int gridColumnsForWidth(double width) {
    if (width < phoneMaxWidth) return 2;
    if (width < tabletMinWidth) return 3;
    return 4;
  }

  /// 书架网格子项宽高比
  ///
  /// 手机竖卡（0.65），平板横卡（0.75），参考安卓原版
  static double bookGridChildAspectRatio(double width) {
    return width < phoneMaxWidth ? 0.65 : 0.75;
  }

  /// RSS 源网格子项宽高比（保持安卓端 item_rss.xml 竖卡比例）
  static double rssGridChildAspectRatio(double width) {
    return width < phoneMaxWidth ? 0.62 : 0.75;
  }
}
