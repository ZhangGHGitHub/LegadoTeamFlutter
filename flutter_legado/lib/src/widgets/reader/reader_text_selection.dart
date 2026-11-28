/// R49 正文字符级选区：选区模型、行级偏移映射与词边界纯函数
///
/// 本文件只包含**纯逻辑**（无 Widget / 无 RenderObject），供正文渲染层做
/// 命中定位、选区绘制与文本提取：
/// - 坐标统一使用**章节 UTF-16 偏移**（与高亮/书签/笔记/朗读链路同口径）；
/// - [ReaderTextSelection.focus] 为**含端**（与参考版
///   `ReaderSelection.endInclusive` 一致），单字符选区即 anchor == focus；
/// - 行内 / 段落内偏移一律按行现算，不缓存在选区对象里，避免重排后失配。
///
/// 映射口径与高亮渲染完全一致（`highlight_span_builder.dart`）：
/// - 纯文本行：`text[highlightSkip]` 对应章节偏移 `chapterStartIndex`；
/// - 含行内图片行：优先用 `LineInfo.chapterOffsets` 逐字符映射，`-1`
///   表示缩进列/无映射，归到最近的有效字符；
/// - 行内图片占位符（[readerImagePlaceholderChar]）只占 1 个渲染字符，
///   复制文本中剔除，但选区灰块仍覆盖其占位宽度。
library;

import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../../utils/reader_inline_image.dart';
import '../paragraph_layout_engine.dart';

/// [R49] 选区手柄几何（对齐参考版 `ReaderCanvasSurface.kt:181-184`）
///
/// - 竖线宽 2dp、行底空心圆半径 7dp、圆与竖线视作同一只 pin 手柄；
/// - 热区半径 28dp（胶囊形：竖线 + 圆整体可抓）。
const double kReaderSelectionHandleRadius = 7.0;
const double kReaderSelectionHandleStrokeWidth = 2.0;
const double kReaderSelectionHandleHitRadius = 28.0;

/// 正文选区（章节 UTF-16 偏移，端点含端）
@immutable
class ReaderTextSelection {
  const ReaderTextSelection({
    required this.anchor,
    required this.focus,
    this.isTitle = false,
  });

  /// 长按起点（章节 UTF-16 偏移，含）
  final int anchor;

  /// 当前端点（章节 UTF-16 偏移，含）
  final int focus;

  /// 预留：标题选区（当前正文不选标题，恒 false）
  final bool isTitle;

  /// anchor 是否在 focus 之前（同位置视为正向）
  bool get isForward => anchor <= focus;

  /// 文档顺序起点（含）
  int get start => isForward ? anchor : focus;

  /// 文档顺序终点（含）
  int get endInclusive => isForward ? focus : anchor;

  /// 半开区间终点 [start, endExclusive)
  int get endExclusive => endInclusive + 1;

  /// 是否为空选区
  ///
  /// 端点均为含端，故合法选区的长度至少为 1；只有外部构造出
  /// `endExclusive <= start` 的异常区间才算折叠（设计文档里的
  /// `anchor == focus` 在含端语义下是合法的单字符选区，不视为折叠）。
  bool get isCollapsed => endExclusive <= start;

  /// 选区覆盖的章节字符数
  int get length => math.max(0, endExclusive - start);

  bool containsChapterOffset(int offset) =>
      offset >= start && offset <= endInclusive;

  ReaderTextSelection copyWith({int? anchor, int? focus, bool? isTitle}) {
    return ReaderTextSelection(
      anchor: anchor ?? this.anchor,
      focus: focus ?? this.focus,
      isTitle: isTitle ?? this.isTitle,
    );
  }

  ReaderTextSelection withAnchor(int value) => copyWith(anchor: value);

  ReaderTextSelection withFocus(int value) => copyWith(focus: value);

