// RSS 图片 data: URI 解码（批15g③ 收口）
//
// 对齐原版 `ReadRssViewModel.webData2bitmap`（`ReadRssViewModel.kt:248-256`）：
// 图片地址不是合法 URL 时按 `data:[mime];base64,<payload>` 处理——取逗号后
// 的 base64 正文解码为字节，不发起网络请求。原版对非法 base64 直接抛异常
// （保存失败 toast）；本实现改为**可展示的明确错误**，UI 不崩溃。
//
// 与原版的差异（有意收紧）：
// - 只接受 `image/*` MIME（原版不校验，任意 data URI 都尝试 base64 解码）；
// - 要求显式 `;base64` 标记（原版对非 base64 data URI 也会误当 base64 解码）；
// - 增加解码字节上限，避免超长 base64 撑爆内存（原版无上限）。

import 'dart:convert';
import 'dart:typed_data';

/// data: URI 图片解码结果的默认字节上限（32 MiB）
///
/// RSS 图片极少超过该体积；超限按「数据过大」报错，避免一次性解码
/// 数百 MB 的 base64 导致 OOM。
const int kMaxImageDataUriBytes = 32 * 1024 * 1024;

/// data: URI 图片解码失败（[message] 为可直接展示的中文文案）
class ImageDataUriException implements Exception {
  const ImageDataUriException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// data: URI 图片解码结果
class RssDataUriImage {
  const RssDataUriImage({
    required this.bytes,
    required this.mimeType,
    required this.extension,
  });

  /// 解码后的图片字节
  final Uint8List bytes;

  /// 原始 MIME（小写，如 `image/png`）
  final String mimeType;

