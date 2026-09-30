import 'dart:convert';

/// 漫画色彩滤镜配置（对齐原版 MangaColorFilterConfig）
///
/// r/g/b/a：0–255，矩阵系数 `(255 - v) / 255`；
/// l：窗口亮度 0–255（对标 ReadMangaActivity.updateWindowBrightness）。
class MangaColorFilterConfig {
  int r;
  int g;
  int b;
  int a;
  int l;

  MangaColorFilterConfig({
    this.r = 0,
    this.g = 0,
    this.b = 0,
    this.a = 0,
    this.l = 0,
  });

  bool get isIdentity => r == 0 && g == 0 && b == 0 && a == 0;

  factory MangaColorFilterConfig.fromJson(Map<String, dynamic> json) {
    return MangaColorFilterConfig(
      r: (json['r'] as num?)?.toInt() ?? 0,
      g: (json['g'] as num?)?.toInt() ?? 0,
      b: (json['b'] as num?)?.toInt() ?? 0,
      a: (json['a'] as num?)?.toInt() ?? 0,
      l: (json['l'] as num?)?.toInt() ?? 0,
    );
  }

  Map<String, dynamic> toJson() => {
        'r': r,
        'g': g,
        'b': b,
        'a': a,
        'l': l,
      };

  /// 空滤镜写空串（对齐原版 toJson 全 0 返回 ""）
  String toStorage() {
    if (isIdentity && l == 0) return '';
    return jsonEncode(toJson());
  }

  static MangaColorFilterConfig fromStorage(String? raw) {
    if (raw == null || raw.trim().isEmpty) {
      return MangaColorFilterConfig();
    }
    try {
      final map = jsonDecode(raw) as Map<String, dynamic>;
      return MangaColorFilterConfig.fromJson(map);
    } catch (_) {
      return MangaColorFilterConfig();
    }
  }

  /// 对齐原版 MangaAdapter.setImageColorFilter 的 ColorMatrix
  List<double> toColorMatrix() {
    final rr = ((255 - r.clamp(0, 255)) / 255.0);
    final gg = ((255 - g.clamp(0, 255)) / 255.0);
    final bb = ((255 - b.clamp(0, 255)) / 255.0);
    final aa = ((255 - a.clamp(0, 255)) / 255.0);
    return <double>[
      rr, 0, 0, 0, 0,
      0, gg, 0, 0, 0,
      0, 0, bb, 0, 0,
      0, 0, 0, aa, 0,
    ];
  }
}

/// 漫画页脚配置（对齐原版 MangaFooterConfig）
class MangaFooterConfig {
  bool hideChapterLabel;
  bool hideChapter;
  bool hidePageNumberLabel;
  bool hidePageNumber;
  bool hideProgressRatioLabel;
  bool hideProgressRatio;
  /// 0=靠左，1=居中（对齐 ReaderInfoBarView.ALIGN_*）
  int footerOrientation;
  bool hideFooter;
  bool hideChapterName;

  MangaFooterConfig({
    this.hideChapterLabel = false,
    this.hideChapter = false,
    this.hidePageNumberLabel = false,
    this.hidePageNumber = false,
    this.hideProgressRatioLabel = false,
    this.hideProgressRatio = false,
    this.footerOrientation = 0,
    this.hideFooter = false,
    this.hideChapterName = false,
  });

  static const int alignLeft = 0;
  static const int alignCenter = 1;

  factory MangaFooterConfig.fromJson(Map<String, dynamic> json) {
    return MangaFooterConfig(
      hideChapterLabel: json['hideChapterLabel'] as bool? ?? false,
      hideChapter: json['hideChapter'] as bool? ?? false,
      hidePageNumberLabel: json['hidePageNumberLabel'] as bool? ?? false,
      hidePageNumber: json['hidePageNumber'] as bool? ?? false,
      hideProgressRatioLabel: json['hideProgressRatioLabel'] as bool? ?? false,
      hideProgressRatio: json['hideProgressRatio'] as bool? ?? false,
      footerOrientation: (json['footerOrientation'] as num?)?.toInt() ?? 0,
      hideFooter: json['hideFooter'] as bool? ?? false,
      hideChapterName: json['hideChapterName'] as bool? ?? false,
    );
  }

