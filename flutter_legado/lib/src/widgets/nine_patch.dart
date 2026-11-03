// [设置批2b-1b-2b | 2026-11-03；回修 2026-11-03] Android `.9.png` 九宫格解析
// — 全栈工程师 + UI
//
// 语义基准（参考版 legado-with-MD3）：
// - `AppContainerBackground.kt:36-75`：Large/Item 背景图若路径以 `.9.png`
//   结尾，用 `BitmapFactory` + `NinePatchDrawable`（`ContentScale.FillBounds`）
//   拉伸；否则按普通图（默认 `ContentScale.Crop`）绘制。
// - `.9.png` 的拉伸区域记在 PNG 可选块 `npTc`（`Res_png_9patch`）。该块有
//   **两种物理格式**（AOSP ResourceTypes.h / ResourceTypes.cpp）：
//   1) 文件序列化格式（APK/资源文件中的真实形态，byte0 == 0）：
//      32 字节 header = wasDeserialized(0) + numXDivs + numYDivs +
//      numColors + xDivsOffset(4, 本机小端) + yDivsOffset(8, 本机小端) +
//      paddingLeft/Top/Right/Bottom(12/16/20/24, 本机小端) +
//      colorsOffset(28, 本机小端)；divs/colors 位于对应偏移处，值为
//      **大端 int32**（serialize() 用 htonl，网络序）。
//   2) Android 内存反序列化格式（byte0 == 1）：
//      4 字节 header 后紧跟 xDivs/yDivs/colors，值为**小端 int32**。
//   旧实现只按 (2) 解析，导致 release APK 内 114/114 真实 `.9.png` 全部
//   解析失败；本版优先按 (1) 解析并保留 (2) 兼容内存样例。
// - `npLb` 为 4 个 int32 布局边界（左/上/右/下，本机小端），仅解析留档，
//   不参与拉伸切片；序列化 header 内的 padding 作为 npLb 缺失时的回退。
// - 注意：aapt 编译时会移除 `.9.png` 的 1px 黑边标记并写入 npTc。源码形态
//   的 `.9.png`（只有黑边、无 npTc）无法表达拉伸区，按普通图 cover 回落
//   （参考版 `loadNinePatch` 读不到 ninePatchChunk 时同样回落 Crop）。
//
// 我方等价实现：Flutter `Image.centerSlice`。限制：
// - centerSlice 只支持**单**拉伸区域；x/y div 必须各恰好 2 个，否则回落
//   普通图（多区域拉伸 Flutter 无法表达，宁可退化也不画错）。
// - colors 数组（tint 颜色）忽略，仅登记不渲染。
// - centerSlice 与 `BoxFit.cover` 互斥（paintImage 断言），故 `.9` 固定
//   `BoxFit.fill`；普通图沿用 `BoxFit.cover`。
// - `.9` 不走 ResizeImage：centerSlice 以**解码像素**为坐标，ResizeImage
//   会缩小解码尺寸导致切片错位；为防止超大图 OOM，超过像素上限
//   （单边 8192 / 总量 32MP）时回落普通图并重新走 ResizeImage cover。
// - 解析失败（非 PNG/无 npTc/块损坏/坐标越界/CRC 不符/超限）→ 回落普通图，
//   与参考版 `loadNinePatch` 返回 null 后按 Crop 绘制一致。
// - 结果按「绝对路径 + mtime + 文件长度」做**有界 LRU** 缓存（默认 64 项，
//   含负结果）；文件被替换/重写后自动重新解析。解析是 O(块数) 的头部扫描，
//   不读入 IDAT 大块，并限制文件/块大小与块数量。
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'theme_background_layer.dart';

/// PNG 文件签名（8 字节）
const List<int> _pngSignature = <int>[137, 80, 78, 71, 13, 10, 26, 10];

/// `.9` 单边像素上限：超过回落普通图（ResizeImage cover），防全量解码 OOM
const int kMaxNinePatchDimension = 8192;

