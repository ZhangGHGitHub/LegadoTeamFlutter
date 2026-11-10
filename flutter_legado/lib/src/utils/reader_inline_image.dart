// 正文行内图片混排（批16）——纯逻辑层
//
// 对齐上游/参考版语义：
// - 上游 `HtmlFormatter.kt:53-87`：正文净化只保留 `<img>`，懒加载属性转
//   src，相对地址按抓取页 URL 绝对化，复合 `,{json}` 参数原样保留；
// - 上游 `TextChapterLayout.kt:456-600`：逐段匹配 img，读 `style`/`width`/
//   `click`；`:630-712` 大图独立变高 ImageColumn；`:1573-1585` <80px 小图
//   落行内占位符；`:510-528` 宽度支持 %/px、居中/左右；`:326-380` 标题图；
// - 参考版 `ReaderChapterSource.kt:132`（拆 inline Image）、
//   `ReaderChapterBlockMeasurer.kt:221-266`（inline/standalone 与尺寸失败
//   行高占位）、`ReaderPaginator.kt:349-391`（缩放/居中/单页）、
//   `LegacyReaderImageOptionsResolver.kt:20-45`（click/width/style）。
//
// 本文件只做分段、URL 绝对化、宽度/尺寸解析与显示布局决策，不依赖渲染，
// 供排版引擎与阅读器渲染层共用，便于单测覆盖。— 全栈工程师 + UI

import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import 'click_img_way.dart';
import 'comic_image_utils.dart';

/// 行内图片占位字符（U+FFFC OBJECT REPLACEMENT CHARACTER）
///
/// 与上游 `srcReplaceChar` 等价：排版按该字符宽度占位，渲染时替换为
/// WidgetSpan 图片。必须是单个 UTF-16 code unit，便于行内偏移映射。
const String readerImagePlaceholderChar = '\uFFFC';

/// 小于该尺寸（宽与高同时）按行内小图处理（对齐上游 `imgSize.width < 80
/// && imgSize.height < 80`）。
const double readerImageInlineThreshold = 80.0;

/// 图片在行内的显示对齐方式
enum ReaderImageAlignment { left, center, right }

/// 图片行的排版位置
enum ReaderImagePlacement {
  /// 行内：与文字同一行，渲染为 WidgetSpan 占位
  inline,

  /// 独立变高行：独占一行（可多段文字之间）
  standalone,
}

/// 图片固有尺寸（解码像素），或失败标记
@immutable
class ReaderImageSize {
  final double width;
  final double height;

  /// 测量失败/图片不可用（布局仍按占位高度，避免分页丢字）
  final bool failed;

  /// 失败是否可跨章重试（网络/超时为 true；解码/格式/路径拒绝为 false）
  final bool retryable;

  const ReaderImageSize(this.width, this.height)
    : failed = false,
      retryable = false;

  const ReaderImageSize.failed({this.retryable = true})
    : width = 0,
      height = 0,
      failed = true;

  bool get isValid => !failed && width > 0 && height > 0;
}

/// 图片尺寸缓存（异步预测量结果，按图片原始 src 去重）
///
/// [revision] 在每次写入后递增，阅读页据此触发一次合并重排；测量失败也
/// 写入失败标记（同样递增一次），避免对同一 URL 反复重试与无限重排。
///
/// [beginMeasure]/[completeMeasure]/[cancelMeasure] 为在途测量生命周期：
/// - 同一 URL 同时只允许一次测量（[beginMeasure] 返回 false 表示已在途或
///   已有不可重试结果）；
/// - 换书/切章取消（[cancelMeasure]）只清在途标记、不写失败，允许新章
///   重新测量；
/// - 解码/格式失败永久保留；网络类失败（[ReaderImageSize.retryable]）允许
///   跨章重试，同章内是否重试由阅读页会话级 attempted 集合控制。
class ReaderImageSizeCache {
  ReaderImageSizeCache._();

  static final Map<String, ReaderImageSize> _sizes = {};
  static final Set<String> _inFlight = {};
  static int _measureBatchDepth = 0;
  static int _revision = 0;

  /// 是否有测量批次在进行（渲染回填需让位给权威测量）
  static bool get isBatchMeasuring => _measureBatchDepth > 0;

  /// 标记测量批次开始/结束（阅读页串行测量协程生命周期）
  static void beginMeasureBatch() => _measureBatchDepth++;