  Map<String, dynamic> toJson() => {
        'hideChapterLabel': hideChapterLabel,
        'hideChapter': hideChapter,
        'hidePageNumberLabel': hidePageNumberLabel,
        'hidePageNumber': hidePageNumber,
        'hideProgressRatioLabel': hideProgressRatioLabel,
        'hideProgressRatio': hideProgressRatio,
        'footerOrientation': footerOrientation,
        'hideFooter': hideFooter,
        'hideChapterName': hideChapterName,
      };

  String toStorage() => jsonEncode(toJson());

  static MangaFooterConfig fromStorage(String? raw) {
    if (raw == null || raw.trim().isEmpty) {
      return MangaFooterConfig();
    }
    try {
      final map = jsonDecode(raw) as Map<String, dynamic>;
      return MangaFooterConfig.fromJson(map);
    } catch (_) {
      return MangaFooterConfig();
    }
  }

  /// 组装页脚文案（对齐 ReadMangaActivity.upInfoBar）
  String buildLabel({
    required String chapterName,
    required int chapterIndex,
    required int chapterSize,
    required int pageIndex,
    required int imageCount,
  }) {
    if (hideFooter) return '';
    final buf = StringBuffer();
    if (!hideChapterName && chapterName.isNotEmpty) {
      buf.write(chapterName);
      buf.write(' ');
    }
    if (!hidePageNumber && imageCount > 0) {
      if (!hidePageNumberLabel) buf.write('页数');
      buf.write('${pageIndex + 1}/$imageCount ');
    }
    if (!hideChapter && chapterSize > 0) {
      if (!hideChapterLabel) buf.write('章节');
      buf.write('${chapterIndex + 1}/$chapterSize ');
    }
    if (!hideProgressRatio && chapterSize > 0) {
      if (!hideProgressRatioLabel) buf.write('总进度');
      final percent = progressPercent(
        chapterIndex: chapterIndex,
        chapterSize: chapterSize,
        pageIndex: pageIndex,
        imageCount: imageCount,
      );
      buf.write(percent);
    }
    return buf.toString().trim();
  }

  /// [P4-3 M4 批1] 总进度百分比文案（对齐原版进度计算；公开供页脚
  /// 内容胶囊组复算样例段值，保证胶囊文案与 buildLabel 预览一致）
  static String progressPercent({
    required int chapterIndex,
    required int chapterSize,
    required int pageIndex,
    required int imageCount,
  }) {
    if (chapterSize == 0 || (imageCount == 0 && chapterIndex == 0)) {
      return '0.0%';
    }
    if (imageCount == 0) {
      final v = ((chapterIndex + 1.0) / chapterSize) * 100;
      return '${v.toStringAsFixed(1)}%';
    }
    var v = (chapterIndex * 1.0 / chapterSize +
            1.0 / chapterSize * (pageIndex + 1) / imageCount) *
        100;
    var text = '${v.toStringAsFixed(1)}%';
    if (text == '100.0%' &&
        (chapterIndex + 1 != chapterSize || pageIndex + 1 != imageCount)) {
      text = '99.9%';
    }
    return text;
  }
}

/// 灰度矩阵（对齐 GrayscaleTransformation）
const List<double> kMangaGrayscaleMatrix = <double>[
  0.299, 0.587, 0.114, 0, 0,
  0.299, 0.587, 0.114, 0, 0,
  0.299, 0.587, 0.114, 0, 0,
  0, 0, 0, 1, 0,
];

/// PreferKey 对齐常量
abstract final class MangaConfigKeys {
  static const colorFilter = 'mangaColorFilter';
  static const footerConfig = 'mangaFooterConfig';
  static const enableEInk = 'enableMangaEInk';
  static const eInkThreshold = 'mangaEInkThreshold';
  static const enableGray = 'enableMangaGray';

  /// [P4-3 E1] 翻页模式（对齐参考版 MangaScrollMode，默认条漫 4）
  static const scrollMode = 'mangaScrollMode';

  /// [P4-3 E3] 自动翻页速度档 1..15（对齐参考版 autoReadSpeed，默认 3；
  /// 开关本身为会话态不落库，对齐参考版 Contract L44 语义）
  static const autoReadSpeed = 'mangaAutoReadSpeed';

  /// [P4-3 E2] 分页适配类型 0..5（对齐参考版 pageScaleType，
  /// Contract L121 默认 0 = 全屏适配）
  static const pageScaleType = 'mangaPageScaleType';

