// 封面比例缓存与换算单元测试（批39）
//
// 覆盖：固定 5:7 默认、比例记录/忽略非法值、上下限收敛、网格代表比例、
// 固定宽度换算高度并夹在上下限。
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_legado/src/services/cover_aspect_ratio.dart';

void main() {
  setUp(CoverAspectRatio.clear);

  group('CoverAspectRatio 缓存', () {
    test('未知封面回退固定 5:7', () {
      expect(CoverAspectRatio.ratioFor('http://a/1.jpg'),
          closeTo(5 / 7, 1e-9));
      expect(CoverAspectRatio.cached('http://a/1.jpg'), isNull);
    });

    test('记录合法比例并返回「是否新值」', () {
      expect(CoverAspectRatio.remember('http://a/1.jpg', 0.5), isTrue);
      expect(CoverAspectRatio.cached('http://a/1.jpg'), closeTo(0.5, 1e-9));
      expect(CoverAspectRatio.ratioFor('http://a/1.jpg'), closeTo(0.5, 1e-9));
      // 同值重复上报不触发修订（避免网格无意义重算）
      expect(CoverAspectRatio.remember('http://a/1.jpg', 0.5), isFalse);
      expect(CoverAspectRatio.remember('http://a/1.jpg', 0.6), isTrue);
    });

    test('非法比例与空 URL 不记录', () {
      expect(CoverAspectRatio.remember(null, 0.5), isFalse);
      expect(CoverAspectRatio.remember('', 0.5), isFalse);
      expect(CoverAspectRatio.remember('http://a/1.jpg', null), isFalse);
      expect(CoverAspectRatio.remember('http://a/1.jpg', 0), isFalse);
      expect(CoverAspectRatio.remember('http://a/1.jpg', -1), isFalse);
      expect(CoverAspectRatio.remember('http://a/1.jpg', double.nan), isFalse);
      expect(CoverAspectRatio.remember('http://a/1.jpg', double.infinity),
          isFalse);
      expect(CoverAspectRatio.cached('http://a/1.jpg'), isNull);
    });

    test('极端比例收敛到上下限', () {
      CoverAspectRatio.remember('http://a/narrow.jpg', 0.1);
      CoverAspectRatio.remember('http://a/wide.jpg', 3.0);
      expect(CoverAspectRatio.cached('http://a/narrow.jpg'),
          closeTo(CoverAspectRatio.minRatio, 1e-9));
      expect(CoverAspectRatio.cached('http://a/wide.jpg'),
          closeTo(CoverAspectRatio.maxRatio, 1e-9));
    });

    test('网格代表比例取首个已知值，全部未知回退 5:7', () {
      expect(
        CoverAspectRatio.representativeRatio(
          const ['http://a/unknown.jpg', 'http://a/2.jpg'],
        ),
        closeTo(5 / 7, 1e-9),
      );
      CoverAspectRatio.remember('http://a/2.jpg', 0.6);
      CoverAspectRatio.remember('http://a/3.jpg', 0.9);
      expect(
        CoverAspectRatio.representativeRatio(
          const ['http://a/unknown.jpg', 'http://a/2.jpg', 'http://a/3.jpg'],
        ),
        closeTo(0.6, 1e-9),
      );
    });

    test('clear 清空缓存（测试隔离）', () {
      CoverAspectRatio.remember('http://a/1.jpg', 0.5);
      CoverAspectRatio.clear();
      expect(CoverAspectRatio.cached('http://a/1.jpg'), isNull);
    });
  });

  group('CoverAspectRatio.heightFor', () {
    test('按原图比例换算高度', () {
      // 宽 74、比例 0.5 → 高 148（在 74..160 内）
      expect(
        CoverAspectRatio.heightFor(
          width: 74,
          ratio: 0.5,
          minHeight: 74,
          maxHeight: 160,
        ),
        closeTo(148, 1e-6),
      );
    });

    test('超过上下限时收敛（保持布局稳定）', () {
      // 极窄图：0.2 → 收敛 0.4 → 185 → 上限 160
      expect(
        CoverAspectRatio.heightFor(
          width: 74,
          ratio: 0.2,
          minHeight: 74,
          maxHeight: 160,
        ),
        closeTo(160, 1e-6),
      );
      // 横版图：2.0 → 收敛 1.5 → 49.3 → 下限 74
      expect(
        CoverAspectRatio.heightFor(
          width: 74,
          ratio: 2.0,
          minHeight: 74,
          maxHeight: 160,
        ),
        closeTo(74, 1e-6),
      );
    });

    test('非法比例回退固定 5:7', () {
      expect(
        CoverAspectRatio.heightFor(
          width: 70,
          ratio: 0,
          minHeight: 1,
          maxHeight: 1000,
        ),
        closeTo(98, 1e-6),
      );
    });
  });
}
