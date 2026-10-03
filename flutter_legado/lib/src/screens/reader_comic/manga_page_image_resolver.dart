import 'dart:convert';
import 'dart:typed_data';

import '../../services/book_api.dart';
import '../../utils/comic_image_utils.dart';

/// [P4-3 E5] 一页漫画图片的可操作字节 + 文件名后缀推断
class MangaPageImageBytes {
  /// 图片原始字节（PNG/JPEG/GIF/WEBP，经 [looksLikeImageBytes] 校验）
  final Uint8List bytes;

  /// 文件后缀（含点号，如 `.jpg`；仅按魔数推断，用于落盘文件名）
  final String suffix;

  const MangaPageImageBytes(this.bytes, this.suffix);
}

/// [P4-3 E5] 解析某页图片字节（不旁路重新下载）
///
/// 优先级与渲染链路 `_DecodedComicImage` 一致（契约 §2.46 磁盘缓存优先）：
/// 1. 内存缓存 [memoryCached]（渲染链已解码入 ComicImageDecodeCache，
///    当前可见页必然命中）；
/// 2. 磁盘缓存 `api.getImageCache`（未命中渲染才可能走到这里）；
/// 3. FFI `fetchImageWithDecode` 回退（仅 [sourceJson] 非 null 时；
///    与正常渲染管道同一 FFI 链路，非 HTTP 旁路重下）。
///
/// [cbz 批 D | 2026-10-03] 本地 cbz 页（[cbzPath] 非 null 且 url 为
/// `cbz://<条目名>` 伪 URL）：内存未命中 → FFI `cbz_read_page` 读 ZIP
/// 条目（cbz:// 无磁盘缓存/网络链路），字节经魔数校验后返回。
///
/// 全部未命中 / 解码无效时返回 null（调用方负责降级提示）。
Future<MangaPageImageBytes?> resolveMangaPageImageBytes({
  required BookApi api,
  required String bookUrl,
  required String url,
  String? sourceJson,
  String? cbzPath,
  Uint8List? memoryCached,
}) async {
  // 1. 内存缓存命中：零 IO 直接返回
  if (memoryCached != null && looksLikeImageBytes(memoryCached)) {
    return MangaPageImageBytes(memoryCached, _imageSuffixOf(memoryCached));
  }
  // 1b. 本地 cbz 页：cbzReadPage 读条目（与渲染链 _LocalCbzImage 同字节源）
  if (cbzPath != null && url.startsWith('cbz://')) {
    try {
      final json = await api.cbzReadPage(path: cbzPath, entry: url);
      final decoded = jsonDecode(json) as Map<String, dynamic>;
      final b64 = decoded['base64'] as String? ?? '';
      if (b64.isEmpty) return null;
      final bytes = base64Decode(b64);
      if (!looksLikeImageBytes(bytes)) return null;
      return MangaPageImageBytes(
        Uint8List.fromList(bytes),
        _imageSuffixOf(bytes),
      );
    } catch (_) {
      return null;
    }
  }
  // 2. 磁盘缓存命中（对齐 _DecodedComicImage 的本地优先语义）
  try {
    final disk = await api.getImageCache(bookUrl, url);
    if (disk != null && disk.isNotEmpty && looksLikeImageBytes(disk)) {
      final bytes = disk is Uint8List ? disk : Uint8List.fromList(disk);
      return MangaPageImageBytes(bytes, _imageSuffixOf(bytes));
    }
  } catch (_) {
    // 磁盘缓存读失败：继续 FFI 回退（读失败不影响在线链路）
  }
  // 3. FFI 解码回退（无 sourceJson 时不旁路直连，直接放弃）
  if (sourceJson == null) return null;
  try {
    final json = await api.fetchImageWithDecode(url, sourceJson);
    final decoded = jsonDecode(json) as Map<String, dynamic>;
    final b64 = decoded['base64'] as String? ?? '';
    if (b64.isEmpty) return null;
    final bytes = base64Decode(b64);
    if (!looksLikeImageBytes(bytes)) return null;
    return MangaPageImageBytes(Uint8List.fromList(bytes), _imageSuffixOf(bytes));
  } catch (_) {
    return null;
  }
}

/// 按魔数推断图片文件后缀（对齐 comic_image_utils 判型集合）
String _imageSuffixOf(Uint8List bytes) {
  if (bytes.length < 4) return '.jpg';
  if (bytes[0] == 0xFF && bytes[1] == 0xD8) return '.jpg';
  if (bytes[0] == 0x89 &&
      bytes[1] == 0x50 &&
      bytes[2] == 0x4E &&
      bytes[3] == 0x47) {
    return '.png';
  }
  if (bytes[0] == 0x47 && bytes[1] == 0x49 && bytes[2] == 0x46) return '.gif';
  if (bytes.length >= 12 &&
      bytes[0] == 0x52 &&
      bytes[1] == 0x49 &&
      bytes[2] == 0x46 &&
      bytes[3] == 0x46 &&
      bytes[8] == 0x57 &&
      bytes[9] == 0x45 &&
      bytes[10] == 0x42 &&
      bytes[11] == 0x50) {
    return '.webp';
  }
  return '.jpg';
}