  /// [P4-3 M3 修4] 条漫侧边留白百分比 0..45（对齐参考版 SettingSlider
  /// sidePaddingPercent 0..45，仅条漫路径生效：每侧 padding =
  /// 百分比 × 视口宽；默认 0，单页式模式设置面板不显示此滑杆）
  static const sidePadding = 'mangaSidePadding';

  // ---------------------------------------------------------------------------
  // [P4-3 M4 批2] 行为开关组（键名对齐原版 PreferKey 值：
  // constant/PreferKey.kt L134 disableClickScroll / L136 hideMangaTitle /
  // L219 disableMangaScale / L220 mangaLongClickSaveImage /
  // L221 disableMangaPageAnim；reverseVolumeKeyPage / disableMangaCrossFade
  // 为参考版 MangaSettings 键；mangaBgColor 新增（对齐参考版
  // MangaSettings.background ARGB 整型，默认 0xFF000000））
  // ---------------------------------------------------------------------------

  /// 禁用点击翻页（原版默认 false；九区 1/2 失效，0/3/4 保留）
  static const disableClickScroll = 'disableClickScroll';

  /// 禁用漫画缩放（原版默认 **true**；InteractiveViewer 不渲染）
  static const disableMangaScale = 'disableMangaScale';

  /// 禁用翻页动画（原版默认 false；单页 jumpToPage / 条漫 jumpTo
  /// 替代 animate；自动翻页定时器 animateTo 保留）
  static const disableMangaPageAnim = 'disableMangaPageAnim';

  /// 隐藏漫画列表标题（原版默认 false；我方无章节标题页 →
  /// 映射 0 图卷章分隔页 + 章节导航区标题隐藏）
  static const hideMangaTitle = 'hideMangaTitle';

  /// 长按保存图片（原版默认 **true**；开启时长按直接保存当前页，
  /// 关闭时长按弹页操作菜单）
  static const mangaLongClickSaveImage = 'mangaLongClickSaveImage';

  /// 音量键翻页（原版默认 **true**；平台无按键拦截通道 → 仅登记键，
  /// 行为待平台支持）
  static const volumeKeyPage = 'volumeKeyPage';

  /// 反转音量键翻页方向（参考版默认 false；同上仅登记）
  static const reverseVolumeKeyPage = 'reverseVolumeKeyPage';

  /// 禁用加载淡入动画（参考版键，默认 false = 淡入开启；
  /// 控制漫画图片加载完成淡入）
  static const disableMangaCrossFade = 'disableMangaCrossFade';

  /// 阅读背景颜色（ARGB 整型十进制持久化，默认 0xFF000000 黑；
  /// 接 Scaffold 背景色 = 图片未覆盖区域底色）
  static const mangaBgColor = 'mangaBgColor';

  /// 九区（3x3）点击动作配置（[P4-3 M5] JSON 数组 9 值持久化，
  /// 默认对齐参考版 Contract L167 [-1,-1,1,2,0,1,2,1,1]；
  /// 经设置面板九宫格编辑器循环切换，见 MangaClickActions）
  static const mangaClickActions = 'mangaClickActions';
}

/// [P4-3 M4 批2] 漫画阅读背景色预设色板（ARGB 整型）
///
/// 对齐任务「黑/白/灰/绿/蓝 + 当前色圆点」：五档预设 + 当前色
/// 圆点（当前色不在预设内时追加圆点展示）。默认 [black] 与原版
/// Scaffold 硬编码黑一致（默认行为零变化）。
abstract final class MangaBgColors {
  /// 黑（默认，对齐原版硬编码 Colors.black）
  static const int black = 0xFF000000;

  /// 白
  static const int white = 0xFFFFFFFF;

  /// 深灰
  static const int gray = 0xFF424242;

  /// 护眼绿
  static const int green = 0xFF43752A;

  /// 深蓝
  static const int blue = 0xFF0061A4;

  /// 预设色板（面板渲染顺序）
  static const List<int> all = [black, white, gray, green, blue];

  /// 解析持久化值（十进制 ARGB 字符串）；缺省/非法 → 默认黑
  static int parse(String? raw) {
    final v = int.tryParse(raw ?? '');
    if (v == null || v < 0 || v > 0xFFFFFFFF) return black;
    return v;
  }
}
