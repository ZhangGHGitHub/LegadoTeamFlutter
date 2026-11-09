/// 书签标记锚点/样式领域模型（契约 §2.52，批7b-2a）
///
/// 对齐参考版：
/// - `domain/model/BookContentProcessModels.kt` 的 `TextProcessAnchor` /
///   `TextProcessStyle` / `MarkingEffect`；
/// - `SaveMarkingUseCase.kt:50-147` 的锚点比对与 `normalizeProcessText`；
/// - `MarkingSheet.kt` 的 16 预设色、7 效果格与默认色 `0xFF63C37D`。
///
/// `anchorJson` / `styleJson` 均为本文件模型序列化后的 JSON 字符串，
/// 由 Dart 构造并写入 `book_marks`；Rust 侧只要求 `anchorJson` 非空，
/// 内容解析与渲染属 7b-2b。
library;

import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'highlight_style.dart';

/// 标记锚点（章节内定位 + 归一化文本哈希）
class BookMarkingAnchor {
  const BookMarkingAnchor({
    required this.chapterIndex,
    this.chapterPosition,
    required this.selectedText,
    this.contextBefore = '',
    this.contextAfter = '',
    required this.normalizedTextHash,
  });

  /// 章节索引
  final int chapterIndex;

  /// 章节内字符位置（排版坐标，可空）
  final int? chapterPosition;

  /// 归一化后的选中文本
  final String selectedText;

  /// 选区前文（定位消歧用）
  final String contextBefore;

  /// 选区后文（定位消歧用）
  final String contextAfter;

  /// [selectedText] 的 MD5（对齐参考版 `normalizedTextHash`）
  final String normalizedTextHash;

  factory BookMarkingAnchor.fromJson(Map<String, dynamic> json) {
    return BookMarkingAnchor(
      chapterIndex: json['chapterIndex'] is num
          ? (json['chapterIndex'] as num).toInt()
          : 0,
      chapterPosition: json['chapterPosition'] is num
          ? (json['chapterPosition'] as num).toInt()
          : null,
      selectedText: (json['selectedText'] ?? '').toString(),
      contextBefore: (json['contextBefore'] ?? '').toString(),
      contextAfter: (json['contextAfter'] ?? '').toString(),
      normalizedTextHash: (json['normalizedTextHash'] ?? '').toString(),
    );
  }

  /// 宽松解析：null/空串/非法 JSON/非对象 → null（旧数据或损坏行不阻断列表）
  static BookMarkingAnchor? tryParse(String? raw) {
    if (raw == null || raw.trim().isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) {
        return BookMarkingAnchor.fromJson(decoded);
      }
      if (decoded is Map) {
        return BookMarkingAnchor.fromJson(Map<String, dynamic>.from(decoded));
      }
    } catch (_) {
      // 解析失败按无锚点处理
    }
    return null;
  }

  Map<String, dynamic> toJson() => {
    'chapterIndex': chapterIndex,
    'chapterPosition': chapterPosition,
    'selectedText': selectedText,
    'contextBefore': contextBefore,
    'contextAfter': contextAfter,
    'normalizedTextHash': normalizedTextHash,
  };

  String encode() => jsonEncode(toJson());
}

/// 标记样式（参考版 `TextProcessStyle`）
class BookMarkingStyle {
  const BookMarkingStyle({
    this.textColor,
    this.bgColor,
    this.underlineMode = 0,
    this.underlineColor,
    this.underlineWidth = 1,
    this.underlineOffset = 2,
    this.underlineSvgPath,
  });

  /// 字体色（ARGB）
  final int? textColor;

  /// 背景色（ARGB；BG 效果自动 20% alpha）
  final int? bgColor;

  /// 下划线模式：0 无 / 1 单实线 / 2 虚线 / 3 波浪 / 6 删除线 / 7 荧光
  final int underlineMode;

  /// 下划线颜色（ARGB）
  final int? underlineColor;

  /// 下划线宽度（dp，默认 1）
  final double underlineWidth;

  /// 下划线偏移（dp，默认 2）
  final double underlineOffset;

  /// 自定义下划线 SVG 路径（预留；本批不渲染）
  final String? underlineSvgPath;

  factory BookMarkingStyle.fromJson(Map<String, dynamic> json) {
    double asDouble(Object? raw, double fallback) =>
        raw is num ? raw.toDouble() : fallback;
    int? asColor(Object? raw) => raw is num ? raw.toInt() : null;
    return BookMarkingStyle(
      textColor: asColor(json['textColor']),
      bgColor: asColor(json['bgColor']),
      underlineMode: json['underlineMode'] is num
          ? (json['underlineMode'] as num).toInt()
          : 0,
      underlineColor: asColor(json['underlineColor']),
      underlineWidth: asDouble(json['underlineWidth'], 1),
      underlineOffset: asDouble(json['underlineOffset'], 2),
      underlineSvgPath: json['underlineSvgPath'] is String
          ? json['underlineSvgPath'] as String
          : null,
    );
  }

