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
      final percent = _progressPercent(
        chapterIndex: chapterIndex,
        chapterSize: chapterSize,
        pageIndex: pageIndex,
        imageCount: imageCount,
      );
      buf.write(percent);
    }
    return buf.toString().trim();
  }

  static String _progressPercent({
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
}
