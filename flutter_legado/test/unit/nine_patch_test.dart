// [设置批2b-1b-2b | 2026-11-03；回修 2026-11-03] `.9.png` 九宫格解析单测
// — 全栈工程师 + UI
//
// 覆盖：**文件序列化格式**（npTc byte0=0，32 字节 header，offset/padding
// 本机小端，divs 大端）与 **Android 内存反序列化格式**（byte0=1，divs
// 小端）的解析/切片/npLb；真实 APK fixture（res/0x.9.png 单区域、
// res/1J.9.png 多区域、去 npTc 源码形态）；CRC/偏移/长度/坐标/格式标记
// 损坏回落；像素与块大小上限；路径后缀；mtime+长度缓存失效与有界 LRU。
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'package:flutter_legado/src/widgets/nine_patch.dart';

/// 真实 fixture 来源：参考版 release APK（.tmp/kazusa.apk）内
/// `res/0x.9.png`（12x12，x/y divs=(4,8)，npTc 为文件序列化格式）、
/// `res/1J.9.png`（54x54，x/y 各 4 divs → 多拉伸区域）与由 0x 去除
/// npTc 后得到的源码形态 `.9.png`（仅黑边标记、无拉伸块）。
const String _fixture0x = 'test/fixtures/nine_patch_0x.9.png';
const String _fixture1J = 'test/fixtures/nine_patch_1J.9.png';
const String _fixtureNoNpTc =
    'test/fixtures/nine_patch_source_no_nptc.9.png';

/// CRC32（PNG chunk 校验，同实现逻辑）
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

int _crc32(Iterable<int> bytes) {
  var crc = 0xFFFFFFFF;
  for (final b in bytes) {
    crc = _crcTable[(crc ^ b) & 0xFF] ^ (crc >> 8);
  }
  return (crc ^ 0xFFFFFFFF) & 0xFFFFFFFF;
}

Uint8List _pngChunk(String type, List<int> data, {int? crcOverride}) {
  final typeBytes = type.codeUnits;
  final bytes = Uint8List(8 + data.length + 4);
  final view = ByteData.sublistView(bytes);
  view.setUint32(0, data.length, Endian.big);
  bytes.setRange(4, 8, typeBytes);
  bytes.setRange(8, 8 + data.length, data);
  view.setUint32(
    8 + data.length,
    crcOverride ?? _crc32(<int>[...typeBytes, ...data]),
    Endian.big,
  );
  return bytes;
}

/// 在 IHDR 后插入块（构造合法可解码 PNG）
Uint8List _insertAfterIhdr(
  Uint8List png,
  String type,
  List<int> data, {
  int? crcOverride,
}) {
  final ihdrLength = ByteData.sublistView(png, 8, 12).getUint32(0, Endian.big);
  final ihdrEnd = 8 + 12 + ihdrLength;
  final out = BytesBuilder(copy: false)
    ..add(png.sublist(0, ihdrEnd))
    ..add(_pngChunk(type, data, crcOverride: crcOverride))
    ..add(png.sublist(ihdrEnd));
  return out.toBytes();
}

/// 实色 PNG（真实可解码；供切片坐标使用）
Uint8List _basePng({int width = 9, int height = 9}) {
  final image = img.Image(width: width, height: height);
  img.fill(image, color: img.ColorRgb8(200, 30, 30));
  return Uint8List.fromList(img.encodePng(image));
}

/// 只有 IHDR/npTc/IEND 的伪 PNG（解析器只读头部，不校验 IDAT；用于构造
/// 超限尺寸/超大块等无法真实编码的极端样例）
Uint8List _fakePngWithSize(int width, int height, List<int> npTcData) {
  final ihdr = Uint8List(13);
  final view = ByteData.sublistView(ihdr);
  view.setUint32(0, width, Endian.big);
  view.setUint32(4, height, Endian.big);
  ihdr[8] = 8; // bit depth
  ihdr[9] = 6; // color type RGBA
  final out = BytesBuilder(copy: false)
    ..add(const <int>[137, 80, 78, 71, 13, 10, 26, 10])
    ..add(_pngChunk('IHDR', ihdr))
    ..add(_pngChunk('npTc', npTcData))
    ..add(_pngChunk('IEND', const <int>[]));
  return out.toBytes();
}

