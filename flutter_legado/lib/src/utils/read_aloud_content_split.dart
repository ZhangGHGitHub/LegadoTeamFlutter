// 朗读内容划分纯函数（设置批5b）
//
// 参考：
// - `ReadAloudContentSplit.kt`（章节绝对位置、连续标点同一单元、标点保留在
//   单元末尾、`resolveSymbols` 空集合回退句末标点）
// - `ReadAloudSettings.kt:47-108`（contentSplitMode 默认 default、symbols 默认
//   空集合、ttsParagraphInterval 默认 0）
// - `ReadAloudContentSplitMode.kt`（default/paragraph/page/symbols）
//
// 口径（与参考版一致）：
// - `default` 运行时归一为 `paragraph`（整段），不是句级；
// - `paragraph` 有空白行时按空行分段（段内换行保留），无空白行时逐行切分
//   （TXT/在线书单换行正文），CRLF 同样覆盖；
// - `symbols` 先按行、再逐行按选中标点切分，连续标点归入同一单元，标点保留；
//   未选择标点时回退句末标点 `。！？…`；
// - `page` 按阅读器提供的页首字符偏移切分；无分页信息回退 `paragraph`。
//
// 所有单元满足 `text == content.substring(start, end)`，`start/end` 是章节
// 正文的绝对 UTF-16 偏移（右开区间）；切分只剔除单元首尾空白，不改变正文
// 字符，调用方不得用累加偏移推算位置。
//
// — 全栈工程师（设置批5b） ｜ 2026-11-05

/// 「按符号」可选的 14 个标点（展示顺序与参考版一致）
const String kReadAloudSplitSymbols = '。！？…；，、：.!?;,:';

/// 未显式选择标点时的默认句末标点（对齐参考版
/// `ReadAloudSplitSymbol.sentenceEnds`）
const String kReadAloudDefaultSentenceEndSymbols = '。！？…';

/// 段落间隔上限（毫秒；参考版 `ttsParagraphInterval` 0–5000）
const int kMaxTtsParagraphIntervalMs = 5000;

/// 段落间隔默认值（毫秒）
const int kDefaultTtsParagraphIntervalMs = 0;

/// 内容划分方式（设置值对齐参考版 storageValue）
enum ReadAloudContentSplitMode {
  defaultMode('default'),
  paragraph('paragraph'),
  page('page'),
  symbols('symbols');

  const ReadAloudContentSplitMode(this.storageValue);

  /// 持久化值（`default` / `paragraph` / `page` / `symbols`）
  final String storageValue;

  /// 读取持久化值；未知/损坏值回退 [defaultMode]（与参考版 fromStorage 一致）
  static ReadAloudContentSplitMode fromStorage(String? value) {
    for (final mode in values) {
      if (mode.storageValue == value) return mode;
    }
    return defaultMode;
  }

  /// 运行时实际粒度：`default` 归一为 `paragraph`（整段）
  ReadAloudContentSplitMode get resolved =>
      this == defaultMode ? paragraph : this;
}

/// 一个朗读划分单元：章节绝对偏移 + 对应原文
class ReadAloudUnit {
  const ReadAloudUnit({
    required this.text,
    required this.start,
    required this.end,
  });

  /// 单元文本（已去除首尾空白，保留内部换行与原标点）
  final String text;

  /// 章节正文起始偏移（含，UTF-16）
  final int start;

  /// 章节正文结束偏移（不含，UTF-16）
  final int end;

  @override
  bool operator ==(Object other) =>
      other is ReadAloudUnit &&
      other.text == text &&
      other.start == start &&
      other.end == end;

  @override
  int get hashCode => Object.hash(text, start, end);

  @override
  String toString() => 'ReadAloudUnit($start-$end: $text)';
}

/// 把存储串解析为实际生效的标点集合（按展示顺序、去重）。
///
/// 非法字符过滤；空集合回退句末标点 [`kReadAloudDefaultSentenceEndSymbols`]，
/// 避免「按符号」退化成整段（对齐参考版 `resolveSymbols`）。
String resolveReadAloudSymbols(String? stored) {
  final selected = <String>{};
  for (final rune in (stored ?? '').runes) {
    final symbol = String.fromCharCode(rune);
    if (kReadAloudSplitSymbols.contains(symbol)) selected.add(symbol);
  }
  if (selected.isEmpty) return kReadAloudDefaultSentenceEndSymbols;
  return kReadAloudSplitSymbols.split('').where(selected.contains).join();
}