  @override
  bool operator ==(Object other) {
    return other is ReaderTextSelection &&
        other.anchor == anchor &&
        other.focus == focus &&
        other.isTitle == isTitle;
  }

  @override
  int get hashCode => Object.hash(anchor, focus, isTitle);

  @override
  String toString() =>
      'ReaderTextSelection(anchor: $anchor, focus: $focus, '
      'isTitle: $isTitle)';
}

/// 一行在渲染文本坐标与章节坐标之间的映射
///
/// [line] 为排版引擎输出的行信息；[text] 即渲染文本
/// （`line.words.join('')`，含首行缩进全角空格与行内图片占位符）。
@immutable
class ReaderLineSelectionMap {
  ReaderLineSelectionMap(this.line) : text = line.words.join('');

  final LineInfo line;

  /// 该行渲染文本（与 `Text` / `Text.rich` 完全同源）
  final String text;

  /// 独立图片行（不渲染文字，不参与文字选区）
  bool get isImageOnlyLine => line.imageLayout != null;

  /// 该行是否存在可选文字
  bool get isSelectable => !isImageOnlyLine && text.isNotEmpty;

  /// 行首不可选字符数（首行缩进全角空格）
  int get skip => line.highlightSkip.clamp(0, text.length);

  List<int>? get _charOffsets => line.chapterOffsets;

  /// 行内首个可选字符下标（含行内图片占位符）
  int get firstSelectableLocal {
    final offsets = _charOffsets;
    if (offsets == null) return skip;
    final limit = math.min(offsets.length, text.length);
    for (var i = 0; i < limit; i++) {
      if (offsets[i] >= 0) return i;
    }
    return skip;
  }

  /// 行首可选字符对应的章节偏移（含）
  int get bodyStart {
    final offsets = _charOffsets;
    if (offsets == null) return line.chapterStartIndex;
    final limit = math.min(offsets.length, text.length);
    for (var i = 0; i < limit; i++) {
      if (offsets[i] >= 0) return offsets[i];
    }
    return line.chapterStartIndex;
  }

  /// 行尾之后一位的章节偏移（半开）
  int get bodyEnd {
    final offsets = _charOffsets;
    if (offsets == null) {
      return line.chapterStartIndex + math.max(0, text.length - skip);
    }
    for (var i = math.min(offsets.length, text.length) - 1; i >= 0; i--) {
      if (offsets[i] >= 0) return offsets[i] + 1;
    }
    return line.chapterStartIndex;
  }

  /// 行内下标 → 章节偏移
  ///
  /// 缩进区（`local < skip` 或 `chapterOffsets == -1`）落到最近的后续有效
  /// 字符；行尾（`local >= text.length`）返回 [bodyEnd]。结果始终落在
  /// `[bodyStart, bodyEnd]` 内。
  int localToChapter(int local) {
    final l = local.clamp(0, text.length);
    final offsets = _charOffsets;
    if (offsets == null) {
      if (l <= skip) return line.chapterStartIndex;
      return line.chapterStartIndex + (l - skip);
    }
    final limit = math.min(offsets.length, text.length);
    if (l >= limit) {
      for (var i = limit - 1; i >= 0; i--) {
        if (offsets[i] >= 0) return offsets[i] + 1;
      }
      return line.chapterStartIndex;
    }
    final value = offsets[l];
    if (value >= 0) return value;
    // 缩进列/无映射：先找后续有效字符，再向前回退
    for (var i = l + 1; i < limit; i++) {
      if (offsets[i] >= 0) return offsets[i];
    }
    for (var i = l - 1; i >= 0; i--) {
      if (offsets[i] >= 0) return offsets[i];
    }
    return line.chapterStartIndex;
  }

