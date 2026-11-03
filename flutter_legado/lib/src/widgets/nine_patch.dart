// [设置批2b-1b-2b | 2026-11-03] Android `.9.png` 九宫格解析 — 全栈工程师 + UI
//
// 语义基准（参考版 legado-with-MD3）：
// - `AppContainerBackground.kt:36-75`：Large/Item 背景图若路径以 `.9.png`
//   结尾，用 `BitmapFactory` + `NinePatchDrawable`（`ContentScale.FillBounds`）
//   拉伸；否则按普通图（默认 `ContentScale.Crop`）绘制。
// - `.9.png` 的拉伸区域记在 PNG 可选块 `npTc`（`Res_png_9patch` 的内存
//   序列化布局）：`wasDeserialized=1, numXDivs, numYDivs, numColors`，
//   随后是 xDivs[]、yDivs[]、colors[]；整数为**小端 int32**
//   （构建主机与 Android 设备均为小端，参考 `NinePatch` 直接按 native
//   布局解释该块）。
// - `npLb` 为 4 个 int32 布局边界（左/上/右/下，像素），仅解析留档，
//   不参与拉伸切片。
//
// 我方等价实现：Flutter `Image.centerSlice`。限制：
// - centerSlice 只支持**单**拉伸区域；x/y div 必须各恰好 2 个，否则回落
//   普通图（多区域拉伸 Flutter 无法表达，宁可退化也不画错）。
// - centerSlice 与 `BoxFit.cover` 互斥（paintImage 断言），故 `.9` 固定
//   `BoxFit.fill`；普通图沿用 `BoxFit.cover`。
// - `.9` 不走 ResizeImage：centerSlice 以**解码像素**为坐标，ResizeImage
//   会缩小解码尺寸导致切片错位；九宫格素材通常很小，全量解码可接受。
// - 解析失败（非 PNG/无 npTc/块损坏/坐标越界/CRC 不符）→ 回落普通图，
//   与参考版 `loadNinePatch` 返回 null 后按 Crop 绘制一致。
// - 结果按「绝对路径 + mtime + 文件长度」缓存；文件被替换/重写后自动
//   重新解析。解析是 O(块数) 的头部扫描，不读入 IDAT 大块。
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'theme_background_layer.dart';

/// PNG 文件签名（8 字节）
const List<int> _pngSignature = <int>[137, 80, 78, 71, 13, 10, 26, 10];

/// 九宫格解析结果
class NinePatchInfo {
  /// 拉伸中心区（源图像素坐标；Flutter `Image.centerSlice` 直接使用）
  final Rect centerSlice;

  /// `npLb` 布局边界（像素）；无该块时为 null
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

/// 同步解析 `.9.png` 文件（路径+mtime+长度缓存）
///
/// 非 `.9.png`、文件缺失、解析失败均返回 null，调用方回落普通图。
NinePatchInfo? resolveNinePatchSync(String path) {
  if (!isNinePatchPath(path)) return null;
  try {
    final file = File(path);
    final stat = file.statSync();
    if (stat.type == FileSystemEntityType.notFound) return null;
    if (stat.size <= 0) return null;
    final key = file.absolute.path;
    final cached = _cache[key];
    if (cached != null &&
        cached.modifiedMs == stat.modified.millisecondsSinceEpoch &&
        cached.length == stat.size) {
      return cached.info;
    }
    final info = _parseFile(file, stat.size);
    _cache[key] = _NinePatchCacheEntry(
      modifiedMs: stat.modified.millisecondsSinceEpoch,
      length: stat.size,
      info: info,
    );
    return info;
  } catch (_) {
    // 权限/编码/IO 异常：按「非九宫格」回落，不阻断页面渲染
    return null;
  }
}

/// 测试隔离：清空解析缓存
@visibleForTesting
void resetNinePatchCache() => _cache.clear();

/// 构建背景图片（大容器图 / 项目图共用）
///
/// - `.9.png` 且解析成功：`centerSlice + BoxFit.fill`（九宫格拉伸不模糊）；
/// - 其他情况（含解析失败）：`BoxFit.cover` 普通图，沿用
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

final Map<String, _NinePatchCacheEntry> _cache =
    <String, _NinePatchCacheEntry>{};

/// 只读 PNG 块头/目标块，跳过 IDAT 等大块
NinePatchInfo? _parseFile(File file, int fileLength) {
  RandomAccessFile? raf;
  try {
    raf = file.openSync();
    final reader = raf;
    return _parsePng(fileLength, (offset, length) {
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
  if (totalLength < _pngSignature.length) return null;
  final signature = read(0, _pngSignature.length);
  if (signature.length != _pngSignature.length) return null;
  for (var i = 0; i < _pngSignature.length; i++) {
    if (signature[i] != _pngSignature[i]) return null;
  }

  var offset = _pngSignature.length;
  int? width;
  int? height;
  Uint8List? npTc;
  int? npTcCrc;
  Uint8List? npLb;
  int? npLbCrc;

  while (offset + 8 <= totalLength) {
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
      npTc = read(dataOffset, length);
      final crc = read(dataOffset + length, 4);
      if (npTc.length != length || crc.length != 4) return null;
      npTcCrc = ByteData.sublistView(crc).getUint32(0, Endian.big);
    } else if (type == 'npLb') {
      npLb = read(dataOffset, length);
      final crc = read(dataOffset + length, 4);
      if (npLb.length != length || crc.length != 4) return null;
      npLbCrc = ByteData.sublistView(crc).getUint32(0, Endian.big);
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
  if (chunk.length < 4) return null;
  // 未反序列化标记必须为 1（Android NinePatch.isNinePatchChunk 同口径）
  if (chunk[0] != 1) return null;
  final numX = chunk[1];
  final numY = chunk[2];
  final numColors = chunk[3];
  final expected = 4 + (numX + numY + numColors) * 4;
  if (chunk.length < expected) return null;
  // x/y 各恰好一个拉伸区域；多区域 Flutter centerSlice 无法表达
  if (numX != 2 || numY != 2) return null;

  final data = ByteData.sublistView(chunk);
  int readI32(int index) => data.getInt32(index, Endian.little);

  final x0 = readI32(4);
  final x1 = readI32(8);
  final y0 = readI32(12);
  final y1 = readI32(16);
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
    layoutBounds: layoutBounds,
    width: width,
    height: height,
  );
}

/// `npLb` → 布局边界 (left, top, right, bottom)
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