/// 存储串对应的选中标点集合（空串 → 默认句末标点，与朗读实际行为一致）
Set<String> readAloudSymbolSet(String? stored) =>
    resolveReadAloudSymbols(stored).split('').toSet();

/// 兼容读取「String 存储串」与参考版 `StringSet` / `List<String>` 两种形态。
///
/// 参考版 DataStore 存 `Set<String>`，JSON 备份经 appPrefs 往返为数组；
/// 本实现批5b 早期写 String。两种形态都接受，非法元素忽略；坏值不抛出，
/// 由调用方按空串（回退句末标点）处理，避免拖累同批其它偏好读回。
String decodeReadAloudSymbols(Object? stored) {
  if (stored is String) return stored;
  if (stored is Iterable) {
    final buffer = StringBuffer();
    for (final item in stored) {
      if (item is String) buffer.write(item);
    }
    return buffer.toString();
  }
  return '';
}

/// 把选中标点编码为存储串（过滤非法字符、按展示顺序去重）。
///
/// 集合为空返回空串——存储层约定「空 = 回退句末标点」，与参考版一致。
String encodeReadAloudSymbols(Iterable<String> symbols) {
  final selected = <String>{};
  for (final item in symbols) {
    for (final rune in item.runes) {
      final symbol = String.fromCharCode(rune);
      if (kReadAloudSplitSymbols.contains(symbol)) selected.add(symbol);
    }
  }
  if (selected.isEmpty) return '';
  return kReadAloudSplitSymbols.split('').where(selected.contains).join();
}

/// 按 [mode] 把章节正文切成朗读单元。
///
/// - [content]：Rust 正文链返回的纯正文（替换/净化已生效）；
/// - [mode]：划分方式；`default` 归一为 `paragraph`；
/// - [symbols]：仅 [ReadAloudContentSplitMode.symbols] 使用，存储串形态；
///   空串回退句末标点；
/// - [pageStarts]：仅 [ReadAloudContentSplitMode.page] 使用，当前章各页页首
///   字符偏移（0 与章末可省略，函数自行补齐）；null/空表示无分页信息。
///
/// 纯空白内容返回空列表；任何模式下返回的单元互不重叠，且除首尾空白外
/// 不丢失正文。
List<ReadAloudUnit> splitReadAloudUnits(
  String content,
  ReadAloudContentSplitMode mode, {
  String symbols = '',
  List<int>? pageStarts,
}) {
  if (content.trim().isEmpty) return const [];
  switch (mode) {
    case ReadAloudContentSplitMode.defaultMode:
    case ReadAloudContentSplitMode.paragraph:
      return _splitParagraphs(content);
    case ReadAloudContentSplitMode.symbols:
      return _splitAtSymbols(content, resolveReadAloudSymbols(symbols));
    case ReadAloudContentSplitMode.page:
      final boundaries = _normalizePageStarts(content, pageStarts);
      if (boundaries == null) return _splitParagraphs(content);
      return _splitByBoundaries(content, boundaries);
  }
}

/// 空行分段（整段单元，保留段内换行）
///
/// 分隔符选择恢复批5b前行为：正文存在空行时只按空行切（段内单换行保留），
/// 否则按每个换行切。没有这条回退，无空行 TXT/在线书整章会变成 1 个单元，
/// 段落切换失效且长章一次合成易失败。CRLF 空行与换行同样覆盖。
List<ReadAloudUnit> _splitParagraphs(String content) {
  final result = <ReadAloudUnit>[];
  final hasBlankLine = RegExp(r'\n[ \t]*\r?\n').hasMatch(content);
  final separator = hasBlankLine ? RegExp(r'\n\s*\n') : RegExp(r'\r?\n');
  var start = 0;
  for (final match in separator.allMatches(content)) {
    _emitRange(content, start, match.start, result);
    start = match.end;
  }
  _emitRange(content, start, content.length, result);
  return result;
}