  static void endMeasureBatch() {
    if (_measureBatchDepth > 0) _measureBatchDepth--;
  }

  /// 缓存修订号（每次 put 递增）
  static int get revision => _revision;

  static String keyOf(String rawSrc) => rawSrc.trim();

  static ReaderImageSize? lookup(String rawSrc) => _sizes[keyOf(rawSrc)];

  /// 是否已有结果（成功或失败）
  static bool hasResult(String rawSrc) => _sizes.containsKey(keyOf(rawSrc));

  /// 是否正在测量
  static bool isMeasuring(String rawSrc) => _inFlight.contains(keyOf(rawSrc));

  /// 尝试开始一次测量：已有不可重试结果/已在途返回 false
  static bool beginMeasure(String rawSrc) {
    final key = keyOf(rawSrc);
    final existing = _sizes[key];
    if (existing != null) {
      // 仅网络类失败允许跨章重试；解码/格式失败永久保留
      if (!(existing.failed && existing.retryable)) return false;
    }
    return _inFlight.add(key);
  }

  /// 完成测量：写回结果并清在途标记；返回是否写入
  ///
  /// 若期间渲染层已成功写回真实尺寸，则保留已有成功结果（避免覆盖与
  /// 多余 revision）。[retryable] 仅对失败结果生效。
  static bool completeMeasure(
    String rawSrc,
    ReaderImageSize? size, {
    bool retryable = true,
  }) {
    final key = keyOf(rawSrc);
    _inFlight.remove(key);
    final existing = _sizes[key];
    if (existing != null && existing.isValid) return false;
    put(key, size ?? ReaderImageSize.failed(retryable: retryable));
    return true;
  }

  /// 取消测量：只清在途标记（不写失败，允许换章后重试）
  static void cancelMeasure(String rawSrc) => _inFlight.remove(keyOf(rawSrc));

  static void put(String rawSrc, ReaderImageSize size) {
    _sizes[keyOf(rawSrc)] = size;
    _revision++;
  }

  static void putFailure(String rawSrc, {bool retryable = true}) =>
      put(rawSrc, ReaderImageSize.failed(retryable: retryable));

  @visibleForTesting
  static int get inFlightCount => _inFlight.length;

  @visibleForTesting
  static void clearForTest() {
    _sizes.clear();
    _inFlight.clear();
    _measureBatchDepth = 0;
    _revision = 0;
  }
}

/// 正文图片字节缓存（LRU，渲染与尺寸预测量共用）
///
/// 键 = 书源地址 + 原始 src（复合 `,{json}` 保留），避免不同书源同 URL
/// 但 imageDecode 不同的密文串用。同时受条数与总字节预算约束（默认
/// 16MiB），超限淘汰最久未用；单张超过预算的图片不缓存（仍可当次渲染）。
class ReaderImageBytesCache {
  ReaderImageBytesCache._();

  static const int maxEntries = 32;

  /// 总字节预算（16MiB）
  static const int maxTotalBytes = 16 * 1024 * 1024;

  static final LinkedHashMap<String, Uint8List> _cache =
      LinkedHashMap<String, Uint8List>();
  static int _totalBytes = 0;

  static String keyOf(String origin, String rawSrc) =>
      '$origin\u0000${rawSrc.trim()}';

  static Uint8List? get(String origin, String rawSrc) {
    final key = keyOf(origin, rawSrc);
    final hit = _cache.remove(key);
    if (hit == null) return null;
    _cache[key] = hit; // 命中移到队尾（LRU）
    return hit;
  }

  static void put(String origin, String rawSrc, Uint8List bytes) {
    if (bytes.isEmpty || bytes.length > maxTotalBytes) return;
    final key = keyOf(origin, rawSrc);
    final old = _cache.remove(key);
    if (old != null) _totalBytes -= old.length;
    _cache[key] = bytes;
    _totalBytes += bytes.length;
    while (_cache.length > 1 &&
        (_cache.length > maxEntries || _totalBytes > maxTotalBytes)) {
      final evicted = _cache.remove(_cache.keys.first);
      if (evicted != null) _totalBytes -= evicted.length;
    }
  }

  @visibleForTesting
  static int get totalBytes => _totalBytes;

  @visibleForTesting
  static int get entryCount => _cache.length;