/// Android 内存反序列化格式（byte0=1，4 字节 header + 小端 int32）
List<int> _deserializedNpTcData({
  required int numX,
  required int numY,
  List<int> xDivs = const <int>[],
  List<int> yDivs = const <int>[],
  int numColors = 0,
  List<int> colors = const <int>[],
  int version = 1,
}) {
  final values = <int>[...xDivs, ...yDivs, ...colors];
  final bytes = Uint8List(4 + values.length * 4);
  bytes[0] = version;
  bytes[1] = numX;
  bytes[2] = numY;
  bytes[3] = numColors;
  final view = ByteData.sublistView(bytes);
  for (var i = 0; i < values.length; i++) {
    view.setInt32(4 + i * 4, values[i], Endian.little);
  }
  return bytes;
}

/// PNG 文件序列化格式（byte0=0，32 字节 header；offset/padding 本机小端，
/// divs/colors 大端 int32）
List<int> _serializedNpTcData({
  required int numX,
  required int numY,
  List<int> xDivs = const <int>[],
  List<int> yDivs = const <int>[],
  int numColors = 0,
  List<int> colors = const <int>[],
  int paddingLeft = 0,
  int paddingTop = 0,
  int paddingRight = 0,
  int paddingBottom = 0,
  int? xOffsetOverride,
  int? yOffsetOverride,
  int? colorsOffsetOverride,
}) {
  final xOffset = 32;
  final yOffset = xOffset + numX * 4;
  final colorsOffset = yOffset + numY * 4;
  final total = colorsOffset + numColors * 4;
  final bytes = Uint8List(total);
  bytes[0] = 0; // 文件序列化格式
  bytes[1] = numX;
  bytes[2] = numY;
  bytes[3] = numColors;
  final view = ByteData.sublistView(bytes);
  view.setInt32(4, xOffsetOverride ?? xOffset, Endian.little);
  view.setInt32(8, yOffsetOverride ?? yOffset, Endian.little);
  view.setInt32(12, paddingLeft, Endian.little);
  view.setInt32(16, paddingTop, Endian.little);
  view.setInt32(20, paddingRight, Endian.little);
  view.setInt32(24, paddingBottom, Endian.little);
  view.setInt32(28, colorsOffsetOverride ?? colorsOffset, Endian.little);
  void writeBigEndian(int offset, List<int> values) {
    for (var i = 0; i < values.length; i++) {
      view.setInt32(offset + i * 4, values[i], Endian.big);
    }
  }

  writeBigEndian(xOffset, xDivs);
  writeBigEndian(yOffset, yDivs);
  writeBigEndian(colorsOffset, colors);
  return bytes;
}

List<int> _npLbData(int left, int top, int right, int bottom) {
  final bytes = Uint8List(16);
  final view = ByteData.sublistView(bytes);
  view.setInt32(0, left, Endian.little);
  view.setInt32(4, top, Endian.little);
  view.setInt32(8, right, Endian.little);
  view.setInt32(12, bottom, Endian.little);
  return bytes;
}

/// 反序列化格式 PNG（byte0=1，兼容旧样例/内存形态）
Uint8List _deserializedNinePatchPng({
  List<int>? xDivs,
  List<int>? yDivs,
  List<int>? npLb,
  int? crcOverride,
  int? numXOverride,
  int? numYOverride,
  int version = 1,
}) {
  final x = xDivs ?? const <int>[2, 7];
  final y = yDivs ?? const <int>[2, 7];
  final data = _deserializedNpTcData(
    numX: numXOverride ?? x.length,
    numY: numYOverride ?? y.length,
    xDivs: x,
    yDivs: y,
    version: version,
  );
  var png = _insertAfterIhdr(
    _basePng(),
    'npTc',
    data,
    crcOverride: crcOverride,
  );
  if (npLb != null) {
    png = _insertAfterIhdr(png, 'npLb', npLb);
  }
  return png;
}

