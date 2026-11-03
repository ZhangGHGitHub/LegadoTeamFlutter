// [设置批2b-1b-2b | 2026-11-03] `.9.png` 九宫格解析单测 — 全栈工程师 + UI
//
// 覆盖任务书测试项：synthetic PNG 含 npTc 的解析/切片、npLb 布局边界、
// 无 npTc 回落、损坏 chunk（CRC/长度/坐标/多区域/截断）回落、路径后缀
// 判定、路径+mtime+长度缓存失效。
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'package:flutter_legado/src/widgets/nine_patch.dart';

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

/// 9x9 实色 PNG（真实可解码；供切片坐标使用）
Uint8List _basePng({int size = 9}) {
  final image = img.Image(width: size, height: size);
  img.fill(image, color: img.ColorRgb8(200, 30, 30));
  return Uint8List.fromList(img.encodePng(image));
}

/// npTc 数据：header + 小端 int32 divs/colors
List<int> _npTcData({
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

List<int> _npLbData(int left, int top, int right, int bottom) {
  final bytes = Uint8List(16);
  final view = ByteData.sublistView(bytes);
  view.setInt32(0, left, Endian.little);
  view.setInt32(4, top, Endian.little);
  view.setInt32(8, right, Endian.little);
  view.setInt32(12, bottom, Endian.little);
  return bytes;
}

Uint8List _ninePatchPng({
  List<int>? xDivs,
  List<int>? yDivs,
  List<int>? npLb,
  int? crcOverride,
  int? numXOverride,
  int? numYOverride,
}) {
  final x = xDivs ?? const <int>[2, 7];
  final y = yDivs ?? const <int>[2, 7];
  final data = _npTcData(
    numX: numXOverride ?? x.length,
    numY: numYOverride ?? y.length,
    xDivs: x,
    yDivs: y,
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

  setUp(resetNinePatchCache);
  tearDown(resetNinePatchCache);

  group('npTc 解析', () {
    test('单拉伸区域 → centerSlice 与图像尺寸', () {
      final info = parseNinePatchPng(_ninePatchPng());
      expect(info, isNotNull);
      expect(info!.centerSlice, const Rect.fromLTRB(2, 2, 7, 7));
      expect(info.width, 9);
      expect(info.height, 9);
      expect(info.layoutBounds, isNull);
    });

    test('可选 npLb → 布局边界（不影响 centerSlice）', () {
      final info = parseNinePatchPng(
        _ninePatchPng(npLb: _npLbData(1, 2, 3, 4)),
      );
      expect(info, isNotNull);
      expect(info!.centerSlice, const Rect.fromLTRB(2, 2, 7, 7));
      expect(info.layoutBounds, const Rect.fromLTRB(1, 2, 3, 4));
    });

    test('x1/y1 可等于图像宽高（右下无固定边）', () {
      final info = parseNinePatchPng(
        _ninePatchPng(xDivs: const <int>[0, 9], yDivs: const <int>[0, 9]),
      );
      expect(info, isNotNull);
      expect(info!.centerSlice, const Rect.fromLTRB(0, 0, 9, 9));
    });
  });

  group('回落（返回 null → 普通图）', () {
    test('无 npTc 块', () {
      expect(parseNinePatchPng(_basePng()), isNull);
    });

    test('非 PNG 字节', () {
      expect(
        parseNinePatchPng(Uint8List.fromList(<int>[1, 2, 3, 4, 5, 6, 7, 8])),
        isNull,
      );
    });

    test('npTc CRC 损坏', () {
      expect(parseNinePatchPng(_ninePatchPng(crcOverride: 0xDEADBEEF)), isNull);
    });

    test('npTc 声明 div 数与数据长度不符', () {
      expect(
        parseNinePatchPng(_ninePatchPng(numXOverride: 4, numYOverride: 2)),
        isNull,
      );
    });

    test('多拉伸区域（4 个 div）→ Flutter centerSlice 无法表达，回落', () {
      expect(
        parseNinePatchPng(
          _ninePatchPng(
            xDivs: const <int>[1, 3, 5, 7],
            yDivs: const <int>[1, 3, 5, 7],
          ),
        ),
        isNull,
      );
    });

    test('坐标越界/逆序', () {
      expect(
        parseNinePatchPng(_ninePatchPng(xDivs: const <int>[2, 20])),
        isNull,
      );
      expect(
        parseNinePatchPng(_ninePatchPng(yDivs: const <int>[6, 3])),
        isNull,
      );
      expect(
        parseNinePatchPng(_ninePatchPng(xDivs: const <int>[-1, 7])),
        isNull,
      );
    });

    test('未反序列化标记不为 1', () {
      final data = _npTcData(
        numX: 2,
        numY: 2,
        xDivs: const [2, 7],
        yDivs: const [2, 7],
      );
      data[0] = 0;
      final png = _insertAfterIhdr(_basePng(), 'npTc', data);
      expect(parseNinePatchPng(png), isNull);
    });

    test('npTc 块被截断（块长超出文件）', () {
      final png = _ninePatchPng();
      final ihdrLength = ByteData.sublistView(
        png,
        8,
        12,
      ).getUint32(0, Endian.big);
      final npTcStart = 8 + 12 + ihdrLength;
      // 只保留 npTc 头 + 4 字节数据，其余数据与 CRC 缺失
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

    test('文件解析 + 路径/mtime/长度缓存失效', () async {
      final dir = await Directory.systemTemp.createTemp('legado_nine_patch_');
      addTearDown(() async {
        if (await dir.exists()) await dir.delete(recursive: true);
      });
      final file = File('${dir.path}${Platform.pathSeparator}frame.9.png');
      await file.writeAsBytes(_ninePatchPng());

      final first = resolveNinePatchSync(file.path);
      expect(first, isNotNull);
      expect(first!.centerSlice, const Rect.fromLTRB(2, 2, 7, 7));
      expect(
        identical(resolveNinePatchSync(file.path), first),
        isTrue,
        reason: 'mtime/长度未变 → 命中缓存',
      );

      // 覆盖为普通 PNG（长度不同 → 缓存失效，解析为 null）
      await file.writeAsBytes(_basePng(size: 4));
      expect(resolveNinePatchSync(file.path), isNull);

      // 恢复九宫格 → 重新解析成功
      await file.writeAsBytes(_ninePatchPng());
      expect(resolveNinePatchSync(file.path), isNotNull);
    });

    test('非 `.9.png`/缺失文件 → null（不抛错）', () async {
      final dir = await Directory.systemTemp.createTemp('legado_nine_patch_');
      addTearDown(() async {
        if (await dir.exists()) await dir.delete(recursive: true);
      });
      final normal = File('${dir.path}${Platform.pathSeparator}frame.png');
      await normal.writeAsBytes(_ninePatchPng());
      expect(resolveNinePatchSync(normal.path), isNull);
      expect(
        resolveNinePatchSync(
          '${dir.path}${Platform.pathSeparator}missing.9.png',
        ),
        isNull,
      );
    });
  });
}