/// `.9` 像素总量上限（32MP）
const int kMaxNinePatchPixels = 32 * 1024 * 1024;

/// npTc/npLb 单块字节上限（正常块 < 1KB；防御畸形大块整体读入）
const int kMaxNinePatchChunkBytes = 1 << 20;

/// 解析源文件字节上限（与 ThemeBackgroundImageStore.maxBytes 同口径）
/// 测试可调小验证超限回落
@visibleForTesting
int maxNinePatchFileBytes = 32 * 1024 * 1024;

/// 单个 PNG 最多扫描的块数（防御海量空块拖慢解析）
const int _kMaxPngChunks = 4096;

/// 解析缓存上限（LRU，含负结果）；测试可调小验证淘汰
@visibleForTesting
int maxNinePatchCacheEntries = 64;

/// 九宫格解析结果
class NinePatchInfo {
  /// 拉伸中心区（源图像素坐标；Flutter `Image.centerSlice` 直接使用）
  final Rect centerSlice;

  /// 布局边界（npLb；缺失时为序列化 header padding）；无则为 null
  final Rect? layoutBounds;

  /// PNG 像素宽高（用于校验 div 坐标）
  final int width;
  final int height;

  const NinePatchInfo({
    required this.centerSlice,
    required this.width,
    required this.height,
    this.layoutBounds,
  });

  @override
  bool operator ==(Object other) =>
      other is NinePatchInfo &&
      other.centerSlice == centerSlice &&
      other.layoutBounds == layoutBounds &&
      other.width == width &&
      other.height == height;

  @override
  int get hashCode => Object.hash(centerSlice, layoutBounds, width, height);

  @override
  String toString() =>
      'NinePatchInfo(${width}x$height, centerSlice: $centerSlice, '
      'layoutBounds: $layoutBounds)';
}

/// 路径是否 `.9.png`（大小写不敏感）
bool isNinePatchPath(String path) => path.toLowerCase().endsWith('.9.png');

/// 解析 PNG 字节流中的九宫格信息；不可用返回 null（纯函数，便于单测）
NinePatchInfo? parseNinePatchPng(Uint8List bytes) {
  return _parsePng(bytes.length, (offset, length) {
    if (offset < 0 || length < 0 || offset + length > bytes.length) {
      return Uint8List(0);
    }
    return Uint8List.sublistView(bytes, offset, offset + length);
  });
}

/// 同步解析 `.9.png` 文件（路径+mtime+长度有界 LRU 缓存）
///
/// 非 `.9.png`、文件缺失、超限、解析失败均返回 null，调用方回落普通图。
NinePatchInfo? resolveNinePatchSync(String path) {
  if (!isNinePatchPath(path)) return null;
  try {
    final file = File(path);
    final stat = file.statSync();
    if (stat.type == FileSystemEntityType.notFound) return null;
    if (stat.size <= 0 || stat.size > maxNinePatchFileBytes) return null;
    final key = file.absolute.path;
    final cached = _cache.remove(key);
    if (cached != null &&
        cached.modifiedMs == stat.modified.millisecondsSinceEpoch &&
        cached.length == stat.size) {
      // 命中后重新插入，维持 LRU 顺序
      _cache[key] = cached;
      return cached.info;
    }
    final info = _parseFile(file, stat.size);
    _cache[key] = _NinePatchCacheEntry(
      modifiedMs: stat.modified.millisecondsSinceEpoch,
      length: stat.size,
      info: info,
    );
    _trimCache();
    return info;
  } catch (_) {
    // 权限/编码/IO 异常：按「非九宫格」回落，不阻断页面渲染
    return null;
  }
}

/// 测试隔离：清空解析缓存
@visibleForTesting
void resetNinePatchCache() => _cache.clear();