  /// 章节偏移 → 行内下标；不属于本行时返回 -1
  ///
  /// 含行内图片的行按逐字符映射查最近字符：落在 `<img>` 标签内部的偏移
  /// 会落到图片之后的第一个字符（标签本身只按占位符 1 个字符参与选区）。
  int chapterToLocal(int chapter) {
    if (!isSelectable) return -1;
    final offsets = _charOffsets;
    if (offsets != null) {
      final limit = math.min(offsets.length, text.length);
      for (var i = 0; i < limit; i++) {
        final value = offsets[i];
        if (value >= 0 && value >= chapter) return i;
      }
      return -1;
    }
    final start = line.chapterStartIndex;
    final end = start + (text.length - skip);
    if (chapter < start || chapter >= end) return -1;
    return skip + (chapter - start);
  }

  /// 章节半开区间 [startChapter, endExclusiveChapter) 在本行的行内区间
  ///
  /// 返回 `(局部起点, 局部终点)`，与 [text] 下标一致；不相交或空区间返回
  /// null。起止越界时按整行截断（跨行/跨段选区由调用方逐行收集）。
  (int, int)? localRangeFor(int startChapter, int endExclusiveChapter) {
    if (!isSelectable || endExclusiveChapter <= startChapter) return null;
    final first = bodyStart;
    final end = bodyEnd;
    if (endExclusiveChapter <= first || startChapter >= end) return null;
    var ls = startChapter <= first
        ? firstSelectableLocal
        : chapterToLocal(startChapter);
    if (ls < 0) ls = firstSelectableLocal;
    var le = endExclusiveChapter >= end
        ? text.length
        : chapterToLocal(endExclusiveChapter);
    if (le < 0) le = text.length;
    if (le <= ls) return null;
    return (ls, le);
  }
}

/// 词边界区间（行内 UTF-16 下标，半开区间）
@immutable
class ReaderWordRange {
  const ReaderWordRange(this.start, this.endExclusive);

  final int start;
  final int endExclusive;

  int get length => endExclusive - start;

  bool get isEmpty => endExclusive <= start;

  @override
  bool operator ==(Object other) {
    return other is ReaderWordRange &&
        other.start == start &&
        other.endExclusive == endExclusive;
  }

  @override
  int get hashCode => Object.hash(start, endExclusive);

  @override
  String toString() => 'ReaderWordRange($start, $endExclusive)';
}

/// 长按词级起选：把按压点所在的词/字符转成章节选区
///
/// - [localOffset] 超出缩进列时钳到首个可选字符；
/// - 行内图片占位符按单字符处理（章节偏移取 `<img>` 标签起点）；
/// - 词不跨视觉行（跨行词按当前行截断，与参考版整段分词的差异登记 P3）。
ReaderTextSelection? readerSelectionForWordAt(
  ReaderLineSelectionMap map,
  int localOffset,
) {
  if (!map.isSelectable) return null;
  var local = localOffset.clamp(0, map.text.length - 1);
  final first = map.firstSelectableLocal;
  if (local < first) local = first;
  if (local >= map.text.length) return null;
  final word = readerWordRangeAt(map.text, local);
  if (word.isEmpty) return null;
  var startLocal = math.max(word.start, first);
  var endLocal = math.max(word.endExclusive - 1, startLocal);
  if (endLocal >= map.text.length) endLocal = map.text.length - 1;
  if (startLocal > endLocal) return null;
  final anchor = map.localToChapter(startLocal);
  final focus = map.localToChapter(endLocal);
  return ReaderTextSelection(
    anchor: math.min(anchor, focus),
    focus: math.max(anchor, focus),
  );
}