  @visibleForTesting
  static void clearForTest() {
    _cache.clear();
    _totalBytes = 0;
  }
}

/// 正文图片节点（URL 已绝对化，保留 `,{json}` 复合参数）
@immutable
class ReaderInlineImage {
  /// 绝对化后的完整 src（含 `,{json}` 后缀；FFI 下载需完整串）
  final String rawSrc;

  /// 复合参数解析结果（[ClickImgUrlOptions.url] 为绝对化后的纯 URL）
  final ClickImgUrlOptions options;

  const ReaderInlineImage({required this.rawSrc, required this.options});

  String get url => options.url;

  String? get style => options.style;

  String? get widthSpec => options.width;

  String? get click => options.click;

  Map<String, String> get headers => options.headers;

  @override
  String toString() => 'ReaderInlineImage(url: $url, style: $style)';
}

/// 一个段落的排版 run
sealed class ReaderParagraphRun {
  const ReaderParagraphRun();
}

/// 纯文本 run
@immutable
class ReaderTextRun extends ReaderParagraphRun {
  final String text;

  /// run 在原始段落文本中的起止偏移（供高亮/选区映射）
  final int start;
  final int end;

  const ReaderTextRun(this.text, {this.start = 0, this.end = 0});

  @override
  String toString() => 'ReaderTextRun(${text.length} chars)';
}

/// 图片 run
@immutable
class ReaderImageRun extends ReaderParagraphRun {
  final ReaderInlineImage image;

  /// 整个 `<img ...>` 标签在原始段落文本中的起止偏移
  final int start;
  final int end;

  const ReaderImageRun(this.image, {this.start = 0, this.end = 0});

  @override
  String toString() => 'ReaderImageRun(${image.url})';
}

/// 图片显示布局（排版/渲染共用的确定结果）
@immutable
class ReaderImageLayout {
  final ReaderInlineImage image;
  final ReaderImagePlacement placement;

  /// 显示宽高（已按可用宽/页高缩放，宽高比与固有尺寸一致）
  final double width;
  final double height;

  final ReaderImageAlignment alignment;

  /// 该图片行是否强制另起一页（SINGLE 样式，对齐上游 prepareNextPageIfNeed）
  final bool pageBreakBefore;
  final bool pageBreakAfter;

  /// 固有尺寸未知或测量失败：行高为占位高度
  final bool placeholder;

  /// 是否为行内小图（渲染为 WidgetSpan 占位）
  bool get isInline => placement == ReaderImagePlacement.inline;

  const ReaderImageLayout({
    required this.image,
    required this.placement,
    required this.width,
    required this.height,
    this.alignment = ReaderImageAlignment.center,
    this.pageBreakBefore = false,
    this.pageBreakAfter = false,
    this.placeholder = false,
  });

  ReaderImageLayout copyWith({
    ReaderImagePlacement? placement,
    double? width,
    double? height,
    ReaderImageAlignment? alignment,
    bool? pageBreakBefore,
    bool? pageBreakAfter,
    bool? placeholder,
  }) {
    return ReaderImageLayout(
      image: image,
      placement: placement ?? this.placement,
      width: width ?? this.width,
      height: height ?? this.height,
      alignment: alignment ?? this.alignment,
      pageBreakBefore: pageBreakBefore ?? this.pageBreakBefore,
      pageBreakAfter: pageBreakAfter ?? this.pageBreakAfter,
      placeholder: placeholder ?? this.placeholder,
    );
  }
}