/// 测试/诊断：当前缓存条目数
@visibleForTesting
int ninePatchCacheEntryCount() => _cache.length;

/// 构建背景图片（大容器图 / 项目图共用）
///
/// - `.9.png` 且解析成功：`centerSlice + BoxFit.fill`（九宫格拉伸不模糊）；
/// - 其他情况（含解析失败/超限）：`BoxFit.cover` 普通图，沿用
///   [themeBackgroundImageProvider] 的窗口×DPR 解码上限。
Widget buildBackgroundImage({
  Key? key,
  required BuildContext context,
  required String path,
  BoxFit fallbackFit = BoxFit.cover,
  Alignment alignment = Alignment.center,
  ImageErrorWidgetBuilder? errorBuilder,
}) {
  final info = isNinePatchPath(path) ? resolveNinePatchSync(path) : null;
  final onError = errorBuilder ?? (_, _, _) => const SizedBox.shrink();
  if (info != null) {
    return Image(
      key: key,
      // 全量解码：centerSlice 以解码像素为坐标，不得再经 ResizeImage
      image: FileImage(File(path)),
      fit: BoxFit.fill,
      alignment: alignment,
      centerSlice: info.centerSlice,
      gaplessPlayback: true,
      errorBuilder: onError,
    );
  }
  return Image(
    key: key,
    image: themeBackgroundImageProvider(path, context),
    fit: fallbackFit,
    alignment: alignment,
    gaplessPlayback: true,
    errorBuilder: onError,
  );
}

// ===== 内部实现 =====

class _NinePatchCacheEntry {
  final int modifiedMs;
  final int length;
  final NinePatchInfo? info;

  const _NinePatchCacheEntry({
    required this.modifiedMs,
    required this.length,
    required this.info,
  });
}

/// 插入顺序即 LRU 顺序（Dart Map 默认 LinkedHashMap）
final Map<String, _NinePatchCacheEntry> _cache =
    <String, _NinePatchCacheEntry>{};

void _trimCache() {
  final limit =
      maxNinePatchCacheEntries > 0 ? maxNinePatchCacheEntries : 1;
  while (_cache.length > limit) {
    _cache.remove(_cache.keys.first);
  }
}

/// 只读 PNG 块头/目标块，跳过 IDAT 等大块
NinePatchInfo? _parseFile(File file, int fileLength) {
  if (fileLength <= 0 || fileLength > maxNinePatchFileBytes) return null;
  RandomAccessFile? raf;
  try {
    raf = file.openSync();
    final reader = raf;
    final info = _parsePng(fileLength, (offset, length) {
      reader.setPositionSync(offset);
      final out = Uint8List(length);
      var read = 0;
      while (read < length) {
        final chunk = reader.readSync(length - read);
        if (chunk.isEmpty) break;
        out.setRange(read, read + chunk.length, chunk);
        read += chunk.length;
      }
      return read == length ? out : Uint8List.sublistView(out, 0, read);
    });
    return info;
  } catch (_) {
    return null;
  } finally {
    try {
      raf?.closeSync();
    } catch (_) {
      // 关闭失败不影响解析结果
    }
  }
}

typedef _ReadRange = Uint8List Function(int offset, int length);

