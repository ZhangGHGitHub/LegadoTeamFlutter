/// 正文高亮样式与命中区间模型（批34）
///
/// 对齐 Android 原版 `HighlightStyle` / `HighlightRuleMatcher.RuleMatch`
/// 的 JSON 形态：
/// - style 是原版 `HighlightStyle` 完整 JSON（fill / fillShape / textColor /
///   bold / italic / underline / strike / box / emphasis / shadow / ...）；
/// - Rust `highlightRuleMatch` 返回 `{ruleId, start, end, order, styleJson}`，
///   `start/end` 为 UTF-16 code unit 半开区间。
///
/// 本文件不依赖 Flutter（只做解析），渲染映射见
/// `widgets/reader/highlight_span_builder.dart`。
library;

import 'dart:convert';

/// 下划线样式（对齐原版 `HighlightStyle.Underline`）
class HighlightUnderline {
  const HighlightUnderline({
    this.kind = 'SOLID',
    this.color = 0,
    this.width = 1,
    this.distance = 0,
  });

  /// 线型：SOLID / WAVY / DASHED / DOTTED / DOUBLE
  final String kind;

  /// 线色（ARGB，0=跟随文字色）
  final int color;

  /// 线宽（dp）
  final double width;

  /// 线距（dp，Flutter TextStyle 无对应能力，MVP 不渲染）
  final double distance;

  factory HighlightUnderline.fromMap(Map<String, dynamic> map) {
    final rawKind = map['kind'];
    return HighlightUnderline(
      kind: rawKind is String && rawKind.isNotEmpty
          ? rawKind.toUpperCase()
          : 'SOLID',
      color: normalizeArgb(map['color']),
      width: _asDouble(map['width']) ?? 1,
      distance: _asDouble(map['distance']) ?? 0,
    );
  }

  Map<String, dynamic> toMap() => {
    'kind': kind,
    'color': color,
    'width': width,
    'distance': distance,
  };
}

/// 正文高亮样式（只读解析，未知键原样保留在 [extra]）
class HighlightStyle {
  const HighlightStyle({
    this.fill = 0,
    this.fillShape,
    this.textColor = 0,
    this.bold = false,
    this.italic = false,
    this.underline,
    this.strike = false,
    this.strikeColor = 0,
    this.extra = const {},
  });

  /// 背景填充色（ARGB，0=无填充）
  final int fill;

  /// 填充形状：RECTANGLE / ROUNDED / MARKER / HALF / BASELINE / PILL
  ///
  /// MVP 渲染统一按矩形绘制（形状差异登记为未实现）。
  final String? fillShape;

  /// 前景文字色（ARGB，0=不改色）
  final int textColor;

  /// 是否加粗（MVP 不渲染：会改变字体度量）
  final bool bold;

  /// 是否斜体（MVP 不渲染：会改变字体度量）
  final bool italic;

  /// 下划线（null=无）
  final HighlightUnderline? underline;

  /// 是否删除线（原版 `strike: Deco?`，字段存在即启用）
  final bool strike;

  /// 删除线颜色（ARGB，0=跟随文字色）
  final int strikeColor;

  /// 未建模/未知键（原样保留，便于后续扩展与调试）
  final Map<String, dynamic> extra;

  /// 空样式（无任何可渲染效果）
  static const HighlightStyle empty = HighlightStyle();

  /// 已建模的键集合（解析时其余键进入 [extra]）
  static const Set<String> _knownKeys = {
    'fill',
    'fillShape',
    'textColor',
    'bold',
    'italic',
    'underline',
    'strike',
    'pillPaddingScale',
    'box',
    'emphasis',
    'shadow',
    'fontPath',
    'fontSize',
    'letterSpacing',
    'horizontalPadding',
    'reserveTextSpace',
  };

  /// 是否有 MVP 可渲染的效果（颜色/背景/下划线/删除线）
  ///
  /// 注意：bold/italic 不算——本批明确不渲染字体度量变更。
  bool get hasRenderableEffect =>
      textColor != 0 || fill != 0 || underline != null || strike;

  /// 解析 style JSON 字符串；空/非法/非对象返回 [empty]（不抛错）
  factory HighlightStyle.parse(String? rawStyle) {
    if (rawStyle == null || rawStyle.trim().isEmpty) {
      return HighlightStyle.empty;
    }
    try {
      final decoded = jsonDecode(rawStyle);
      if (decoded is Map<String, dynamic>) {
        return HighlightStyle.fromMap(decoded);
      }
    } catch (_) {
      // 非法 style 静默按无样式处理（对齐原版 styleObj 容错语义）
    }
    return HighlightStyle.empty;
  }