/// URL 绝对化（对齐上游 `NetworkUtils.getAbsoluteURL`）：
/// - 已带协议（http/https/data/file/content/cbz）原样返回；
/// - `//host/path` 继承 baseUrl 协议；
/// - `/path`、`../`、相对路径用 baseUrl resolve。
///
/// baseUrl 为空或非法时保持相对地址（fail-open，不阻断排版）。
String resolveReaderImageUrl(String url, String baseUrl) {
  final raw = url.trim();
  if (raw.isEmpty) return raw;
  final lower = raw.toLowerCase();
  if (lower.startsWith('http://') ||
      lower.startsWith('https://') ||
      lower.startsWith('data:') ||
      lower.startsWith('file:') ||
      lower.startsWith('content:') ||
      lower.startsWith('cbz://')) {
    return raw;
  }
  final base = baseUrl.trim();
  if (base.isEmpty) return raw;
  // 本地文件路径基址（Windows 盘符 / POSIX 绝对路径）：按目录拼接
  final isWindowsPath = RegExp(r'^[A-Za-z]:[\\/]').hasMatch(base);
  if (isWindowsPath || base.startsWith('/')) {
    if (raw.startsWith('/') || RegExp(r'^[A-Za-z]:[\\/]').hasMatch(raw)) {
      return raw;
    }
    final sep = math.max(base.lastIndexOf('/'), base.lastIndexOf('\\'));
    if (sep >= 0) return '${base.substring(0, sep + 1)}$raw';
    return raw;
  }
  final baseUri = Uri.tryParse(base);
  if (baseUri == null || baseUri.scheme.isEmpty) return raw;
  try {
    if (raw.startsWith('//')) return '${baseUri.scheme}:$raw';
    return baseUri.resolve(raw).toString();
  } catch (_) {
    return raw;
  }
}

/// 把复合 src 中的纯 URL 替换为绝对化结果，保留 `,{json}` 后缀
String rebuildReaderImageSrc(String original, String resolvedUrl) {
  final raw = original.trim();
  if (raw.isEmpty) return resolvedUrl;
  final separator = RegExp(r'\s*,\s*(?=\{)').firstMatch(raw);
  final originalUrl = separator == null
      ? raw
      : raw.substring(0, separator.start).trim();
  if (originalUrl == resolvedUrl) return raw;
  final idx = raw.indexOf(originalUrl);
  if (idx < 0) return resolvedUrl;
  return raw.replaceRange(idx, idx + originalUrl.length, resolvedUrl);
}

/// 解析正文中的图片 src 为 [ReaderInlineImage]
///
/// [rawSrc] 可以是 `<img>` 的 src 值（含 `,{json}`）或章节 `imgUrl`。
/// [baseUrl] 为正文抓取页/章节地址，用于相对地址绝对化。
ReaderInlineImage? parseReaderInlineImage(
  String? rawSrc, {
  String baseUrl = '',
}) {
  final raw = rawSrc?.trim() ?? '';
  if (raw.isEmpty) return null;
  final options = parseClickImgUrlOptions(raw);
  if (options.url.trim().isEmpty) return null;
  final resolvedUrl = resolveReaderImageUrl(options.url, baseUrl);
  return ReaderInlineImage(
    rawSrc: rebuildReaderImageSrc(raw, resolvedUrl),
    options: ClickImgUrlOptions(
      url: resolvedUrl,
      click: options.click,
      js: options.js,
      headers: options.headers,
      style: options.style,
      width: options.width,
    ),
  );
}

/// 解析图片显式宽度（`50%` / `120px` / 裸数值 `120`）
///
/// 返回 null 表示未指定或非法（调用方回落默认布局）。
double? parseReaderImageWidth(String? spec, double availableWidth) {
  final raw = spec?.trim() ?? '';
  if (raw.isEmpty) return null;
  if (raw.endsWith('%')) {
    final percent = double.tryParse(raw.substring(0, raw.length - 1).trim());
    if (percent == null || percent <= 0) return null;
    return availableWidth * percent / 100.0;
  }
  final numeric = raw.toLowerCase().endsWith('px')
      ? raw.substring(0, raw.length - 2).trim()
      : raw;
  final value = double.tryParse(numeric);
  if (value == null || value <= 0) return null;
  return value;
}

/// 单张图片的占位高度（测量未完成/失败时用）
///
/// 按 16:9 估计并限制在页面高度内：既不让占位过矮导致加载后大幅跳动，
/// 也保证分页不会因占位过高丢字。
double readerImagePlaceholderHeight(double availableWidth, double maxHeight) {
  final byWidth = availableWidth * 9.0 / 16.0;
  if (maxHeight.isFinite && maxHeight > 0) {
    return math.min(byWidth, maxHeight);
  }
  return byWidth;
}

