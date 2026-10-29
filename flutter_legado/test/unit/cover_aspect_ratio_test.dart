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

    test('LRU 上限：超出 maxEntries 淘汰最久未使用', () {
      // 写满上限 + 10 条：前 10 条应被淘汰
      for (var i = 0; i < CoverAspectRatio.maxEntries + 10; i++) {
        CoverAspectRatio.remember('http://a/$i.jpg', 0.5);
      }
      expect(CoverAspectRatio.cached('http://a/0.jpg'), isNull);
      expect(CoverAspectRatio.cached('http://a/9.jpg'), isNull);
      expect(CoverAspectRatio.cached('http://a/10.jpg'), isNotNull);
      // 最近写入的仍在
      expect(
        CoverAspectRatio.cached(
          'http://a/${CoverAspectRatio.maxEntries + 9}.jpg',
        ),
        isNotNull,
      );
    });

    test('LRU 命中刷新位置：最近读取过的条目不被优先淘汰', () {
      // 写满上限，然后把最早写入的条目重新读一次（刷新 LRU 位置）
      for (var i = 0; i < CoverAspectRatio.maxEntries; i++) {
        CoverAspectRatio.remember('http://a/$i.jpg', 0.5);
      }
      expect(CoverAspectRatio.cached('http://a/0.jpg'), isNotNull);
      // 再写 1 条：淘汰的是次久未用（1.jpg），而不是刚读过的 0.jpg
      CoverAspectRatio.remember('http://a/new.jpg', 0.5);
      expect(CoverAspectRatio.cached('http://a/0.jpg'), isNotNull);
      expect(CoverAspectRatio.cached('http://a/1.jpg'), isNull);
    });
  });

  group('rememberDetailed 与修订号门控（批39 审查回修）', () {
    test('首个已知比例标记 firstKnown，后续写入为 false', () {
      final first = CoverAspectRatio.rememberDetailed('http://a/1.jpg', 0.5);
      expect(first.changed, isTrue);
      expect(first.firstKnown, isTrue);

      final second = CoverAspectRatio.rememberDetailed('http://a/2.jpg', 0.6);
      expect(second.changed, isTrue);
      expect(second.firstKnown, isFalse);
    });

    test('同值重复上报不改变（changed/firstKnown 均 false）', () {
      CoverAspectRatio.remember('http://a/1.jpg', 0.5);
      final again = CoverAspectRatio.rememberDetailed('http://a/1.jpg', 0.5);
      expect(again.changed, isFalse);
      expect(again.firstKnown, isFalse);
    });

    test('shouldNotifyCoverRatioRevision：restrict=true 仅首个比例通知', () {
      // 限制比例开启（默认）：网格行高固定，普通新比例不通知（避免整屏重建）
      expect(
        shouldNotifyCoverRatioRevision(
          changed: true,
          restrict: true,
          firstKnown: false,
        ),
        isFalse,
      );
      // 但首个已知比例会改变「代表比例」回退值 → 通知一次
      expect(
        shouldNotifyCoverRatioRevision(
          changed: true,
          restrict: true,
          firstKnown: true,
        ),
        isTrue,
      );
      // 关闭限制比例：布局随比例变化，任何新值都通知
      expect(
        shouldNotifyCoverRatioRevision(
          changed: true,
          restrict: false,
          firstKnown: false,
        ),
        isTrue,
      );
      // 无变化不通知
      expect(
        shouldNotifyCoverRatioRevision(
          changed: false,
          restrict: false,
          firstKnown: true,
        ),
        isFalse,
      );
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