  /// 宽松解析：null/空串/非法 JSON/非对象 → null
  static BookMarkingStyle? tryParse(String? raw) {
    if (raw == null || raw.trim().isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) {
        return BookMarkingStyle.fromJson(decoded);
      }
      if (decoded is Map) {
        return BookMarkingStyle.fromJson(Map<String, dynamic>.from(decoded));
      }
    } catch (_) {
      // 解析失败按默认样式处理
    }
    return null;
  }

  Map<String, dynamic> toJson() => {
    'textColor': textColor,
    'bgColor': bgColor,
    'underlineMode': underlineMode,
    'underlineColor': underlineColor,
    'underlineWidth': underlineWidth,
    'underlineOffset': underlineOffset,
    'underlineSvgPath': underlineSvgPath,
  };

  String encode() => jsonEncode(toJson());

  /// 转换为正文渲染使用的 `HighlightStyle`（批7b-2b）
  ///
  /// 映射约定（对齐参考版 `MarkingEffect.toStyle` 的渲染语义）：
  /// - mode 1/3/2（单实线/波浪/虚线）→ `underline`；
  /// - mode 6（删除线）→ `strike`，**不加上划线**；
  /// - mode 7（荧光）→ `fill=(显示色 & 0x00FFFFFF) | 0x33000000`
  ///   （**整行 20% 背景近似**，参考版荧光笔的半高绘制未复刻，登记差异）；
  /// - BG → `fill=bgColor`（无 bgColor 则不产生效果）；
  /// - TEXT → `textColor`；
  /// - mode 5（SVG 下划线）→ 回退单实线 SOLID（SVG 路径本批不渲染，登记）；
  /// - mode 0/未知 → 无效果。
  ///
  /// 线色为空/0 时回退展示色（`MarkingEffect.colorOf`）。
  HighlightStyle toHighlightStyle() {
    final fallbackColor = MarkingEffect.colorOf(this);
    final lineColor = (underlineColor == null || underlineColor == 0)
        ? fallbackColor
        : underlineColor!;
    const kindByMode = {1: 'SOLID', 3: 'WAVY', 2: 'DASHED'};
    final kind =
        kindByMode[underlineMode] ?? (underlineMode == 5 ? 'SOLID' : null);
    if (kind != null) {
      return HighlightStyle(
        underline: HighlightUnderline(
          kind: kind,
          color: lineColor,
          width: underlineWidth,
          distance: underlineOffset,
        ),
      );
    }
    if (underlineMode == 6) {
      return HighlightStyle(strike: true, strikeColor: lineColor);
    }
    if (underlineMode == 7) {
      return HighlightStyle(fill: (lineColor & 0x00FFFFFF) | 0x33000000);
    }
    if (bgColor != null && bgColor != 0) {
      return HighlightStyle(fill: bgColor!);
    }
    if (textColor != null && textColor != 0) {
      return HighlightStyle(textColor: textColor!);
    }
    return HighlightStyle.empty;
  }

  BookMarkingStyle copyWith({
    Object? textColor = _unset,
    Object? bgColor = _unset,
    int? underlineMode,
    Object? underlineColor = _unset,
    double? underlineWidth,
    double? underlineOffset,
    Object? underlineSvgPath = _unset,
  }) {
    return BookMarkingStyle(
      textColor: identical(textColor, _unset)
          ? this.textColor
          : textColor as int?,
      bgColor: identical(bgColor, _unset) ? this.bgColor : bgColor as int?,
      underlineMode: underlineMode ?? this.underlineMode,
      underlineColor: identical(underlineColor, _unset)
          ? this.underlineColor
          : underlineColor as int?,
      underlineWidth: underlineWidth ?? this.underlineWidth,
      underlineOffset: underlineOffset ?? this.underlineOffset,
      underlineSvgPath: identical(underlineSvgPath, _unset)
          ? this.underlineSvgPath
          : underlineSvgPath as String?,
    );
  }

  static const _unset = Object();
}

/// 标记效果（参考版 `MarkingEffect`，顺序即 UI 7 效果格顺序）
enum MarkingEffect {
  solid('单实线'),
  wave('波浪线'),
  dashed('虚线'),
  strike('删除线'),
  highlight('荧光'),
  bg('背景色'),
  text('字体色');

  const MarkingEffect(this.label);

  /// UI 文案
  final String label;

  /// 标记默认颜色（参考版 `MarkingEffect.DEFAULT_COLOR`）
  static const int defaultColor = 0xFF63C37D;

  /// 是否属于下划线类效果（对应 underlineMode != 0）
  bool get isUnderline =>
      this == solid || this == wave || this == dashed ||
      this == strike || this == highlight;

