import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

/// 漫画电子纸真像素二值化（对齐 EpaperTransformation）
///
/// 1. 按亮度转灰度：`0.299R + 0.587G + 0.114B`（等同 ColorMatrix 去饱和）
/// 2. `gray < threshold` → 黑，否则白（原版默认阈值 150）
void binarizeRgbaInPlace(Uint8List rgba, int threshold) {
  final thr = threshold.clamp(0, 255);
  for (var i = 0; i + 3 < rgba.length; i += 4) {
    final r = rgba[i];
    final g = rgba[i + 1];
    final b = rgba[i + 2];
    final gray = (0.299 * r + 0.587 * g + 0.114 * b).round();
    final v = gray < thr ? 0 : 255;
    rgba[i] = v;
    rgba[i + 1] = v;
    rgba[i + 2] = v;
  }
}

/// 解码图片字节并二值化为 [ui.Image]
Future<ui.Image> mangaEpaperFromBytes(
  Uint8List bytes, {
  int threshold = 150,
}) async {
  final codec = await ui.instantiateImageCodec(bytes);
  final frame = await codec.getNextFrame();
  final src = frame.image;
  final width = src.width;
  final height = src.height;
  final data = await src.toByteData(format: ui.ImageByteFormat.rawRgba);
  src.dispose();
  if (data == null) throw StateError('无法读取像素');
  final rgba = Uint8List.fromList(data.buffer.asUint8List());
  binarizeRgbaInPlace(rgba, threshold);

  final completer = Completer<ui.Image>();
  ui.decodeImageFromPixels(
    rgba,
    width,
    height,
    ui.PixelFormat.rgba8888,
    completer.complete,
  );
  return completer.future;
}