/// 解析并决定图片的显示布局
///
/// 规则对齐上游：
/// 1. 显式 `style` 优先：`text`/`TEXT` 行内；`FULL`/`SINGLE`/`LEFT`/
///    `RIGHT`/`CENTER` 独立行；
/// 2. 无显式 style 时：固有宽高均 <80px → 行内（上游小图占位符）；
/// 3. 否则按书级 `imageStyle`：`TEXT` 全部行内，其余独立行；
/// 4. 宽度：显式 `width`（%/px/裸数值）优先；`FULL`/`SINGLE` 铺满可用宽；
///    `LEFT`/`RIGHT`/`CENTER` 只决定对齐，尺寸仍取固有宽；默认样式保留
///    固有宽度（不超过可用宽）；
/// 5. 高度按宽高比缩放，独立图片不超过 [maxHeight]；
/// 6. 固有尺寸未知/失败 → 占位尺寸，[ReaderImageLayout.placeholder]=true。
ReaderImageLayout resolveReaderImageLayout({
  required ReaderInlineImage image,
  required double availableWidth,
  required double maxHeight,
  required double textLineHeight,
  required double inlineSlotWidth,
  String? bookImageStyle,
  bool forceStandalone = false,
}) {
  final widthLimit = math.max(1.0, availableWidth);
  // [批16 三审 P3-6] maxHeight==0 是「没有可用高度」而非不限高：返回
  // 零尺寸布局，调用方（标题图）应跳过渲染。
  final heightLimit = maxHeight.isFinite
      ? math.max(0.0, maxHeight)
      : double.infinity;
  if (heightLimit <= 0) {
    return ReaderImageLayout(
      image: image,
      placement: ReaderImagePlacement.standalone,
      width: 0,
      height: 0,
      placeholder: true,
    );
  }
  final explicitStyle = (image.style ?? '').trim().toUpperCase();
  final bookStyle = (bookImageStyle ?? '').trim().toUpperCase();
  final size = ReaderImageSizeCache.lookup(image.rawSrc);
  final known = size != null && size.isValid;
  final failed = size != null && size.failed;

  var inline = false;
  if (!forceStandalone) {
    if (explicitStyle.isEmpty) {
      if (known &&
          size.width < readerImageInlineThreshold &&
          size.height < readerImageInlineThreshold) {
        inline = true;
      } else if (bookStyle == 'TEXT') {
        inline = true;
      }
    } else if (explicitStyle == 'TEXT') {
      inline = true;
    }
  }

  if (inline) {
    final slot = inlineSlotWidth > 0 ? inlineSlotWidth : textLineHeight;
    // 行内图只占一个占位符宽度（与上游 ImageColumn 以字符列宽绘制一致），
    // 显式 width 仅允许在小于占位宽时收窄，绝不超宽破坏断行结果。
    final explicitWidth = parseReaderImageWidth(image.widthSpec, widthLimit);
    var width = explicitWidth != null && explicitWidth < slot
        ? explicitWidth
        : slot;
    width = width.clamp(1.0, widthLimit);
    var height = known ? width * size.height / size.width : textLineHeight;
    if (known && height > heightLimit) {
      height = heightLimit;
      width = height * size.width / size.height;
    }
    // 行内图不独占：最大不超过可用宽；高度随宽高比（行高由排版侧取
    // max(文字行高, 图片高)），不额外做单页裁切。
    return ReaderImageLayout(
      image: image,
      placement: ReaderImagePlacement.inline,
      width: width,
      height: math.max(1.0, height),
      placeholder: !known || failed,
    );
  }

  final explicitWidth = parseReaderImageWidth(image.widthSpec, widthLimit);
  double preferredWidth;
  if (explicitWidth != null) {
    preferredWidth = explicitWidth;
  } else if (explicitStyle == 'FULL' ||
      explicitStyle == 'SINGLE' ||
      bookStyle == 'FULL' ||
      bookStyle == 'SINGLE') {
    // FULL/SINGLE 铺满可用宽；LEFT/RIGHT/CENTER 仅决定对齐，尺寸仍按
    // 固有宽（或显式 width）等比缩放（对齐上游 TextChapterLayout）。
    preferredWidth = widthLimit;
  } else if (known) {
    preferredWidth = math.min(size.width, widthLimit);
  } else {
    preferredWidth = widthLimit;
  }
  var width = preferredWidth.clamp(1.0, widthLimit);
  var height = known
      ? width * size.height / size.width
      : readerImagePlaceholderHeight(widthLimit, heightLimit);
  if (known && height > heightLimit) {
    height = heightLimit;
    width = height * size.width / size.height;
  }
  // 防止除零后宽度异常
  if (!width.isFinite || width <= 0) width = widthLimit;
  if (!height.isFinite || height <= 0) {
    height = readerImagePlaceholderHeight(widthLimit, heightLimit);
  }

  final align = switch (explicitStyle) {
    'LEFT' => ReaderImageAlignment.left,
    'RIGHT' => ReaderImageAlignment.right,
    _ => ReaderImageAlignment.center,
  };
  final single =
      explicitStyle == 'SINGLE' ||
      (explicitStyle.isEmpty && bookStyle == 'SINGLE');

  return ReaderImageLayout(
    image: image,
    placement: ReaderImagePlacement.standalone,
    width: width,
    height: height,
    alignment: align,
    pageBreakBefore: single,
    pageBreakAfter: single,
    placeholder: !known || failed,
  );
}

