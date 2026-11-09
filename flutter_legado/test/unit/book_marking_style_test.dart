/// 书签标记锚点/样式/效果模型测试（契约 §2.52，批7b-2a）
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_legado/src/models/models.dart';

void main() {
  group('BookMarkingAnchor', () {
    test('toJson/fromJson 往返保真（camelCase）', () {
      const anchor = BookMarkingAnchor(
        chapterIndex: 3,
        chapterPosition: 128,
        selectedText: '归一化文本',
        contextBefore: '前文',
        contextAfter: '后文',
        normalizedTextHash: 'abc123',
      );
      final decoded = BookMarkingAnchor.fromJson(anchor.toJson());
      expect(decoded.chapterIndex, 3);
      expect(decoded.chapterPosition, 128);
      expect(decoded.selectedText, '归一化文本');
      expect(decoded.contextBefore, '前文');
      expect(decoded.contextAfter, '后文');
      expect(decoded.normalizedTextHash, 'abc123');
      expect(jsonDecode(anchor.encode())['chapterPosition'], 128);
    });

    test('chapterPosition 可空；缺键按默认值', () {
      final anchor = BookMarkingAnchor.fromJson(const {});
      expect(anchor.chapterIndex, 0);
      expect(anchor.chapterPosition, isNull);
      expect(anchor.selectedText, '');
      expect(anchor.normalizedTextHash, '');
    });

    test('tryParse：空/非法 JSON/非对象 → null', () {
      expect(BookMarkingAnchor.tryParse(null), isNull);
      expect(BookMarkingAnchor.tryParse('  '), isNull);
      expect(BookMarkingAnchor.tryParse('not json'), isNull);
      expect(BookMarkingAnchor.tryParse('[1,2]'), isNull);
      expect(BookMarkingAnchor.tryParse('{"chapterIndex":2}'), isNotNull);
    });
  });

  group('BookMarkingStyle', () {
    test('toJson/fromJson 往返保真（含宽度/偏移/SVG）', () {
      const style = BookMarkingStyle(
        textColor: 0xFFFF0000,
        bgColor: 0x33FF00FF,
        underlineMode: 7,
        underlineColor: 0xFF00FF00,
        underlineWidth: 2.5,
        underlineOffset: 3,
        underlineSvgPath: 'M0 0',
      );
      final back = BookMarkingStyle.fromJson(style.toJson());
      expect(back.textColor, 0xFFFF0000);
      expect(back.bgColor, 0x33FF00FF);
      expect(back.underlineMode, 7);
      expect(back.underlineColor, 0xFF00FF00);
      expect(back.underlineWidth, 2.5);
      expect(back.underlineOffset, 3);
      expect(back.underlineSvgPath, 'M0 0');
    });

    test('缺键默认：mode=0 / width=1 / offset=2 / 颜色 null', () {
      final style = BookMarkingStyle.fromJson(const {});
      expect(style.textColor, isNull);
      expect(style.bgColor, isNull);
      expect(style.underlineMode, 0);
      expect(style.underlineColor, isNull);
      expect(style.underlineWidth, 1);
      expect(style.underlineOffset, 2);
      expect(style.underlineSvgPath, isNull);
    });

    test('tryParse 非法输入 → null', () {
      expect(BookMarkingStyle.tryParse(null), isNull);
      expect(BookMarkingStyle.tryParse('{'), isNull);
      expect(BookMarkingStyle.tryParse('[]'), isNull);
    });
  });

  group('MarkingEffect', () {
    const color = 0xFF123456;

    test('7 效果 toStyle 映射（含 BG 20% alpha）', () {
      expect(MarkingEffect.solid.toStyle(color).underlineMode, 1);
      expect(MarkingEffect.wave.toStyle(color).underlineMode, 3);
      expect(MarkingEffect.dashed.toStyle(color).underlineMode, 2);
      expect(MarkingEffect.strike.toStyle(color).underlineMode, 6);
      expect(MarkingEffect.highlight.toStyle(color).underlineMode, 7);
      expect(MarkingEffect.solid.toStyle(color).underlineColor, color);

      final bg = MarkingEffect.bg.toStyle(color);
      expect(bg.bgColor, (color & 0x00FFFFFF) | 0x33000000);
      expect(bg.underlineMode, 0);

      final text = MarkingEffect.text.toStyle(color);
      expect(text.textColor, color);
      expect(text.underlineMode, 0);
    });

    test('fromStyle 反推 7 效果；未知模式回退单实线', () {
      expect(
        MarkingEffect.fromStyle(const BookMarkingStyle(underlineMode: 1)),
        MarkingEffect.solid,
      );
      expect(
        MarkingEffect.fromStyle(const BookMarkingStyle(underlineMode: 3)),
        MarkingEffect.wave,
      );
      expect(
        MarkingEffect.fromStyle(const BookMarkingStyle(underlineMode: 2)),
        MarkingEffect.dashed,
      );
      expect(
        MarkingEffect.fromStyle(const BookMarkingStyle(underlineMode: 6)),
        MarkingEffect.strike,
      );
      expect(
        MarkingEffect.fromStyle(const BookMarkingStyle(underlineMode: 7)),
        MarkingEffect.highlight,
      );
      expect(
        MarkingEffect.fromStyle(const BookMarkingStyle(bgColor: 0x33FFFFFF)),
        MarkingEffect.bg,
      );
      expect(
        MarkingEffect.fromStyle(const BookMarkingStyle(textColor: 0xFFFFFFFF)),
        MarkingEffect.text,
      );
      expect(
        MarkingEffect.fromStyle(const BookMarkingStyle(underlineMode: 9)),
        MarkingEffect.solid,
      );
      expect(MarkingEffect.fromStyle(null), MarkingEffect.solid);
    });

    test('colorOf：线色 → 背景剥 alpha → 字色 → 默认色', () {
      expect(
        MarkingEffect.colorOf(
          const BookMarkingStyle(
            underlineColor: 0xFF00FF00,
            bgColor: 0x33FF0000,
            textColor: 0xFF0000FF,
          ),
        ),
        0xFF00FF00,
      );
      expect(
        MarkingEffect.colorOf(const BookMarkingStyle(bgColor: 0x33FF0000)),
        0xFFFF0000,
      );
      expect(
        MarkingEffect.colorOf(const BookMarkingStyle(textColor: 0xFF0000FF)),
        0xFF0000FF,
      );
      expect(MarkingEffect.colorOf(null), MarkingEffect.defaultColor);
      expect(MarkingEffect.defaultColor, 0xFF63C37D);
    });

    test('16 预设色与参考版一致（首/末色）', () {
      expect(kMarkingPresetColors, hasLength(16));
      expect(kMarkingPresetColors.first, 0xFFF44848);
      expect(kMarkingPresetColors.last, 0xFF111111);
      expect(kMarkingPresetColors.toSet(), hasLength(16), reason: '预设色不得重复');
    });
  });

  group('BookMarkingStyle.toHighlightStyle（批7b-2b 渲染映射）', () {
    test('mode 1/3/2 → underline SOLID/WAVY/DASHED（宽/距保留）', () {
      final solid = const BookMarkingStyle(
        underlineMode: 1,
        underlineColor: 0xFF112233,
        underlineWidth: 2.5,
        underlineOffset: 3,
      ).toHighlightStyle();
      expect(solid.underline?.kind, 'SOLID');
      expect(solid.underline?.color, 0xFF112233);
      expect(solid.underline?.width, 2.5);
      expect(solid.underline?.distance, 3);
      expect(solid.strike, isFalse);
      expect(solid.hasRenderableEffect, isTrue);

      expect(
        const BookMarkingStyle(
          underlineMode: 3,
        ).toHighlightStyle().underline?.kind,
        'WAVY',
      );
      expect(
        const BookMarkingStyle(
          underlineMode: 2,
        ).toHighlightStyle().underline?.kind,
        'DASHED',
      );
    });

    test('mode 6 → strike，不加上划线', () {
      final style = const BookMarkingStyle(
        underlineMode: 6,
        underlineColor: 0xFF00FF00,
      ).toHighlightStyle();
      expect(style.strike, isTrue);
      expect(style.strikeColor, 0xFF00FF00);
      expect(style.underline, isNull);
    });

    test('mode 7 → 荧光 fill（20% alpha），不加上划线', () {
      final style = const BookMarkingStyle(
        underlineMode: 7,
        underlineColor: 0xFF123456,
      ).toHighlightStyle();
      expect(style.fill, (0xFF123456 & 0x00FFFFFF) | 0x33000000);
      expect(style.underline, isNull);
      expect(style.strike, isFalse);
    });

    test('BG → fill=bgColor；TEXT → textColor', () {
      final bg = const BookMarkingStyle(bgColor: 0x33FF0000).toHighlightStyle();
      expect(bg.fill, 0x33FF0000);
      expect(bg.textColor, 0);

      final text = const BookMarkingStyle(
        textColor: 0xFF0000FF,
      ).toHighlightStyle();
      expect(text.textColor, 0xFF0000FF);
      expect(text.fill, 0);
    });

    test('mode 5（SVG）回退 SOLID；mode 4 映射 DOUBLE；mode 0/未知无效果', () {
      final svg = const BookMarkingStyle(
        underlineMode: 5,
        underlineColor: 0xFFABCDEF,
      ).toHighlightStyle();
      expect(svg.underline?.kind, 'SOLID');

      final doubleLine = const BookMarkingStyle(
        underlineMode: 4,
        underlineColor: 0xFFABCDEF,
      ).toHighlightStyle();
      expect(doubleLine.underline?.kind, 'DOUBLE');

      final none = const BookMarkingStyle(underlineMode: 0).toHighlightStyle();
      expect(none.hasRenderableEffect, isFalse);
      final unknown = const BookMarkingStyle(
        underlineMode: 9,
      ).toHighlightStyle();
      expect(unknown.hasRenderableEffect, isFalse);
    });

    test('线色为空/0 回退展示色（含 BG/TEXT 展示色与默认色）', () {
      // 无任何颜色 → 默认色
      final fallback = const BookMarkingStyle(
        underlineMode: 1,
      ).toHighlightStyle();
      expect(fallback.underline?.color, MarkingEffect.defaultColor);

      // underlineColor=0，展示色取 textColor
      final withText = const BookMarkingStyle(
        underlineMode: 1,
        underlineColor: 0,
        textColor: 0xFF00AA00,
      ).toHighlightStyle();
      expect(withText.underline?.color, 0xFF00AA00);

      // 删除线同样回退展示色
      final strike = const BookMarkingStyle(
        underlineMode: 6,
        underlineColor: 0,
        bgColor: 0x33FF0000,
      ).toHighlightStyle();
      expect(strike.strikeColor, 0xFFFF0000);
    });
  });

  group('normalizeMarkingText / buildBookMarkingAnchor', () {
    test('逐行 trim 空格/制表/全角空格，保留行内空格与换行', () {
      expect(normalizeMarkingText('  第一行  \n\t第二行　\n'), '第一行\n第二行');
      expect(normalizeMarkingText('  a b  '), 'a b');
      expect(normalizeMarkingText('\u3000\u3000缩进\u3000'), '缩进');
      expect(normalizeMarkingText('一\r\n二'), '一\n二');
      expect(normalizeMarkingText('   '), '');
    });

    test('buildBookMarkingAnchor 统一归一化与 MD5 哈希', () {
      final anchor = buildBookMarkingAnchor(
        chapterIndex: 2,
        chapterPosition: 42,
        selectedText: '  选中\n文本  ',
        contextBefore: '前',
        contextAfter: '后',
      );
      expect(anchor.selectedText, '选中\n文本');
      expect(anchor.normalizedTextHash, markingTextHash('选中\n文本'));
      expect(anchor.normalizedTextHash, hasLength(32));
      expect(anchor.chapterPosition, 42);
      expect(anchor.contextBefore, '前');
      expect(anchor.contextAfter, '后');
      expect(anchor.chapterIndex, 2);
    });
  });
}