NinePatchInfo? _parsePng(int totalLength, _ReadRange read) {
  if (totalLength < _pngSignature.length ||
      totalLength > maxNinePatchFileBytes) {
    return null;
  }
  final signature = read(0, _pngSignature.length);
  if (signature.length != _pngSignature.length) return null;
  for (var i = 0; i < _pngSignature.length; i++) {
    if (signature[i] != _pngSignature[i]) return null;
  }

  var offset = _pngSignature.length;
  var chunkCount = 0;
  int? width;
  int? height;
  Uint8List? npTc;
  int? npTcCrc;
  Uint8List? npLb;
  int? npLbCrc;

  while (offset + 8 <= totalLength) {
    if (++chunkCount > _kMaxPngChunks) return null;
    final header = read(offset, 8);
    if (header.length != 8) return null;
    final headerData = ByteData.sublistView(header);
    final length = headerData.getUint32(0, Endian.big);
    final type = String.fromCharCodes(header.sublist(4, 8));
    final dataOffset = offset + 8;
    // 块数据 + 4 字节 CRC 必须完整落在文件内；CRC 不符由后续校验判定
    if (length > 0x7FFFFFFF || dataOffset + length + 4 > totalLength) {
      return null;
    }
    if (type == 'IHDR') {
      if (length < 13) return null;
      final ihdr = read(dataOffset, 13);
      if (ihdr.length != 13) return null;
      final data = ByteData.sublistView(ihdr);
      width = data.getUint32(0, Endian.big);
      height = data.getUint32(4, Endian.big);
      if (width <= 0 || height <= 0) return null;
    } else if (type == 'npTc') {
      // 畸形超大块直接回落，避免把整块读入内存
      if (length > kMaxNinePatchChunkBytes) return null;
      npTc = read(dataOffset, length);
      final crc = read(dataOffset + length, 4);
      if (npTc.length != length || crc.length != 4) return null;
      npTcCrc = ByteData.sublistView(crc).getUint32(0, Endian.big);
    } else if (type == 'npLb') {
      // npLb 仅用于布局边界，超限时忽略而非拖垮整图解析
      if (length <= kMaxNinePatchChunkBytes) {
        npLb = read(dataOffset, length);
        final crc = read(dataOffset + length, 4);
        if (npLb.length == length && crc.length == 4) {
          npLbCrc = ByteData.sublistView(crc).getUint32(0, Endian.big);
        } else {
          npLb = null;
        }
      }
    } else if (type == 'IEND') {
      break;
    }
    offset = dataOffset + length + 4;
  }

  if (width == null || height == null || npTc == null) return null;
  if (!_chunkCrcMatches('npTc', npTc, npTcCrc)) return null;
  final layout = npLb != null && _chunkCrcMatches('npLb', npLb, npLbCrc)
      ? _decodeLayoutBounds(npLb)
      : null;
  return _decodeNinePatch(npTc, width, height, layout);
}