/// 序列化格式 PNG（byte0=0，APK 内真实形态）
Uint8List _serializedNinePatchPng({
  List<int>? xDivs,
  List<int>? yDivs,
  List<int>? npLb,
  int? crcOverride,
  int? xOffsetOverride,
  int? yOffsetOverride,
  int? colorsOffsetOverride,
  int numColors = 0,
  List<int> colors = const <int>[],
  int paddingLeft = 0,
  int paddingTop = 0,
  int paddingRight = 0,
  int paddingBottom = 0,
}) {
  final x = xDivs ?? const <int>[2, 7];
  final y = yDivs ?? const <int>[2, 7];
  final data = _serializedNpTcData(
    numX: x.length,
    numY: y.length,
    xDivs: x,
    yDivs: y,
    numColors: numColors,
    colors: colors,
    paddingLeft: paddingLeft,
    paddingTop: paddingTop,
    paddingRight: paddingRight,
    paddingBottom: paddingBottom,
    xOffsetOverride: xOffsetOverride,
    yOffsetOverride: yOffsetOverride,
    colorsOffsetOverride: colorsOffsetOverride,
  );
  var png = _insertAfterIhdr(
    _basePng(),
    'npTc',
    data,
    crcOverride: crcOverride,
  );
  if (npLb != null) {
    png = _insertAfterIhdr(png, 'npLb', npLb);
  }
  return png;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    resetNinePatchCache();
    maxNinePatchCacheEntries = 64;
    maxNinePatchFileBytes = 32 * 1024 * 1024;
  });
  tearDown(() {
    resetNinePatchCache();
    maxNinePatchCacheEntries = 64;
    maxNinePatchFileBytes = 32 * 1024 * 1024;
  });

  group('文件序列化格式（byte0=0，APK 真实形态）', () {
    test('单拉伸区域 → centerSlice（大端 divs）', () {
      final info = parseNinePatchPng(_serializedNinePatchPng());
      expect(info, isNotNull);
      expect(info!.centerSlice, const Rect.fromLTRB(2, 2, 7, 7));
      expect(info.width, 9);
      expect(info.height, 9);
    });

    test('真实 APK fixture res/0x.9.png → centerSlice=(4,4,8,8)', () {
      final bytes = File(_fixture0x).readAsBytesSync();
      final info = parseNinePatchPng(bytes);
      expect(info, isNotNull);
      expect(info!.width, 12);
      expect(info.height, 12);
      expect(info.centerSlice, const Rect.fromLTRB(4, 4, 8, 8));
      // 0x 无 npLb，且 header padding 全 0 → 无布局边界
      expect(info.layoutBounds, isNull);
    });

    test('npLb 优先于 header padding', () {
      final info = parseNinePatchPng(
        _serializedNinePatchPng(
          npLb: _npLbData(1, 2, 3, 4),
          paddingLeft: 5,
          paddingTop: 6,
          paddingRight: 7,
          paddingBottom: 8,
        ),
      );
      expect(info, isNotNull);
      expect(info!.layoutBounds, const Rect.fromLTRB(1, 2, 3, 4));
    });

    test('无 npLb 时 header padding 作为布局边界回退', () {
      final info = parseNinePatchPng(
        _serializedNinePatchPng(
          paddingLeft: 5,
          paddingTop: 6,
          paddingRight: 7,
          paddingBottom: 8,
        ),
      );
      expect(info, isNotNull);
      expect(info!.layoutBounds, const Rect.fromLTRB(5, 6, 7, 8));
    });

    test('真实 APK fixture res/1J.9.png：多拉伸区域回落 null', () {
      final bytes = File(_fixture1J).readAsBytesSync();
      expect(parseNinePatchPng(bytes), isNull);
    });

    test('源码形态 `.9.png`（无 npTc）回落 null', () {
      final bytes = File(_fixtureNoNpTc).readAsBytesSync();
      expect(parseNinePatchPng(bytes), isNull);
    });

    test('CRC 损坏回落', () {
      expect(
        parseNinePatchPng(_serializedNinePatchPng(crcOverride: 0xDEADBEEF)),
        isNull,
      );
    });

    test('header 截断（<32 字节）回落', () {
      final data = Uint8List(20);
      data[0] = 0;
      data[1] = 2;
      data[2] = 2;
      final png = _insertAfterIhdr(_basePng(), 'npTc', data);
      expect(parseNinePatchPng(png), isNull);
    });

    test('offset 非法（指向 header 内/越界/颜色区越界）回落', () {
      expect(
        parseNinePatchPng(_serializedNinePatchPng(xOffsetOverride: 8)),
        isNull,
      );
      expect(
        parseNinePatchPng(_serializedNinePatchPng(yOffsetOverride: 4096)),
        isNull,
      );
      expect(
        parseNinePatchPng(
          _serializedNinePatchPng(
            numColors: 2,
            colors: const <int>[1, 2],
            colorsOffsetOverride: 4096,
          ),
        ),
        isNull,
      );
    });

    test('坐标越界回落', () {
      expect(
        parseNinePatchPng(_serializedNinePatchPng(xDivs: const <int>[2, 20])),
        isNull,
      );
      expect(
        parseNinePatchPng(_serializedNinePatchPng(yDivs: const <int>[6, 3])),
        isNull,
      );
    });

    test('像素上限：单边 8193 或总量 >32MP → null（回落 ResizeImage）', () {
      final npTc = _serializedNpTcData(
        numX: 2,
        numY: 2,
        xDivs: const <int>[2, 7],
        yDivs: const <int>[2, 7],
      );
      expect(parseNinePatchPng(_fakePngWithSize(8193, 1, npTc)), isNull);
      expect(parseNinePatchPng(_fakePngWithSize(8000, 5000, npTc)), isNull);
      // 上限内仍可解析
      expect(parseNinePatchPng(_fakePngWithSize(100, 100, npTc)), isNotNull);
    });

    test('npTc 块超 1MB → null（不整体读入）', () {
      final huge = Uint8List(kMaxNinePatchChunkBytes + 1);
      expect(
        parseNinePatchPng(_fakePngWithSize(9, 9, huge)),
        isNull,
      );
    });
  });

  group('反序列化内存格式（byte0=1，兼容）', () {
    test('单拉伸区域 → centerSlice（小端 divs）', () {
      final info = parseNinePatchPng(_deserializedNinePatchPng());
      expect(info, isNotNull);
      expect(info!.centerSlice, const Rect.fromLTRB(2, 2, 7, 7));
      expect(info.width, 9);
      expect(info.height, 9);
    });

    test('可选 npLb → 布局边界（不影响 centerSlice）', () {
      final info = parseNinePatchPng(
        _deserializedNinePatchPng(npLb: _npLbData(1, 2, 3, 4)),
      );
      expect(info, isNotNull);
      expect(info!.centerSlice, const Rect.fromLTRB(2, 2, 7, 7));
      expect(info.layoutBounds, const Rect.fromLTRB(1, 2, 3, 4));
    });

    test('x1/y1 可等于图像宽高（右下无固定边）', () {
      final info = parseNinePatchPng(
        _deserializedNinePatchPng(
          xDivs: const <int>[0, 9],
          yDivs: const <int>[0, 9],
        ),
      );
      expect(info, isNotNull);
      expect(info!.centerSlice, const Rect.fromLTRB(0, 0, 9, 9));
    });

    test('无 npTc 块 / 非 PNG 字节', () {
      expect(parseNinePatchPng(_basePng()), isNull);
      expect(
        parseNinePatchPng(Uint8List.fromList(<int>[1, 2, 3, 4, 5, 6, 7, 8])),
        isNull,
      );
    });

    test('npTc CRC 损坏 / 声明 div 数与数据长度不符', () {
      expect(
        parseNinePatchPng(_deserializedNinePatchPng(crcOverride: 0xDEADBEEF)),
        isNull,
      );
      expect(
        parseNinePatchPng(
          _deserializedNinePatchPng(numXOverride: 4, numYOverride: 2),
        ),
        isNull,
      );
    });

    test('多拉伸区域（4 divs）→ 回落（Flutter centerSlice 无法表达）', () {
      expect(
        parseNinePatchPng(
          _deserializedNinePatchPng(
            xDivs: const <int>[1, 3, 5, 7],
            yDivs: const <int>[1, 3, 5, 7],
          ),
        ),
        isNull,
      );
    });

    test('坐标越界/逆序', () {
      expect(
        parseNinePatchPng(
          _deserializedNinePatchPng(xDivs: const <int>[2, 20]),
        ),
        isNull,
      );
      expect(
        parseNinePatchPng(
          _deserializedNinePatchPng(yDivs: const <int>[6, 3]),
        ),
        isNull,
      );
      expect(
        parseNinePatchPng(
          _deserializedNinePatchPng(xDivs: const <int>[-1, 7]),
        ),
        isNull,
      );
    });

    test('未知格式标记（非 0/1）→ null', () {
      expect(
        parseNinePatchPng(_deserializedNinePatchPng(version: 2)),
        isNull,
      );
    });

    test('npTc 块被截断（块长超出文件）', () {
      final png = _deserializedNinePatchPng();
      final ihdrLength =
          ByteData.sublistView(png, 8, 12).getUint32(0, Endian.big);
      final npTcStart = 8 + 12 + ihdrLength;
      expect(
        parseNinePatchPng(Uint8List.sublistView(png, 0, npTcStart + 12)),
        isNull,
      );
    });
  });

  group('路径与缓存', () {
    test('仅 `.9.png` 后缀（大小写不敏感）视为九宫格', () {
      expect(isNinePatchPath('a.9.png'), isTrue);
      expect(isNinePatchPath('A.9.PNG'), isTrue);
      expect(isNinePatchPath('a.png'), isFalse);
      expect(isNinePatchPath('a.9.jpg'), isFalse);
      expect(isNinePatchPath(''), isFalse);
    });

    test('真实 fixture 文件解析 + 路径/mtime/长度缓存失效', () async {
      final dir = await Directory.systemTemp.createTemp('legado_nine_patch_');
      addTearDown(() async {
        if (await dir.exists()) await dir.delete(recursive: true);
      });
      final file = File('${dir.path}${Platform.pathSeparator}frame.9.png');
      await file.writeAsBytes(File(_fixture0x).readAsBytesSync());

      final first = resolveNinePatchSync(file.path);
      expect(first, isNotNull);
      expect(first!.centerSlice, const Rect.fromLTRB(4, 4, 8, 8));
      expect(identical(resolveNinePatchSync(file.path), first), isTrue,
          reason: 'mtime/长度未变 → 命中缓存');

      // 覆盖为无 npTc 版本（长度不同 → 缓存失效，解析为 null）
      await file.writeAsBytes(File(_fixtureNoNpTc).readAsBytesSync());
      expect(resolveNinePatchSync(file.path), isNull);

      // 恢复 → 重新解析成功
      await file.writeAsBytes(File(_fixture0x).readAsBytesSync());
      expect(resolveNinePatchSync(file.path), isNotNull);
    });

    test('缓存有界（LRU 淘汰最旧条目）', () async {
      final dir = await Directory.systemTemp.createTemp('legado_nine_patch_');
      addTearDown(() async {
        if (await dir.exists()) await dir.delete(recursive: true);
      });
      final bytes = File(_fixture0x).readAsBytesSync();
      final paths = <String>[];
      for (var i = 0; i < 3; i++) {
        final file = File('${dir.path}${Platform.pathSeparator}p$i.9.png');
        await file.writeAsBytes(bytes);
        paths.add(file.path);
      }
      maxNinePatchCacheEntries = 2;
      expect(resolveNinePatchSync(paths[0]), isNotNull);
      expect(resolveNinePatchSync(paths[1]), isNotNull);
      expect(resolveNinePatchSync(paths[2]), isNotNull);
      expect(ninePatchCacheEntryCount(), 2);
      // 最早条目已被淘汰；再次解析后仍保持上限
      expect(resolveNinePatchSync(paths[0]), isNotNull);
      expect(ninePatchCacheEntryCount(), 2);
    });

    test('文件超上限 → null（不打开解析）', () async {
      final dir = await Directory.systemTemp.createTemp('legado_nine_patch_');
      addTearDown(() async {
        if (await dir.exists()) await dir.delete(recursive: true);
      });
      final file = File('${dir.path}${Platform.pathSeparator}frame.9.png');
      await file.writeAsBytes(File(_fixture0x).readAsBytesSync());
      maxNinePatchFileBytes = 100;
      expect(resolveNinePatchSync(file.path), isNull);
    });

    test('非 `.9.png`/缺失文件 → null（不抛错）', () async {
      final dir = await Directory.systemTemp.createTemp('legado_nine_patch_');
      addTearDown(() async {
        if (await dir.exists()) await dir.delete(recursive: true);
      });
      final normal = File('${dir.path}${Platform.pathSeparator}frame.png');
      await normal.writeAsBytes(File(_fixture0x).readAsBytesSync());
      expect(resolveNinePatchSync(normal.path), isNull);
      expect(
        resolveNinePatchSync('${dir.path}${Platform.pathSeparator}missing.9.png'),
        isNull,
      );
    });
  });
}