/// 远端图片地址是否允许 HTTP 兜底（仅 http/https，收紧 SSRF 面）
bool isReaderHttpImageUrl(String url) {
  final lower = url.trim().toLowerCase();
  return lower.startsWith('http://') || lower.startsWith('https://');
}

/// 是否本地文件路径（file:// / Windows 盘符 / POSIX 绝对路径 / UNC）
///
/// 仅用于「进入本地读盘安全校验」的分流；实际准入由
/// [resolveReaderLocalImageFile] 按「书文件存在 + 目录围栏」判定，
/// 不依赖书籍类型位/来源（WebDAV 落 LOCAL 位时同样走文件围栏）。
bool isReaderLocalFilePath(String url) {
  final raw = url.trim();
  if (raw.isEmpty) return false;
  final lower = raw.toLowerCase();
  if (lower.startsWith('file:')) return true;
  if (lower.startsWith('content:') || lower.startsWith('cbz://')) {
    return false;
  }
  if (raw.startsWith('\\\\') || raw.startsWith('//')) return true; // UNC
  if (RegExp(r'^[A-Za-z]:[\\/]').hasMatch(raw)) return true;
  return raw.startsWith('/');
}

String _normalizeFsPath(String path) {
  final unified = path.replaceAll('\\', '/');
  final isAbsolute =
      unified.startsWith('/') || RegExp(r'^[A-Za-z]:/').hasMatch(unified);
  final parts = unified.split('/');
  final out = <String>[];
  for (final part in parts) {
    if (part.isEmpty || part == '.') continue;
    if (part == '..') {
      if (out.isNotEmpty && out.last != '..') {
        out.removeLast();
      } else if (!isAbsolute) {
        out.add('..');
      }
      continue;
    }
    out.add(part);
  }
  final body = out.join('/');
  if (isAbsolute) {
    if (RegExp(r'^[A-Za-z]:$').hasMatch(out.isNotEmpty ? out.first : '')) {
      return body; // Windows 盘符相对
    }
    return '/$body';
  }
  return body;
}

/// 路径是否位于目录内（含目录本身；按平台大小写语义比较）
bool isPathInsideDirectory(String candidate, String directory) {
  final c = _normalizeFsPath(candidate);
  final d = _normalizeFsPath(directory);
  if (c.isEmpty || d.isEmpty) return false;
  final caseSensitive = !Platform.isWindows && !Platform.isMacOS;
  final cc = caseSensitive ? c : c.toLowerCase();
  final dd = caseSensitive ? d : d.toLowerCase();
  if (cc == dd) return true;
  return cc.startsWith(dd.endsWith('/') ? dd : '$dd/');
}

/// 解析并校验本地书正文图片文件（安全围栏）
///
/// 仅允许读取**书文件所在目录（含子目录）**内的图片；拒绝 UNC、路径
/// 穿越与符号链接逃逸。调用方传入经 `LocalBookStore.resolveSync` 解析的
/// 书文件真实路径；书文件不存在时返回 null（不依赖书籍类型位/来源）。
/// 返回 null 表示拒绝/不存在。
Future<File?> resolveReaderLocalImageFile({
  required String url,
  required String bookFilePath,
}) async {
  if (!isReaderLocalFilePath(url)) return null;
  final raw = url.trim();
  String path;
  final uri = Uri.tryParse(raw);
  if (uri != null && uri.scheme.toLowerCase() == 'file') {
    try {
      path = uri.toFilePath();
    } catch (_) {
      return null;
    }
  } else {
    path = raw;
  }
  if (path.contains('\u0000')) return null;
  // UNC/网络共享在 canonical 化前直接拒绝（避免触发网络路径访问）
  if (path.startsWith('\\\\') || path.startsWith('//')) return null;
  try {
    final book = File(bookFilePath);
    final bookDir = book.parent.path;
    // 先做纯文本前缀校验（不触碰候选路径），再做 canonical 校验防符号链接
    if (!isPathInsideDirectory(path, bookDir)) return null;
    final canonicalDir = await book.parent.resolveSymbolicLinks();
    final canonicalFile = await File(path).resolveSymbolicLinks();
    if (!isPathInsideDirectory(canonicalFile, canonicalDir)) return null;
    final file = File(canonicalFile);
    if (!await file.exists()) return null;
    return file;
  } catch (_) {
    return null;
  }
}