/// `npTc` → centerSlice（仅单拉伸区域；其余形态返回 null）
NinePatchInfo? _decodeNinePatch(
  Uint8List chunk,
  int width,
  int height,
  Rect? layoutBounds,
) {
  // 像素上限：超限回落普通图（走 ResizeImage cover，避免全量解码 OOM）
  if (width <= 0 ||
      height <= 0 ||
      width > kMaxNinePatchDimension ||
      height > kMaxNinePatchDimension ||
      width * height > kMaxNinePatchPixels) {
    return null;
  }
  if (chunk.length < 4) return null;
  final format = chunk[0];
  final numX = chunk[1];
  final numY = chunk[2];
  final numColors = chunk[3];
  final data = ByteData.sublistView(chunk);
  Rect? headerPadding;
  late final List<int> xDivs;
  late final List<int> yDivs;

  if (format == 0) {
    // 文件序列化格式：32 字节 header；offset/padding 本机小端，divs 大端
    if (chunk.length < 32) return null;
    final xOffset = data.getInt32(4, Endian.little);
    final yOffset = data.getInt32(8, Endian.little);
    final colorsOffset = data.getInt32(28, Endian.little);
    if (!_validChunkRegion(xOffset, numX, chunk.length) ||
        !_validChunkRegion(yOffset, numY, chunk.length)) {
      return null;
    }
    if (numColors > 0 &&
        !_validChunkRegion(colorsOffset, numColors, chunk.length)) {
      return null;
    }
    xDivs = _readDivs(data, xOffset, numX, Endian.big);
    yDivs = _readDivs(data, yOffset, numY, Endian.big);
    final left = data.getInt32(12, Endian.little);
    final top = data.getInt32(16, Endian.little);
    final right = data.getInt32(20, Endian.little);
    final bottom = data.getInt32(24, Endian.little);
    final isZero = left == 0 && top == 0 && right == 0 && bottom == 0;
    if (!isZero && right >= left && bottom >= top) {
      headerPadding = Rect.fromLTRB(
        left.toDouble(),
        top.toDouble(),
        right.toDouble(),
        bottom.toDouble(),
      );
    }
  } else if (format == 1) {
    // Android 内存反序列化格式：4 字节 header 后直接跟 divs/colors（小端）
    final expected = 4 + (numX + numY + numColors) * 4;
    if (chunk.length < expected) return null;
    xDivs = _readDivs(data, 4, numX, Endian.little);
    yDivs = _readDivs(data, 4 + numX * 4, numY, Endian.little);
  } else {
    return null;
  }

  // x/y 各恰好一个拉伸区域；多区域 Flutter centerSlice 无法表达
  if (numX != 2 || numY != 2) return null;
  final x0 = xDivs[0];
  final x1 = xDivs[1];
  final y0 = yDivs[0];
  final y1 = yDivs[1];
  // 坐标必须递增且落在图像内（x1/y1 为**排他**右/下边界，可等于宽高）
  if (x0 < 0 || y0 < 0 || x1 <= x0 || y1 <= y0) return null;
  if (x1 > width || y1 > height) return null;

  return NinePatchInfo(
    centerSlice: Rect.fromLTRB(
      x0.toDouble(),
      y0.toDouble(),
      x1.toDouble(),
      y1.toDouble(),
    ),
    layoutBounds: layoutBounds ?? headerPadding,
    width: width,
    height: height,
  );
}

bool _validChunkRegion(int offset, int count, int chunkLength) {
  if (offset < 0 || count <= 0) return false;
  // 序列化格式的 divs/colors 必须位于 32 字节 header 之后
  if (offset < 32) return false;
  return offset <= chunkLength - count * 4;
}

List<int> _readDivs(
  ByteData data,
  int offset,
  int count,
  Endian endian,
) {
  final out = List<int>.filled(count, 0);
  for (var i = 0; i < count; i++) {
    out[i] = data.getInt32(offset + i * 4, endian);
  }
  return out;
}

/// `npLb` → 布局边界 (left, top, right, bottom)，本机小端
Rect? _decodeLayoutBounds(Uint8List chunk) {
  if (chunk.length < 16) return null;
  final data = ByteData.sublistView(chunk);
  final left = data.getInt32(0, Endian.little);
  final top = data.getInt32(4, Endian.little);
  final right = data.getInt32(8, Endian.little);
  final bottom = data.getInt32(12, Endian.little);
  if (right < left || bottom < top) return null;
  return Rect.fromLTRB(
    left.toDouble(),
    top.toDouble(),
    right.toDouble(),
    bottom.toDouble(),
  );
}

/// PNG 块 CRC32 校验（覆盖 type + data）
bool _chunkCrcMatches(String type, Uint8List data, int? expected) {
  if (expected == null) return false;
  final typeBytes = type.codeUnits;
  var crc = 0xFFFFFFFF;
  for (final b in typeBytes) {
    crc = _crcTable[(crc ^ b) & 0xFF] ^ (crc >> 8);
  }
  for (final b in data) {
    crc = _crcTable[(crc ^ b) & 0xFF] ^ (crc >> 8);
  }
  final actual = (crc ^ 0xFFFFFFFF) & 0xFFFFFFFF;
  return actual == expected;
}

final List<int> _crcTable = _buildCrcTable();

List<int> _buildCrcTable() {
  final table = List<int>.filled(256, 0);
  for (var n = 0; n < 256; n++) {
    var c = n;
    for (var k = 0; k < 8; k++) {
      c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1;
    }
    table[n] = c;
  }
  return table;
}