/// 按章节选区提取选中文本（剔除行内图片占位符，跨段补 `\n`）
///
/// 与参考版 `ReaderSelection.selectedText` 语义一致：同一段落内的行直接
/// 拼接（不补空格），段落之间补一个 `\n`；行内图片占位符不进入文本。
String readerSelectionText(PageInfo page, ReaderTextSelection selection) {
  if (selection.isCollapsed) return '';
  final out = StringBuffer();
  for (final para in page.paragraphs) {
    final paraBuffer = StringBuffer();
    for (final line in para.lines) {
      final map = ReaderLineSelectionMap(line);
      final range = map.localRangeFor(selection.start, selection.endExclusive);
      if (range == null) continue;
      final (ls, le) = range;
      if (le <= ls) continue;
      final body = map.text.substring(ls, le);
      final cleaned = body.replaceAll(readerImagePlaceholderChar, '');
      if (cleaned.isEmpty) continue;
      paraBuffer.write(cleaned);
    }
    if (paraBuffer.isEmpty) continue;
    if (out.isNotEmpty) out.write('\n');
    out.write(paraBuffer.toString());
  }
  return out.toString();
}

/// 把行内下标对齐到字形簇起点（代理对/组合附加符号不拆分）
///
/// 手柄拖拽时 `RenderParagraph.getPositionForOffset` 偶尔会落进代理对中间，
/// 或落在组合附加符号上；这里统一回退到基字符，保证选区端点始终是合法
/// 字形簇边界（与参考版按 cluster 取端点同语义）。
int readerAlignToClusterStart(String text, int offset) {
  if (text.isEmpty) return 0;
  return _alignToClusterStart(text, offset.clamp(0, text.length - 1));
}

// ---------------------------------------------------------------------------
// 词边界（不依赖 ICU 的近似实现，覆盖中英文常见情况）
// ---------------------------------------------------------------------------

/// 返回 [offset] 所在词的半开区间 [start, endExclusive)
///
/// 规则（与参考版 ICU `BreakIterator` 对齐的主要场景）：
/// - 拉丁字母/数字/下划线：整词（含词内 `'` `’` `-` 连接符）；
/// - 中日韩汉字/假名/谚文：单字（无词典时按字符粒度，参考版 ICU 的
///   中文分词结果不可在 Dart 侧复现，登记 P3 差异）；
/// - 标点/空白/其他符号：单个字形簇；
/// - 代理对与组合附加符号不拆分。
ReaderWordRange readerWordRangeAt(String text, int offset) {
  if (text.isEmpty) return const ReaderWordRange(0, 0);
  var index = offset.clamp(0, text.length - 1);
  index = _alignToClusterStart(text, index);
  final codePoint = _codePointAt(text, index);
  final unitLength = _codeUnitLengthAt(text, index);
  if (!_isWordCodePoint(codePoint)) {
    return ReaderWordRange(index, index + unitLength);
  }
  var start = index;
  var end = index + unitLength;
  // 向左扩展：词字符 / 词内连接符 / 组合附加符号
  while (start > 0) {
    final prevIndex = _previousClusterStart(text, start);
    final prevCodePoint = _codePointAt(text, prevIndex);
    if (_isWordCodePoint(prevCodePoint)) {
      start = prevIndex;
      continue;
    }
    if (_isCombiningMark(prevCodePoint)) {
      start = prevIndex;
      continue;
    }
    if (_isWordConnector(prevCodePoint) && prevIndex > 0) {
      final beforeIndex = _previousClusterStart(text, prevIndex);
      if (_isWordCodePoint(_codePointAt(text, beforeIndex))) {
        start = prevIndex;
        continue;
      }
    }
    break;
  }
  // 向右扩展
  while (end < text.length) {
    final codePointAtEnd = _codePointAt(text, end);
    if (_isWordCodePoint(codePointAtEnd) || _isCombiningMark(codePointAtEnd)) {
      end += _codeUnitLengthAt(text, end);
      continue;
    }
    if (_isWordConnector(codePointAtEnd)) {
      final afterConnector = end + _codeUnitLengthAt(text, end);
      if (afterConnector < text.length &&
          _isWordCodePoint(_codePointAt(text, afterConnector))) {
        end = afterConnector;
        continue;
      }
    }
    break;
  }
  return ReaderWordRange(start, end);
}

