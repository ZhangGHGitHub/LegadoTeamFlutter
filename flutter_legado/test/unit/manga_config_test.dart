import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_legado/src/models/manga_config.dart';

void main() {
  group('MangaColorFilterConfig', () {
    test('identity storage 为空串', () {
      expect(MangaColorFilterConfig().toStorage(), '');
    });

    test('矩阵对齐原版 (255-v)/255', () {
      final cfg = MangaColorFilterConfig(r: 51, g: 0, b: 255, a: 0);
      final m = cfg.toColorMatrix();
      expect(m[0], closeTo((255 - 51) / 255.0, 1e-9));
      expect(m[6], closeTo(1.0, 1e-9));
      expect(m[12], closeTo(0.0, 1e-9));
      expect(m[18], closeTo(1.0, 1e-9));
    });

    test('fromStorage 往返', () {
      final raw = MangaColorFilterConfig(r: 10, g: 20, b: 30, a: 40, l: 50)
          .toStorage();
      final back = MangaColorFilterConfig.fromStorage(raw);
      expect(back.r, 10);
      expect(back.g, 20);
      expect(back.b, 30);
      expect(back.a, 40);
      expect(back.l, 50);
    });
  });

  group('MangaFooterConfig', () {
    test('buildLabel 尊重隐藏开关', () {
      final cfg = MangaFooterConfig(
        hideChapterName: true,
        hidePageNumberLabel: true,
        hideChapterLabel: true,
        hideProgressRatioLabel: true,
      );
      final label = cfg.buildLabel(
        chapterName: '第1话',
        chapterIndex: 0,
        chapterSize: 10,
        pageIndex: 1,
        imageCount: 5,
      );
      expect(label.contains('第1话'), isFalse);
      expect(label.contains('2/5'), isTrue);
      expect(label.contains('1/10'), isTrue);
      expect(label.contains('%'), isTrue);
    });

    test('hideFooter 返回空', () {
      final cfg = MangaFooterConfig(hideFooter: true);
      expect(
        cfg.buildLabel(
          chapterName: 'x',
          chapterIndex: 0,
          chapterSize: 1,
          pageIndex: 0,
          imageCount: 1,
        ),
        '',
      );
    });
  });
}