  /// 保存用扩展名（含点，如 `.png`）
  final String extension;
}

/// data: URI 头部长度余量（粗判整串长度时预留，字节）
///
/// 典型头部 `data:image/png;base64,` 不足 32 字节；预留 512 字节覆盖
/// 常见 MIME 参数，避免粗判误伤合法输入。
const int _kMaxDataUriHeaderBytes = 512;

/// 是否为 `data:` URI（大小写/前导空白不敏感）
///
/// 批19 审查 P2-1/P3-4：本函数判定的是「是否 data: URI」而非「是否图片」，
/// 故命名 [isDataUri]；实现只比较前 5 个字符，不再对整串 `toLowerCase()`
/// （32 MiB 级拷贝，且被多处每帧调用）。
bool isDataUri(String value) {
  var start = 0;
  while (start < value.length && _isAsciiWhitespace(value.codeUnitAt(start))) {
    start++;
  }
  const prefix = 'data:';
  if (value.length - start < prefix.length) return false;
  for (var i = 0; i < prefix.length; i++) {
    final lower = _toLowerAscii(value.codeUnitAt(start + i));
    if (lower != prefix.codeUnitAt(i)) return false;
  }
  return true;
}

/// ASCII 空白（与 `String.trimLeft` 的常见输入口径一致）
bool _isAsciiWhitespace(int unit) =>
    unit == 0x20 || // 空格
    unit == 0x09 || // \t
    unit == 0x0A || // \n
    unit == 0x0D || // \r
    unit == 0x0B || // \v
    unit == 0x0C; // \f

/// data URI 中允许出现的空白（对齐 Dart `RegExp(r'\s')` 的匹配集合）
bool _isDataUriWhitespace(int unit) {
  if (_isAsciiWhitespace(unit)) return true;
  return unit == 0xA0 || // 不换行空格
      unit == 0x1680 ||
      (unit >= 0x2000 && unit <= 0x200A) ||
      unit == 0x2028 ||
      unit == 0x2029 ||
      unit == 0x202F ||
      unit == 0x205F ||
      unit == 0x3000 ||
      unit == 0xFEFF;
}

/// ASCII 大写字母转小写（其余码元原样返回）
int _toLowerAscii(int unit) =>
    unit >= 0x41 && unit <= 0x5A ? unit + 0x20 : unit;

/// 解析图片 data: URI
///
/// - 非 data: URI → 返回 `null`（调用方继续走网络/本地路径）；
/// - 是 data: URI 但非法/不支持 → 抛 [ImageDataUriException]（含中文原因）。
///
/// [maxBytes] 仅供单测注入小上限，生产保持 [kMaxImageDataUriBytes]。
RssDataUriImage? parseImageDataUri(
  String value, {
  int maxBytes = kMaxImageDataUriBytes,
}) {
  if (!isDataUri(value)) return null;

  final encodedLimit = (maxBytes * 4 ~/ 3) + 4;
  // 批19 审查 P2-2：在任何 trim/substring 整串拷贝之前先按原始长度粗判
  // （2 倍编码上限 + header 余量，覆盖换行/空白开销），避免为超大输入
  // 付出多次拷贝。
  final roughLimit = encodedLimit * 2 + _kMaxDataUriHeaderBytes;
  if (value.length > roughLimit) {
    throw ImageDataUriException(
      '图片数据过大（超过 ${_formatMegabytes(maxBytes)}）',
    );
  }

  final comma = value.indexOf(',');
  if (comma < 0) {
    throw const ImageDataUriException('data URI 缺少逗号分隔符');
  }
  // 精确预检（不拷贝）：统计逗号后的非空白字符数，超限直接拒绝，
  // 避免为超长输入执行 substring / 去空白 / base64 解码。
  var encodedCount = 0;
  for (var i = comma + 1; i < value.length; i++) {
    if (!_isDataUriWhitespace(value.codeUnitAt(i))) encodedCount++;
  }
  if (encodedCount > encodedLimit) {
    throw ImageDataUriException(
      '图片数据过大（超过 ${_formatMegabytes(maxBytes)}）',
    );
  }

  final text = value.trim();
  final textComma = text.indexOf(',');
  if (textComma < 0) {
    throw const ImageDataUriException('data URI 缺少逗号分隔符');
  }
  final header = text.substring('data:'.length, textComma);
  final payload = text.substring(textComma + 1);

  final parts = header.split(';');
  final mimeType = parts.first.trim().toLowerCase();
  if (!mimeType.startsWith('image/')) {
    throw ImageDataUriException(
      mimeType.isEmpty ? 'data URI 未声明图片类型' : '不是图片类型：$mimeType',
    );
  }

  final hasBase64 = parts
      .skip(1)
      .any((part) => part.trim().toLowerCase() == 'base64');
  if (!hasBase64) {
    throw const ImageDataUriException('data URI 缺少 base64 编码');
  }

  // data URI 允许换行/空白，解码前统一剥离
  final cleaned = payload.replaceAll(RegExp(r'\s+'), '');
  if (cleaned.isEmpty) {
    throw const ImageDataUriException('图片数据为空');
  }
  if (cleaned.length > encodedLimit) {
    throw ImageDataUriException(
      '图片数据过大（超过 ${_formatMegabytes(maxBytes)}）',
    );
  }

  Uint8List bytes;
  try {
    bytes = base64Decode(cleaned);
  } on FormatException {
    throw const ImageDataUriException('base64 数据无效');
  }
  if (bytes.isEmpty) {
    throw const ImageDataUriException('图片数据为空');
  }
  if (bytes.length > maxBytes) {
    throw ImageDataUriException(
      '图片数据过大（超过 ${_formatMegabytes(maxBytes)}）',
    );
  }

  return RssDataUriImage(
    bytes: bytes,
    mimeType: mimeType,
    extension: imageExtensionForMime(mimeType),
  );
}

/// MIME → 保存扩展名（未知 `image/*` 子类型回落 `.jpg`，与原版固定 `.jpg` 一致）
String imageExtensionForMime(String mimeType) {
  final mime = mimeType.trim().toLowerCase();
  switch (mime) {
    case 'image/jpeg':
    case 'image/jpg':
    case 'image/pjpeg':
      return '.jpg';
    case 'image/png':
    case 'image/apng':
      return '.png';
    case 'image/gif':
      return '.gif';
    case 'image/webp':
      return '.webp';
    case 'image/bmp':
    case 'image/x-ms-bmp':
      return '.bmp';
    case 'image/svg+xml':
      return '.svg';
    case 'image/x-icon':
    case 'image/vnd.microsoft.icon':
      return '.ico';
    case 'image/tiff':
    case 'image/x-tiff':
      return '.tiff';
    case 'image/avif':
      return '.avif';
    case 'image/heic':
      return '.heic';
    case 'image/heif':
      return '.heif';
    default:
      return '.jpg';
  }
}

/// 字节上限的可读展示（仅用于错误文案）
String _formatMegabytes(int bytes) {
  if (bytes >= 1024 * 1024) {
    final mb = bytes / (1024 * 1024);
    final text = mb == mb.roundToDouble()
        ? mb.toStringAsFixed(0)
        : mb.toStringAsFixed(1);
    return '$text MB';
  }
  return '${(bytes / 1024).toStringAsFixed(0)} KB';
}
