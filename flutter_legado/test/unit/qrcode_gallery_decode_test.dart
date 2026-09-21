// [PARITY A1] 图库二维码本地解码管线回环测试。
//
// 复刻 qrcode_screen.dart 顶层 [_decodeQrInIsolate] 的解码管线
// （image 自动识别格式 → 4 通道 RGBA → zxing2 RGBLuminanceSource +
// HybridBinarizer 二值化 → QRCodeReader），验证两个新依赖
// （zxing2 ^0.2.4 / image ^4.8.0）在纯 Dart（无平台通道）下可用：
//
// - 编码侧用 zxing2 [Encoder] 生成 QR 矩阵，放大 + 静区渲染为 PNG；
// - 解码侧走与生产完全一致的调用序列（decodeImage → convert(4) →
//   getBytes(rgba) → RGBLuminanceSource → HybridBinarizer →
//   BinaryBitmap → QRCodeReader），覆盖 QrcodeScreen「从图库导入」
//   按钮的本地解码链路（参考 QrCodeActivity 的 BitmapFactory +
//   QRCodeUtils.parseCodeResult 语义）。
//
// 注：[_decodeQrInIsolate] 为库内私有函数，本测试以同一管线镜像其
// 逻辑；若其内部调用序列变更，需同步更新本文件。
//
// 镜像亦包含 [_recoverUtf8Text]：zxing2 0.2.4 的 DecodedBitStreamParser
// 把字节段读入带符号 Int8List 后交给 ECI 字符集 codec，UTF-8 内容的高
// 字节（≥0x80）为负值被 Utf8Codec(allowMalformed) 逐字节替换为 U+FFFD
// （CJK 乱码根因）。生产侧在结果含 U+FFFD 时经
// ResultMetadataType.byteSegments 取回原始字节段、按无符号重建后以
// UTF-8 重解（重解仍含 U+FFFD 则回退原文）。
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:zxing2/qrcode.dart'
    show EncodeHintType, EncodeHints, Encoder, ErrorCorrectionLevel,
        QRCodeReader;
import 'package:zxing2/zxing2.dart'
    show BinaryBitmap, CharacterSetECI, HybridBinarizer, Result,
        ResultMetadataType, RGBLuminanceSource;

/// 与 qrcode_screen.dart [_decodeQrInIsolate] 相同的解码管线（含同款
/// 全函数兜底 catch：decodeImage 探测在畸形字节流上可能抛 Error；及
/// 同款 zxing2 0.2.4 符号字节缺陷规避 [_recoverUtf8Text]）。
String? _decodePipeline(Uint8List bytes) {
  try {
    final image = img.decodeImage(bytes);
    if (image == null) return null;
    final rgba = image.convert(numChannels: 4);
    final pixels =
        rgba.getBytes(order: img.ChannelOrder.rgba).buffer.asInt32List();
    final source = RGBLuminanceSource(rgba.width, rgba.height, pixels);
    final bitmap = BinaryBitmap(HybridBinarizer(source));
    return _recoverUtf8Text(QRCodeReader().decode(bitmap));
  } catch (_) {
    // 探测/二值化/zxing2 异常：按未识别处理
    return null;
  }
}

/// 与 qrcode_screen.dart [_recoverUtf8Text] 一致（zxing2 0.2.4 带符号
/// 字节缺陷规避，依据见该生产函数注释与文件头）。
String _recoverUtf8Text(Result result) {
  final text = result.text;
  if (!text.contains('\uFFFD')) return text;
  final segments =
      result.resultMetadata[ResultMetadataType.byteSegments]
          as List<Int8List>?;
  if (segments == null || segments.isEmpty) return text;
  const utf8 = Utf8Codec(allowMalformed: true);
  final rebuilt = segments
      .map((segment) {
        final unsigned = Uint8List(segment.length);
        for (var i = 0; i < segment.length; i++) {
          unsigned[i] = segment[i] & 0xFF;
        }
        return utf8.decode(unsigned);
      })
      .join();
  return rebuilt.contains('\uFFFD') ? text : rebuilt;
}

/// 用 zxing2 [Encoder] 把 [content] 编码为 QR 并渲染成 PNG 字节流
/// （8 倍放大 + 4 模块静区，提升 HybridBinarizer 检测稳定性）。
///
/// 注：Encoder 默认 byte 模式字符集为 ISO8859_1（非 UTF-8），非 Latin-1
/// 内容（如中文口令）需显式指定 UTF-8 编码提示。
Uint8List _renderQrPng(String content) {
  final hints =
      EncodeHints()..put(EncodeHintType.characterSet, CharacterSetECI.UTF8);
  final qr = Encoder.encode(content, ErrorCorrectionLevel.m, hints: hints);
  final matrix = qr.matrix;
  expect(matrix, isNotNull, reason: 'Encoder 应产出矩阵');
  const quiet = 4;
  const scale = 8;
  final size = (matrix!.width + quiet * 2) * scale;
  final image = img.Image(width: size, height: size, numChannels: 4);
  // 白底（静区 + 模块间隙）
  img.fillRect(
    image,
    x1: 0,
    y1: 0,
    x2: size,
    y2: size,
    color: img.ColorUint8.rgba(255, 255, 255, 255),
  );
  // 暗模块（ByteMatrix.get 返回 1 = 暗）
  for (var y = 0; y < matrix.height; y++) {
    for (var x = 0; x < matrix.width; x++) {
      if (matrix.get(x, y) != 1) continue;
      final px = (x + quiet) * scale;
      final py = (y + quiet) * scale;
      img.fillRect(
        image,
        x1: px,
        y1: py,
        x2: px + scale,
        y2: py + scale,
        color: img.ColorUint8.rgba(0, 0, 0, 255),
      );
    }
  }
  return img.encodePng(image);
}

void main() {
  group('[PARITY A1] 图库本地解码管线（zxing2 + image）', () {
    test('回环：编码 URL → PNG → 与生产相同管线解码得原文', () {
      const content = 'https://legado.example.com/book-source.json';
      final png = _renderQrPng(content);
      expect(_decodePipeline(png), content);
    });

    // 回归测试：zxing2 0.2.4 带符号字节段缺陷（DecodedBitStreamParser 将
    // 字节段读入 Int8List，UTF-8 高字节为负被逐字节替换为 U+FFFD）。未加
    // [_recoverUtf8Text] 时本用例会得到一串 U+FFFD。
    test('回环：中文口令内容（非 URL 文本，回归 CJK 乱码缺陷）', () {
      const content = 'legado://import?data=测试口令';
      final png = _renderQrPng(content);
      expect(_decodePipeline(png), content);
    });

    test('非二维码图片：解码返回 null（不抛异常）', () {
      final image = img.Image(width: 64, height: 64, numChannels: 4);
      img.fillRect(
        image,
        x1: 0,
        y1: 0,
        x2: 64,
        y2: 64,
        color: img.ColorUint8.rgba(200, 30, 30, 255),
      );
      expect(_decodePipeline(img.encodePng(image)), isNull);
    });

    test('非图片字节流：解码返回 null（不抛异常）', () {
      expect(
        _decodePipeline(Uint8List.fromList([0x01, 0x02, 0x03, 0x04])),
        isNull,
      );
    });
  });
}
