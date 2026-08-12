import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_legado/src/utils/manga_epaper.dart';

void main() {
  test('binarizeRgbaInPlace 阈值分割', () {
    // 深灰 + 浅灰各一像素（RGBA）
    final rgba = Uint8List.fromList([
      40, 40, 40, 255,
      200, 200, 200, 255,
    ]);
    binarizeRgbaInPlace(rgba, 150);
    expect(rgba[0], 0);
    expect(rgba[1], 0);
    expect(rgba[2], 0);
    expect(rgba[3], 255);
    expect(rgba[4], 255);
    expect(rgba[5], 255);
    expect(rgba[6], 255);
    expect(rgba[7], 255);
  });
}