/// 按选中标点切分（先按行、再逐行按标点；连续标点归入同一单元）
///
/// 对齐参考版 `ReadAloudContentSplitter.splitLines`（`lineParagraphs` 后
/// `splitParagraphs`）：行与行之间即使没有标点也不会合并成一个长单元；
/// 每行内标点保留在单元末尾，绝对偏移直接取原正文位置。
List<ReadAloudUnit> _splitAtSymbols(String content, String symbols) {
  final result = <ReadAloudUnit>[];
  final splitUnits = symbols.codeUnits.toSet();
  var lineStart = 0;
  for (var index = 0; index <= content.length; index++) {
    final atEnd = index == content.length;
    if (!atEnd && content.codeUnitAt(index) != 0x0A) continue;
    if (index > lineStart) {
      _splitRangeAtSymbols(content, lineStart, index, splitUnits, result);
    }
    lineStart = index + 1;
  }
  return result;
}

/// 在 [rawStart, rawEnd) 内按标点切分（标点及连续标点归入前一单元）
void _splitRangeAtSymbols(
  String content,
  int rawStart,
  int rawEnd,
  Set<int> splitUnits,
  List<ReadAloudUnit> out,
) {
  var start = rawStart;
  var index = rawStart;
  while (index < rawEnd) {
    if (!splitUnits.contains(content.codeUnitAt(index))) {
      index++;
      continue;
    }
    var end = index + 1;
    // 连续标点视为一个整体（如「……」「！？」），切在同一单元末尾
    while (end < rawEnd && splitUnits.contains(content.codeUnitAt(end))) {
      end++;
    }
    _emitRange(content, start, end, out);
    start = end;
    index = end;
  }
  _emitRange(content, start, rawEnd, out);
}

/// 页首偏移归一：补齐 0/章末、过滤越界、代理对边界对齐、去重排序。
///
/// 没有任何分页信息（null/空）返回 null，由调用方回退整段划分。
/// 页首若落在 UTF-16 代理对中间（低代理项位置），向前对齐到高代理项，
/// 避免 `substring` 切开 emoji 等补充平面字符。
List<int>? _normalizePageStarts(String content, List<int>? pageStarts) {
  if (pageStarts == null || pageStarts.isEmpty) return null;
  final boundaries = <int>{0, content.length};
  for (final value in pageStarts) {
    final aligned = _alignToCodeUnitBoundary(content, value);
    if (aligned > 0 && aligned < content.length) boundaries.add(aligned);
  }
  final sorted = boundaries.toList()..sort();
  return sorted;
}

/// 把可能落在代理对中间的偏移向前对齐到合法 UTF-16 边界
int _alignToCodeUnitBoundary(String content, int index) {
  if (index <= 0 || index >= content.length) return index;
  final unit = content.codeUnitAt(index);
  if (unit < 0xDC00 || unit > 0xDFFF) return index;
  final previous = content.codeUnitAt(index - 1);
  if (previous >= 0xD800 && previous <= 0xDBFF) return index - 1;
  return index;
}

/// 按页边界切分；整页文本保留页内换行，仅剔除首尾空白
List<ReadAloudUnit> _splitByBoundaries(String content, List<int> boundaries) {
  final result = <ReadAloudUnit>[];
  for (var i = 0; i + 1 < boundaries.length; i++) {
    _emitRange(content, boundaries[i], boundaries[i + 1], result);
  }
  return result;
}

/// 收集 [rawStart, rawEnd) 的正文并去掉首尾空白；纯空白不产生单元
void _emitRange(
  String content,
  int rawStart,
  int rawEnd,
  List<ReadAloudUnit> out,
) {
  if (rawStart >= rawEnd) return;
  final raw = content.substring(rawStart, rawEnd);
  final text = raw.trim();
  if (text.isEmpty) return;
  final leading = raw.length - raw.trimLeft().length;
  out.add(
    ReadAloudUnit(
      text: text,
      start: rawStart + leading,
      end: rawStart + leading + text.length,
    ),
  );
}
