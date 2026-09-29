// [P4-3 E2] 分页适配类型（纯逻辑）
//
// 取证（参考版，legado-with-MD3）：
// - ui/book/manga/config/MangaPageConfig.kt L3-10：
//   MangaPageScaleType：FIT_SCREEN=0 / STRETCH=1 / FIT_WIDTH=2 /
//   FIT_HEIGHT=3 / ORIGINAL=4 / SMART_FIT=5；
// - ui/book/manga/MangaReaderContract.kt L121：pageScaleType 默认 0；
// - ui/book/manga/MangaReaderScreen.kt L1463-1472 单页式映射：
//   STRETCH→FillBounds / FIT_WIDTH→FillWidth / FIT_HEIGHT→FillHeight /
//   ORIGINAL→None / SMART_FIT&&isWidePage→FillWidth / 其余→Fit；
// - 同文件 L1568：条漫恒 ContentScale.FillWidth；
// - MangaSettingsPanel.kt L372-386：非条漫模式显示「页面适配」6 选项下拉
//   （strings.xml L3363-3369 文案：Fit screen / Stretch / Fit width /
//   Fit height / Original size / Smart fit）。
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_legado/src/screens/reader_comic/manga_page_scale_type.dart';

void main() {
  group('[P4-3 E2] 解析（Contract L121 默认 0 = 全屏适配）', () {
    test('null / 空串 / 非法值 → 默认 0', () {
      expect(MangaPageScaleType.parse(null), 0);
      expect(MangaPageScaleType.parse(''), 0);
      expect(MangaPageScaleType.parse('   '), 0);
      expect(MangaPageScaleType.parse('abc'), 0);
    });

    test('0..5 原样通过', () {
      for (var v = 0; v <= 5; v++) {
        expect(MangaPageScaleType.parse('$v'), v);
      }
    });

    test('越界 / 负数 → 默认 0（对齐 MangaScrollModes.parse 的 valid 集合语义）',
        () {
      expect(MangaPageScaleType.parse('-1'), 0);
      expect(MangaPageScaleType.parse('6'), 0);
      expect(MangaPageScaleType.parse('99'), 0);
    });
  });

  group('[P4-3 E2] 单页式 BoxFit 映射（Screen L1463-1472）', () {
    test('6 值 → BoxFit', () {
      // Fit ≈ contain / FillBounds ≈ fill / FillWidth ≈ fitWidth /
      // FillHeight ≈ fitHeight / None ≈ none
      expect(MangaPageScaleType.fitFor(type: 0), BoxFit.contain);
      expect(MangaPageScaleType.fitFor(type: 1), BoxFit.fill);
      expect(MangaPageScaleType.fitFor(type: 2), BoxFit.fitWidth);
      expect(MangaPageScaleType.fitFor(type: 3), BoxFit.fitHeight);
      expect(MangaPageScaleType.fitFor(type: 4), BoxFit.none);
      // SMART_FIT：宽页 → fitWidth，非宽页 → contain（Fit）
      expect(
        MangaPageScaleType.fitFor(type: 5, isWidePage: true),
        BoxFit.fitWidth,
      );
      expect(
        MangaPageScaleType.fitFor(type: 5, isWidePage: false),
        BoxFit.contain,
      );
    });
  });

  test('[P4-3 E2] 条漫恒 fitWidth（Screen L1568）', () {
    expect(MangaPageScaleType.webtoonFit, BoxFit.fitWidth);
  });

  test('[P4-3 E2] 下拉选项与文案（Panel L376-382 顺序；中文化案）', () {
    expect(MangaPageScaleType.options, [0, 1, 2, 3, 4, 5]);
    expect(MangaPageScaleType.labelOf(0), '全屏适配');
    expect(MangaPageScaleType.labelOf(1), '拉伸');
    expect(MangaPageScaleType.labelOf(2), '适配宽度');
    expect(MangaPageScaleType.labelOf(3), '适配高度');
    expect(MangaPageScaleType.labelOf(4), '原始大小');
    expect(MangaPageScaleType.labelOf(5), '智能适配');
  });

  test(
      '[P4-3 E2] 宽页/双页常量登记（MangaPageConfig L19-30；仅登记不实现行为）',
      () {
    expect(MangaWidePageMode.normal, 0);
    expect(MangaWidePageMode.fitWidth, 1);
    expect(MangaWidePageMode.rotateToFit, 2);
    expect(MangaWidePageMode.split, 3);
    expect(MangaDoublePageMode.off, 0);
    expect(MangaDoublePageMode.landscape, 1);
    expect(MangaDoublePageMode.always, 2);
  });
}