  /// 从已解码的 style map 解析（未知键保留在 [extra]）
  factory HighlightStyle.fromMap(Map<String, dynamic> map) {
    final underlineRaw = map['underline'];
    HighlightUnderline? underline;
    if (underlineRaw is Map) {
      underline = HighlightUnderline.fromMap(
        underlineRaw.map((k, v) => MapEntry(k.toString(), v)),
      );
    }

    final strikeRaw = map['strike'];
    final strike = strikeRaw is Map;
    final strikeColor = strikeRaw is Map ? normalizeArgb(strikeRaw['color']) : 0;

    final fillShapeRaw = map['fillShape'];
    final extra = <String, dynamic>{};
    for (final entry in map.entries) {
      if (!_knownKeys.contains(entry.key)) {
        extra[entry.key] = entry.value;
      }
    }

    return HighlightStyle(
      fill: normalizeArgb(map['fill']),
      fillShape: fillShapeRaw is String && fillShapeRaw.isNotEmpty
          ? fillShapeRaw.toUpperCase()
          : null,
      textColor: normalizeArgb(map['textColor']),
      bold: map['bold'] == true,
      italic: map['italic'] == true,
      underline: underline,
      strike: strike,
      strikeColor: strikeColor,
      extra: extra,
    );
  }

  /// 序列化回原版形态（仅用于调试/测试；未知键一并输出）
  Map<String, dynamic> toMap() => {
    'fill': fill,
    if (fillShape != null) 'fillShape': fillShape,
    'textColor': textColor,
    'bold': bold,
    'italic': italic,
    if (underline != null) 'underline': underline!.toMap(),
    if (strike) 'strike': {'color': strikeColor},
    ...extra,
  };
}

/// 单条规则命中区间
class HighlightMatch {
  const HighlightMatch({
    required this.ruleId,
    required this.start,
    required this.end,
    required this.order,
    required this.style,
    this.styleJson = '',
  });

  /// 命中规则 ID
  final int ruleId;

  /// 起点（UTF-16 code unit，包含）
  final int start;

  /// 终点（UTF-16 code unit，不包含）
  final int end;

  /// 规则排序值（越大优先级越高）
  final int order;

  /// 解析后的样式
  final HighlightStyle style;

  /// style JSON 原文（未知键保真的原始来源）
  final String styleJson;

  /// 区间长度（UTF-16 code unit）
  int get length => end - start;

  /// 容错解析；区间非法（start<0 / end<=start）返回 null
  ///
  /// 数值字段统一走 `is num` 守卫（P3-1）：坏数据（字符串/布尔等）按缺省
  /// 值处理，不在解析期抛类型错误。
  static HighlightMatch? tryParse(Object? value) {
    if (value is! Map) return null;
    final json = value.map((k, v) => MapEntry(k.toString(), v));
    final start = _asInt(json['start']) ?? -1;
    final end = _asInt(json['end']) ?? -1;
    if (start < 0 || end <= start) return null;
    final styleJson = json['styleJson'] is String
        ? json['styleJson'] as String
        : '';
    return HighlightMatch(
      ruleId: _asInt(json['ruleId']) ?? 0,
      start: start,
      end: end,
      order: _asInt(json['order']) ?? 0,
      style: HighlightStyle.parse(styleJson),
      styleJson: styleJson,
    );
  }

  @override
  String toString() =>
      'HighlightMatch(rule=$ruleId, [$start,$end), order=$order)';
}

/// 把 ARGB 数值归一化为 0x00..0xFFFFFFFF
///
/// 原版 Kotlin 用 Int 存 ARGB，`0x80FFF176.toInt()` 等半透明色在 JSON 中
/// 是负数；Flutter `Color` 需要无符号 32 位值。
int normalizeArgb(Object? value) {
  if (value is num) return value.toInt() & 0xFFFFFFFF;
  return 0;
}

/// 数值字段守卫：非 `num`（字符串/布尔等坏数据）返回 null（P3-1）
int? _asInt(Object? value) => value is num ? value.toInt() : null;

/// 数值字段守卫：非 `num` 返回 null（P3-1）
double? _asDouble(Object? value) => value is num ? value.toDouble() : null;

/// 解析 Rust `highlightRuleMatch` 返回的 JSON 数组
///
/// 非法条目跳过；逐条 try/catch（P3-1）：单条坏数据不会连累整章高亮。
/// 结果按 `(start, order)` 升序（渲染按行切分更直观）。
List<HighlightMatch> parseHighlightMatches(String raw) {
  if (raw.isEmpty || raw == 'null') return const [];
  Object? decoded;
  try {
    decoded = jsonDecode(raw);
  } catch (_) {
    return const [];
  }
  if (decoded is! List) return const [];
  final matches = <HighlightMatch>[];
  for (final item in decoded) {
    try {
      final match = HighlightMatch.tryParse(item);
      if (match != null) matches.add(match);
    } catch (_) {
      // 单条坏样式/坏字段静默跳过，保留同章其余命中
    }
  }
  matches.sort((a, b) {
    final byStart = a.start.compareTo(b.start);
    return byStart != 0 ? byStart : a.order.compareTo(b.order);
  });
  return matches;
}
