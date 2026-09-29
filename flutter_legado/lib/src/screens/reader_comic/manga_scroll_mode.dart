import 'package:flutter/widgets.dart';

/// [P4-3 E1] 漫画翻页模式常量与解析（对齐参考版 MangaScrollMode）
///
/// 取证（参考版 legado-with-MD3）：
/// - ui/book/manga/config/MangaScrollMode.kt L3-9：
///   PAGE_LEFT_TO_RIGHT=1 / PAGE_RIGHT_TO_LEFT=2 / PAGE_TOP_TO_BOTTOM=3 /
///   WEBTOON=4 / WEBTOON_WITH_GAP=5；
/// - ui/book/manga/MangaReaderContract.kt L117：默认 WEBTOON(4)；
/// - ui/book/manga/MangaSettingsPanel.kt 阅读模式下拉
///   [条漫, 条漫（间隔）, 从左到右, 从右到左, 从上到下] = [4, 5, 1, 2, 3]；
/// - ui/book/manga/MangaReaderScreen.kt L506/508/807-809：
///   WEBTOON_WITH_GAP 页面间 8.dp 间距。
abstract final class MangaScrollModes {
  /// 从左到右翻页（横向 PageView，左滑下一页）
  static const int pageLeftToRight = 1;

  /// 从右到左翻页（横向 PageView，首页在右，右滑下一页；日漫方向）
  static const int pageRightToLeft = 2;

  /// 从上到下翻页（纵向 PageView，上滑下一页）
  static const int pageTopToBottom = 3;

  /// 条漫（纵向连续滚动 ListView，默认）
  static const int webtoon = 4;

  /// 条漫（间隔）（纵向 ListView，页间 8px 间距）
  static const int webtoonWithGap = 5;

  /// 未配置 / 解析失败时的缺省（对齐参考版 MangaReaderContract 默认值）
  static const int defaultValue = webtoon;

  /// 条漫（间隔）页间间距（参考版 8.dp，实现为 4px 上 + 4px 下包裹）
  static const int gap = 8;

  /// 合法模式集合
  static const Set<int> valid = {
    pageLeftToRight,
    pageRightToLeft,
    pageTopToBottom,
    webtoon,
    webtoonWithGap,
  };

  /// 从配置原文解析模式；空 / 非法值回退缺省 4（条漫）
  static int parse(String? raw) {
    final v = int.tryParse((raw ?? '').trim());
    return (v != null && valid.contains(v)) ? v : defaultValue;
  }

  /// 是否单页式（PageView 路径）：1/2/3
  static bool isPaged(int mode) =>
      mode == pageLeftToRight ||
      mode == pageRightToLeft ||
      mode == pageTopToBottom;

  /// 是否条漫（ListView 连续滚动路径）：4/5
  static bool isWebtoon(int mode) =>
      mode == webtoon || mode == webtoonWithGap;

  /// 滚动轴：T2B 纵向，L2R/R2L 横向
  static Axis axisOf(int mode) =>
      mode == pageTopToBottom ? Axis.vertical : Axis.horizontal;

  /// 是否右起（R2L）：显示索引与逻辑页序反转（首页在最右）
  static bool isReversed(int mode) => mode == pageRightToLeft;

  /// 设置面板下拉文案（对齐参考版 MangaSettingsPanel 选项文案）
  static String labelOf(int mode) {
    switch (mode) {
      case pageLeftToRight:
        return '从左到右';
      case pageRightToLeft:
        return '从右到左';
      case pageTopToBottom:
        return '从上到下';
      case webtoonWithGap:
        return '条漫（间隔）';
      case webtoon:
      default:
        return '条漫';
    }
  }

  /// 设置面板下拉选项（对齐参考版 [条漫, 条漫（间隔）, 从左到右, 从右到左, 从上到下]）
  static const List<int> options = [webtoon, webtoonWithGap, pageLeftToRight, pageRightToLeft, pageTopToBottom];
}
