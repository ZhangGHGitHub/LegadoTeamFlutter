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

  // [红线清理 2.0.260 | 台账 1-3] 书架网格固定 2 列（对齐参考 03b），
  // 原按宽度分档列数/宽高比函数与对应用例已移除

  group('Responsive 网格宽高比', () {
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
