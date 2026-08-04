import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_legado/src/utils/responsive.dart';

void main() {
  group('Responsive 窗口尺寸类判断（断点边界）', () {
    test('compact：<600', () {
      expect(Responsive.isCompact(0), isTrue);
      expect(Responsive.isCompact(399), isTrue);
      expect(Responsive.isCompact(599), isTrue);
      expect(Responsive.isCompact(600), isFalse);
    });

    test('medium：[600, 840)', () {
      expect(Responsive.isMedium(599), isFalse);
      expect(Responsive.isMedium(600), isTrue);
      expect(Responsive.isMedium(839), isTrue);
      expect(Responsive.isMedium(840), isFalse);
    });

    test('expanded：[840, 1200)', () {
      expect(Responsive.isExpanded(839), isFalse);
      expect(Responsive.isExpanded(840), isTrue);
      expect(Responsive.isExpanded(1199), isTrue);
      expect(Responsive.isExpanded(1200), isFalse);
    });

    test('large：>=1200', () {
      expect(Responsive.isLarge(1199), isFalse);
      expect(Responsive.isLarge(1200), isTrue);
      expect(Responsive.isLarge(1920), isTrue);
    });

    test('四断点在任意宽度下恰好命中一类', () {
      for (final w in <double>[0.0, 320, 400, 599.9, 600, 840, 1024, 1200, 2560]) {
        final hits = [
          Responsive.isCompact(w),
          Responsive.isMedium(w),
          Responsive.isExpanded(w),
          Responsive.isLarge(w),
        ].where((e) => e).length;
        expect(hits, equals(1), reason: '宽度 $w 应恰好命中一类');
      }
    });
  });

  group('Responsive 网格列数（多尺寸验证）', () {
    test('<600dp → 3 列（对齐原版 bookshelfLayout 默认列数）', () {
      expect(Responsive.gridColumnsForWidth(320), equals(3));
      expect(Responsive.gridColumnsForWidth(399), equals(3));
      expect(Responsive.gridColumnsForWidth(400), equals(3));
      expect(Responsive.gridColumnsForWidth(599), equals(3));
    });

    test('[600, 1200)dp → 4 列', () {
      expect(Responsive.gridColumnsForWidth(600), equals(4));
      expect(Responsive.gridColumnsForWidth(840), equals(4));
      expect(Responsive.gridColumnsForWidth(1199), equals(4));
    });

    test('>=1200dp → 6 列', () {
      expect(Responsive.gridColumnsForWidth(1200), equals(6));
      expect(Responsive.gridColumnsForWidth(1920), equals(6));
    });
  });

  group('Responsive 网格宽高比', () {
    test('书架：手机竖卡 0.65 / 平板桌面横卡 0.75', () {
      expect(Responsive.bookGridChildAspectRatio(360), equals(0.65));
      expect(Responsive.bookGridChildAspectRatio(599), equals(0.65));
      expect(Responsive.bookGridChildAspectRatio(600), equals(0.75));
      expect(Responsive.bookGridChildAspectRatio(1200), equals(0.75));
    });

    test('RSS：手机竖卡 0.62 / 平板桌面 0.75', () {
      expect(Responsive.rssGridChildAspectRatio(360), equals(0.62));
      expect(Responsive.rssGridChildAspectRatio(600), equals(0.75));
    });
  });

  group('Responsive 导航与内容宽度', () {
    test('medium 及以上使用 NavigationRail', () {
      expect(Responsive.useNavigationRail(599), isFalse);
      expect(Responsive.useNavigationRail(600), isTrue);
      expect(Responsive.useNavigationRail(1200), isTrue);
    });

    test('large 窗口内容限宽 1080，其余不限', () {
      expect(Responsive.contentMaxWidth(1199), isNull);
      expect(Responsive.contentMaxWidth(1200), equals(1080.0));
      expect(Responsive.contentMaxWidth(2560), equals(1080.0));
    });
  });
}