/// 解析 base64 data URI（本地解码，不走 HTTP）；失败返回 null
Uint8List? decodeReaderDataUriImage(String url) {
  final raw = url.trim();
  if (!raw.toLowerCase().startsWith('data:')) return null;
  final comma = raw.indexOf(',');
  if (comma < 0) return null;
  final meta = raw.substring(5, comma).toLowerCase();
  if (!meta.contains(';base64')) return null;
  try {
    final bytes = base64Decode(raw.substring(comma + 1));
    return bytes.isEmpty ? null : bytes;
  } catch (_) {
    return null;
  }
}

/// 把段落拆成 text/image run（img 正则与 `comic_image_utils.dart:56-59`
/// 完全一致，保留复合 `,{json}` 参数）
///
/// 文本 run 按原文顺序拼接后 = 原段落移除全部 `<img>` 标签后的文本（不
/// 插入/吞掉任何非标签字符），该性质由单测钉住。
List<ReaderParagraphRun> splitReaderParagraphRuns(
  String paragraph, {
  String baseUrl = '',
}) {
  if (paragraph.isEmpty) return const [];
  final runs = <ReaderParagraphRun>[];
  var last = 0;
  for (final match in comicImgSrcRegex.allMatches(paragraph)) {
    final src =
        match.group(1) ?? match.group(2) ?? match.group(3) ?? match.group(4);
    if (match.start > last) {
      runs.add(
        ReaderTextRun(
          paragraph.substring(last, match.start),
          start: last,
          end: match.start,
        ),
      );
    }
    final image = parseReaderInlineImage(src, baseUrl: baseUrl);
    if (image != null) {
      runs.add(ReaderImageRun(image, start: match.start, end: match.end));
    }
    last = match.end;
  }
  if (last < paragraph.length) {
    runs.add(
      ReaderTextRun(
        paragraph.substring(last),
        start: last,
        end: paragraph.length,
      ),
    );
  }
  if (runs.isEmpty) {
    runs.add(ReaderTextRun(paragraph, start: 0, end: paragraph.length));
  }
  return runs;
}

/// 收集正文中的全部图片（供阅读页预测量；按 rawSrc 去重保序）
List<ReaderInlineImage> collectReaderInlineImages(
  String content, {
  String baseUrl = '',
}) {
  if (content.isEmpty || !content.toLowerCase().contains('<img')) {
    return const [];
  }
  final seen = <String>{};
  final result = <ReaderInlineImage>[];
  for (final match in comicImgSrcRegex.allMatches(content)) {
    final src =
        match.group(1) ?? match.group(2) ?? match.group(3) ?? match.group(4);
    final image = parseReaderInlineImage(src, baseUrl: baseUrl);
    if (image == null) continue;
    if (seen.add(image.rawSrc)) result.add(image);
  }
  return result;
}

/// 章节标题图（`BookChapter.imgUrl`，对齐上游 `TextChapterLayout.kt:326-380`）
///
/// 基址优先 `chapter.baseUrl`，其次 `chapter.url`，最后书籍地址。
ReaderInlineImage? readerChapterTitleImage({
  String? imgUrl,
  String chapterBaseUrl = '',
  String chapterUrl = '',
  String bookUrl = '',
}) {
  final raw = imgUrl?.trim() ?? '';
  if (raw.isEmpty) return null;
  final base = chapterBaseUrl.trim().isNotEmpty
      ? chapterBaseUrl
      : (chapterUrl.trim().isNotEmpty ? chapterUrl : bookUrl);
  return parseReaderInlineImage(raw, baseUrl: base);
}
