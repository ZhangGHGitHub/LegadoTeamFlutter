import 'package:flutter/painting.dart';

/// [P4-3 E2] 漫画分页适配类型（对齐参考版 MangaPageScaleType）
///
/// 取证（参考版 legado-with-MD3）：
/// - ui/book/manga/config/MangaPageConfig.kt L3-10：
///   FIT_SCREEN=0 / STRETCH=1 / FIT_WIDTH=2 / FIT_HEIGHT=3 /
///   ORIGINAL=4 / SMART_FIT=5；
/// - ui/book/manga/MangaReaderContract.kt L121：pageScaleType 默认 0；
/// - ui/book/manga/MangaReaderScreen.kt L1463-1472 单页式映射
///   （ContentScale → Flutter BoxFit 等价：Fit≈contain、
///   FillBounds≈fill、FillWidth≈fitWidth、FillHeight≈fitHeight、
///   None≈none）：
///   ```
///   isWidePage && widePageMode==FIT_WIDTH → FillWidth（宽页模式，仅登记）
///   STRETCH    → FillBounds
///   FIT_WIDTH  → FillWidth
///   FIT_HEIGHT → FillHeight
///   ORIGINAL   → None
///   SMART_FIT && isWidePage → FillWidth（宽页按宽铺满，窄页 contain）
///   else       → Fit
///   ```
/// - 同文件 L1568：条漫（WebtoonMangaList 单页）恒 ContentScale.FillWidth；
/// - MangaSettingsPanel.kt L372-386：非条漫模式显示「页面适配」6 选项下拉
///   → UpdateSetting(PAGE_SCALE_TYPE)（MangaReaderViewModel L816 持久化）。
abstract final class MangaPageScaleType {
  /// 全屏适配（等比完整显示，ContentScale.Fit ≈ BoxFit.contain）
  static const int fitScreen = 0;

  /// 拉伸（不保持比例铺满，ContentScale.FillBounds ≈ BoxFit.fill）
  static const int stretch = 1;

  /// 适配宽度（ContentScale.FillWidth ≈ BoxFit.fitWidth）
  static const int fitWidth = 2;

  /// 适配高度（ContentScale.FillHeight ≈ BoxFit.fitHeight）
  static const int fitHeight = 3;

  /// 原始大小（ContentScale.None ≈ BoxFit.none）
  static const int original = 4;

  /// 智能适配（宽页按宽铺满，窄页 contain）
  static const int smartFit = 5;

  /// 缺省（对齐参考版 MangaReaderContract L121 pageScaleType 默认 0）
  static const int defaultValue = fitScreen;

  /// 合法取值集合
  static const Set<int> valid = {
    fitScreen,
    stretch,
    fitWidth,
    fitHeight,
    original,
    smartFit,
  };

  /// 从配置原文解析；空 / 非法 / 越界 → 默认 0（对齐 MangaScrollModes.parse
  /// 的 valid 集合语义：越界不 clamp，回退缺省）
  static int parse(String? raw) {
    final v = int.tryParse((raw ?? '').trim());
    return (v != null && valid.contains(v)) ? v : defaultValue;
  }

  /// 单页式渲染 BoxFit（对齐参考版 L1463-1472 映射）
  ///
  /// [isWidePage] 仅 SMART_FIT 参与（宽页 → fitWidth）；图片解码前宽高比
  /// 未知，屏内按 false 传入（窄页语义），宽页分支属宽页模式范畴，
  /// 本波仅登记不实现（见 [MangaWidePageMode] 注释）。
  static BoxFit fitFor({required int type, bool isWidePage = false}) {
    switch (type) {
      case stretch:
        return BoxFit.fill;
      case fitWidth:
        return BoxFit.fitWidth;
      case fitHeight:
        return BoxFit.fitHeight;
      case original:
        return BoxFit.none;
      case smartFit:
        return isWidePage ? BoxFit.fitWidth : BoxFit.contain;
      case fitScreen:
      default:
        return BoxFit.contain;
    }
  }

  /// 条漫恒 fitWidth（对齐参考版 L1568 ContentScale.FillWidth）
  static BoxFit get webtoonFit => BoxFit.fitWidth;

  /// 设置面板下拉选项（对齐参考版 L376-382 顺序 [0,1,2,3,4,5]）
  static const List<int> options = [
    fitScreen,
    stretch,
    fitWidth,
    fitHeight,
    original,
    smartFit,
  ];

  /// 下拉文案（参考版 strings.xml L3363-3369 为中文化案对齐）
  static String labelOf(int type) {
    switch (type) {
      case stretch:
        return '拉伸';
      case fitWidth:
        return '适配宽度';
      case fitHeight:
        return '适配高度';
      case original:
        return '原始大小';
      case smartFit:
        return '智能适配';
      case fitScreen:
      default:
        return '全屏适配';
    }
  }
}

/// [P4-3 E2] 宽页模式常量登记（对齐参考版 MangaPageConfig.kt L19-23）
///
/// 仅登记取值，本波不实现行为（wide page 变体在 P4-3 后续波次）。
abstract final class MangaWidePageMode {
  static const int normal = 0;
  static const int fitWidth = 1;
  static const int rotateToFit = 2;
  static const int split = 3;
}

/// [P4-3 E2] 双页模式常量登记（对齐参考版 MangaPageConfig.kt L26-30）
///
/// 仅登记取值，本波不实现行为（double page 变体在 P4-3 后续波次）。
abstract final class MangaDoublePageMode {
  static const int off = 0;
  static const int landscape = 1;
  static const int always = 2;
}
