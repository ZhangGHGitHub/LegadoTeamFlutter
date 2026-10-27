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

/// 是否为 data: URI（大小写/前导空白不敏感）
bool isImageDataUri(String value) {
  return value.trimLeft().toLowerCase().startsWith('data:');
}

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
  if (!isImageDataUri(value)) return null;
  final text = value.trim();

  final comma = text.indexOf(',');
  if (comma < 0) {
    throw const ImageDataUriException('data URI 缺少逗号分隔符');
  }
  final header = text.substring('data:'.length, comma);
  final payload = text.substring(comma + 1);

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
  final encodedLimit = (maxBytes * 4 ~/ 3) + 4;
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