  /// 由效果 + 选中颜色生成样式
  ///
  /// 背景色自动半透明（约 20% alpha），避免不透明背景盖住正文；
  /// 下划线/荧光/字体色用原色（透明度由所选颜色的 alpha 决定）。
  BookMarkingStyle toStyle(int color) => switch (this) {
    MarkingEffect.solid => BookMarkingStyle(
      underlineMode: 1,
      underlineColor: color,
    ),
    MarkingEffect.wave => BookMarkingStyle(
      underlineMode: 3,
      underlineColor: color,
    ),
    MarkingEffect.dashed => BookMarkingStyle(
      underlineMode: 2,
      underlineColor: color,
    ),
    MarkingEffect.strike => BookMarkingStyle(
      underlineMode: 6,
      underlineColor: color,
    ),
    MarkingEffect.highlight => BookMarkingStyle(
      underlineMode: 7,
      underlineColor: color,
    ),
    MarkingEffect.bg => BookMarkingStyle(
      bgColor: (color & 0x00FFFFFF) | 0x33000000,
    ),
    MarkingEffect.text => BookMarkingStyle(textColor: color),
  };

  /// 从样式反推效果；未知下划线模式回退单实线
  static MarkingEffect fromStyle(BookMarkingStyle? style) {
    switch (style?.underlineMode) {
      case 1:
        return MarkingEffect.solid;
      case 3:
        return MarkingEffect.wave;
      case 2:
        return MarkingEffect.dashed;
      case 6:
        return MarkingEffect.strike;
      case 7:
        return MarkingEffect.highlight;
    }
    if (style?.bgColor != null) return MarkingEffect.bg;
    if (style?.textColor != null) return MarkingEffect.text;
    return MarkingEffect.solid;
  }

  /// 取样式的展示色：下划线取线色，背景剥掉 alpha 取底色，字体取字色
  ///
  /// 0 视为「未设置」（ARGB 全透明），继续按下一优先级回退。
  static int colorOf(BookMarkingStyle? style) {
    final underline = style?.underlineColor;
    if (underline != null && underline != 0) return underline;
    final bg = style?.bgColor;
    if (bg != null && bg != 0) return (bg & 0x00FFFFFF) | 0xFF000000;
    final text = style?.textColor;
    if (text != null && text != 0) return text;
    return defaultColor;
  }
}

/// 16 预设色（对齐参考版 `MarkingPresetColors`，顺序一致）
const List<int> kMarkingPresetColors = [
  0xFFF44848, // 红
  0xFFFF7417, // 橙
  0xFFFFC107, // 琥珀
  0xFFFFEB3B, // 黄
  0xFF9CCC65, // 黄绿
  0xFF22C55E, // 绿
  0xFF18B5A4, // 青绿
  0xFF26C6DA, // 青
  0xFF3B82F6, // 蓝
  0xFF5C6BC0, // 靛蓝
  0xFF9C27B0, // 紫
  0xFFA855F7, // 亮紫
  0xFFEC4899, // 粉
  0xFF9A4D0F, // 棕
  0xFF607D8B, // 蓝灰
  0xFF111111, // 黑
];

/// 参考版 `BookContentProcessEngine.normalizeProcessText`：
/// 逐行 trim（code <= 0x20 或全角空格 U+3000），再整体 trim。
String normalizeMarkingText(String text) {
  bool isTrimChar(int code) => code <= 0x20 || code == 0x3000;
  // Kotlin String.lines() 按 \r\n / \n / \r 切分；统一换行后逐行 trim
  final lines = text.split(RegExp(r'\r\n|\r|\n')).map((line) {
    var start = 0;
    var end = line.length;
    while (start < end && isTrimChar(line.codeUnitAt(start))) {
      start++;
    }
    while (end > start && isTrimChar(line.codeUnitAt(end - 1))) {
      end--;
    }
    return line.substring(start, end);
  });
  final joined = lines.join('\n');
  var start = 0;
  var end = joined.length;
  while (start < end && isTrimChar(joined.codeUnitAt(start))) {
    start++;
  }
  while (end > start && isTrimChar(joined.codeUnitAt(end - 1))) {
    end--;
  }
  return joined.substring(start, end);
}

/// 归一化文本的 MD5（对应参考版 `normalizedTextHash`）
String markingTextHash(String normalizedText) =>
    md5.convert(utf8.encode(normalizedText)).toString();

/// 构造锚点（统一归一化与哈希口径）
BookMarkingAnchor buildBookMarkingAnchor({
  required int chapterIndex,
  required int chapterPosition,
  required String selectedText,
  String contextBefore = '',
  String contextAfter = '',
}) {
  final normalized = normalizeMarkingText(selectedText);
  return BookMarkingAnchor(
    chapterIndex: chapterIndex,
    chapterPosition: chapterPosition,
    selectedText: normalized,
    contextBefore: contextBefore,
    contextAfter: contextAfter,
    normalizedTextHash: markingTextHash(normalized),
  );
}
