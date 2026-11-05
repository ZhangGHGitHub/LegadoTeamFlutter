// 默认封面文字布局单元测试（设置批6b-1）
//
// 覆盖：竖排逐列（超出 0.8 高度换列）、作者右列起始、横排（配置/拉丁强制）、
// 日夜显隐与颜色、默认色（主题 secondary）、描边/阴影开关、空文本不绘制。
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_legado/src/models/cover_settings.dart';
import 'package:flutter_legado/src/widgets/cover_text_painter.dart';

void main() {
  const size = Size(80, 110);

  CoverTextLayout layoutFor({
    String? name = '凡人修仙传',
    String? author = '忘语',
    CoverSettings settings = CoverSettings.defaults,
    bool isNight = false,
  }) {
    return computeCoverTextLayout(
      size: size,
      name: name,
      author: author,
      settings: settings,
      isNight: isNight,
      defaultColor: 0xFF224466,
    );
  }

  test('竖排逐字：首列 x=0.16w、首字 y=0.16h，超 0.8h 换列', () {
    final layout = layoutFor(name: '一二三四五六七八九十');
    expect(layout.horizontal, isFalse);
    expect(layout.showName, isTrue);
    expect(layout.nameGlyphs.length, 10);
    expect(layout.nameGlyphs.first.text, '一');
    expect(layout.nameGlyphs.first.x, closeTo(80 * 0.16, 0.001));
    expect(layout.nameGlyphs.first.y, closeTo(110 * 0.16, 0.001));
    // 宽度 80 → 字号 10，字高 10.5：第 8 个字（index 7）已换到第二列
    final firstColumnX = layout.nameGlyphs.first.x;
    expect(layout.nameGlyphs[6].x, firstColumnX);
    expect(layout.nameGlyphs[7].x, greaterThan(firstColumnX));
    expect(layout.nameGlyphs[7].y, closeTo(110 * 0.2, 0.001));
  });

  test('竖排作者位于右列（x=0.84w），起始不低于 0.2h', () {
    final layout = layoutFor(name: '凡人修仙传', author: '忘语');
    expect(layout.showAuthor, isTrue);
    expect(layout.authorGlyphs.length, 2);
    expect(layout.authorGlyphs.first.x, closeTo(80 * 0.84, 0.001));
    expect(layout.authorGlyphs.first.y, greaterThanOrEqualTo(110 * 0.2));
    // 逐字向下递增
    expect(layout.authorGlyphs[1].y, greaterThan(layout.authorGlyphs[0].y));
  });

  test('信息方向配置横排：横排文本区间与作者位置', () {
    final layout = layoutFor(
      settings: CoverSettings.defaults.copyWith(
        infoOrientation: CoverSettings.infoOrientationLandscape,
      ),
    );
    expect(layout.horizontal, isTrue);
    expect(layout.horizontalName, '凡人修仙传');
    expect(layout.horizontalAuthor, '忘语');
    expect(layout.nameGlyphs, isEmpty);
    expect(layout.authorGlyphs, isEmpty);
    expect(layout.nameMaxWidth, closeTo(80 * 0.8, 0.001));
    expect(layout.nameX, closeTo(8, 0.001));
    expect(layout.nameY, closeTo(110 * 0.08, 0.001));
    expect(layout.authorY, closeTo(110 * 0.75, 0.001));
  });

  test('拉丁书名强制横排（即使配置竖排）', () {
    final layout = layoutFor(name: 'Harry Potter', author: 'J.K.');
    expect(layout.horizontal, isTrue);
    expect(layout.horizontalName, 'Harry Potter');
  });

  test('默认字体色取主题 secondary；自定义取日/夜独立色', () {
    final day = layoutFor();
    expect(day.textColor, 0xFF224466);
    expect(day.shadowColor, 0xFF000000);

    final custom = CoverSettings.defaults.copyWith(
      useDefaultColor: false,
      textColor: 0xFF010203,
      shadowColor: 0xFF040506,
      textColorDark: 0xFF070809,
      shadowColorDark: 0xFF0A0B0C,
    );
    expect(layoutFor(settings: custom).textColor, 0xFF010203);
    expect(layoutFor(settings: custom).shadowColor, 0xFF040506);
    expect(layoutFor(settings: custom, isNight: true).textColor, 0xFF070809);
    expect(layoutFor(settings: custom, isNight: true).shadowColor, 0xFF0A0B0C);
  });

  test('日夜书名/作者显隐独立；作者随书名', () {
    final nightHidden = CoverSettings.defaults.copyWith(
      showNameDark: false,
      showAuthorDark: true,
    );
    final layout = layoutFor(settings: nightHidden, isNight: true);
    expect(layout.showName, isFalse);
    expect(layout.showAuthor, isFalse);
    expect(layout.hasText, isFalse);

    final day = layoutFor(settings: nightHidden, isNight: false);
    expect(day.showName, isTrue);
    expect(day.showAuthor, isTrue);
  });

  test('书名关闭时不绘制作者（即使作者开关为开）', () {
    final layout = layoutFor(
      settings: CoverSettings.defaults.copyWith(
        showName: false,
        showAuthor: true,
      ),
    );
    expect(layout.showName, isFalse);
    expect(layout.showAuthor, isFalse);
    expect(layout.nameGlyphs, isEmpty);
    expect(layout.authorGlyphs, isEmpty);
    expect(layout.hasText, isFalse);
  });

  test('描边/阴影开关透传到布局', () {
    final on = layoutFor();
    expect(on.showStroke, isTrue);
    expect(on.showShadow, isFalse);
    final off = layoutFor(
      settings: CoverSettings.defaults.copyWith(
        showStroke: false,
        showShadow: true,
      ),
    );
    expect(off.showStroke, isFalse);
    expect(off.showShadow, isTrue);
  });

  test('空文本/零尺寸不产生字形', () {
    final empty = layoutFor(name: '', author: '');
    expect(empty.hasText, isFalse);
    final zero = computeCoverTextLayout(
      size: const Size(0, 0),
      name: '书名',
      author: '作者',
      settings: CoverSettings.defaults,
      isNight: false,
      defaultColor: 0xFF000000,
    );
    expect(zero.nameGlyphs, isEmpty);
    expect(zero.authorGlyphs, isEmpty);
  });
}