bool _isHighSurrogate(int codeUnit) => codeUnit >= 0xD800 && codeUnit <= 0xDBFF;

bool _isLowSurrogate(int codeUnit) => codeUnit >= 0xDC00 && codeUnit <= 0xDFFF;

int _codeUnitLengthAt(String text, int index) {
  final codeUnit = text.codeUnitAt(index);
  if (_isHighSurrogate(codeUnit) &&
      index + 1 < text.length &&
      _isLowSurrogate(text.codeUnitAt(index + 1))) {
    return 2;
  }
  return 1;
}

int _codePointAt(String text, int index) {
  final codeUnit = text.codeUnitAt(index);
  if (_isHighSurrogate(codeUnit) && index + 1 < text.length) {
    final next = text.codeUnitAt(index + 1);
    if (_isLowSurrogate(next)) {
      return 0x10000 + ((codeUnit - 0xD800) << 10) + (next - 0xDC00);
    }
  }
  return codeUnit;
}

int _previousClusterStart(String text, int index) {
  if (index <= 1) {
    final prev = index - 1;
    if (prev >= 0 &&
        _isLowSurrogate(text.codeUnitAt(prev)) &&
        prev > 0 &&
        _isHighSurrogate(text.codeUnitAt(prev - 1))) {
      return prev - 1;
    }
    return math.max(0, prev);
  }
  final prev = index - 1;
  if (_isLowSurrogate(text.codeUnitAt(prev)) &&
      _isHighSurrogate(text.codeUnitAt(prev - 1))) {
    return prev - 1;
  }
  return prev;
}

int _alignToClusterStart(String text, int index) {
  var current = index;
  if (current > 0 && _isLowSurrogate(text.codeUnitAt(current))) {
    final prev = current - 1;
    if (_isHighSurrogate(text.codeUnitAt(prev))) return prev;
  }
  // 组合附加符号/变体选择符跟随基字符
  while (current > 0 && _isCombiningMark(_codePointAt(text, current))) {
    current = _previousClusterStart(text, current);
  }
  return current;
}

bool _isCombiningMark(int codePoint) {
  return (codePoint >= 0x0300 && codePoint <= 0x036F) ||
      (codePoint >= 0x1AB0 && codePoint <= 0x1AFF) ||
      (codePoint >= 0x1DC0 && codePoint <= 0x1DFF) ||
      (codePoint >= 0x20D0 && codePoint <= 0x20FF) ||
      (codePoint >= 0xFE00 && codePoint <= 0xFE0F) ||
      (codePoint >= 0xFE20 && codePoint <= 0xFE2F) ||
      (codePoint >= 0xE0100 && codePoint <= 0xE01EF);
}

/// 是否拉丁/数字等"整词"字符（CJK 不走此分支，按单字处理）
bool _isWordCodePoint(int codePoint) {
  return (codePoint >= 0x30 && codePoint <= 0x39) || // 0-9
      (codePoint >= 0x41 && codePoint <= 0x5A) || // A-Z
      (codePoint >= 0x61 && codePoint <= 0x7A) || // a-z
      codePoint == 0x5F || // _
      (codePoint >= 0xC0 && codePoint <= 0x24F) || // 拉丁扩展
      (codePoint >= 0x370 && codePoint <= 0x3FF) || // 希腊字母
      (codePoint >= 0x400 && codePoint <= 0x4FF) || // 西里尔字母
      (codePoint >= 0xFF10 && codePoint <= 0xFF19) || // 全角数字
      (codePoint >= 0xFF21 && codePoint <= 0xFF3A) || // 全角大写
      (codePoint >= 0xFF41 && codePoint <= 0xFF5A); // 全角小写
}

/// 词内连接符（`'` `’` `-`），仅在两侧均为词字符时并入整词
bool _isWordConnector(int codePoint) {
  return codePoint == 0x27 || codePoint == 0x2019 || codePoint == 0x2D;
}
