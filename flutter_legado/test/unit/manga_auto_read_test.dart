// [P4-3 E3] 自动翻页/自动滚动纯逻辑测试
//
// 取证（参考版，legado-with-MD3）：
// - ui/book/manga/MangaReaderContract.kt L44 autoReadEnabled 默认 false
//   （会话态，不落设置）；L136 autoReadSpeed 默认 3；
// - ui/book/manga/MangaSettingsPanel.kt L755-767 AutoReadSettingsContent：
//   开关（ToggleAutoRead）+ 速度滑杆 1..15（AUTO_READ_SPEED）；
// - ui/book/manga/MangaReaderScreen.kt L200-216 单页式自动翻页：
//   delay(autoReadSpeed.coerceAtLeast(1) * 1_000L) → PageStep(1)；
// - L677-699 条漫自动滚动：每周期 scrollBy(10_000px,
//   tween(ceil(16f/speed*10_000f)ms, Linear))，consumed < 1 → NextChapter；
// 原版 ScrollTimer（ReadMangaActivity L570-591）同语义：
// paged 版 delay(distance*1000L) → scrollPage，条漫 scrollBy。
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_legado/src/screens/reader_comic/manga_auto_read.dart';

void main() {
  group('[P4-3 E3] MangaAutoRead 纯逻辑', () {
    test('默认速度档 3（Contract L136）', () {
      expect(MangaAutoRead.defaultValue, 3);
    });

    test('速度档范围 1..15（设置面板滑杆，MangaSettingsPanel L765-771）', () {
      expect(MangaAutoRead.minSpeed, 1);
      expect(MangaAutoRead.maxSpeed, 15);
    });

    test('parse：空/非法 → 默认 3；0 → 下限 1；越限 → 15', () {
      expect(MangaAutoRead.parse(null), 3);
      expect(MangaAutoRead.parse(''), 3);
      expect(MangaAutoRead.parse('abc'), 3);
      expect(MangaAutoRead.parse('0'), 1);
      expect(MangaAutoRead.parse('7'), 7);
      expect(MangaAutoRead.parse('99'), 15);
    });

    test('单页式间隔 = 速度×1000ms（参考 L215；速度 0 收敛到 1）', () {
      expect(MangaAutoRead.pageStepDelay(1), const Duration(seconds: 1));
      expect(MangaAutoRead.pageStepDelay(3), const Duration(seconds: 3));
      expect(MangaAutoRead.pageStepDelay(15), const Duration(seconds: 15));
      expect(MangaAutoRead.pageStepDelay(0), const Duration(seconds: 1));
    });

    test('条漫单周期时长 = ceil(16/速度×10000)ms（参考 L686）', () {
      // 参考版公式：ceil(16f/distance*10_000f)ms —— 速度 1 = 每 10000px 耗时
      // 160s（自动滚动为慢速免手模式，速度 15 才到 10.667s）
      expect(MangaAutoRead.webtoonCycle(1),
          const Duration(milliseconds: 160000));
      expect(MangaAutoRead.webtoonCycle(2),
          const Duration(milliseconds: 80000));
      expect(MangaAutoRead.webtoonCycle(3),
          const Duration(milliseconds: 53334));
      // 速度 0 收敛到 1（coerceAtLeast(1)）
      expect(MangaAutoRead.webtoonCycle(0),
          const Duration(milliseconds: 160000));
      // 速度 15（最快档）= ceil(16/15×10000) = 10667ms
      expect(MangaAutoRead.webtoonCycle(15),
          const Duration(milliseconds: 10667));
    });

    test('条漫单周期滚动像素 10000（参考 L688 value = 10_000f）', () {
      expect(MangaAutoRead.webtoonScrollPx, 10000);
    });
  });
}
