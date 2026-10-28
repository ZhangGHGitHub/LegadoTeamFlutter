/// 高亮样式/命中区间解析测试（批34）
///
/// 覆盖：原版 HighlightStyle JSON（含负数 ARGB、未知键、下划线/删除线）
/// 与 Rust `highlightRuleMatch` 返回数组的容错解析。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_legado/src/models/highlight_style.dart';

void main() {
  group('HighlightStyle 解析', () {
    test('空/非法/非对象 style 返回 empty（不抛错）', () {
      expect(HighlightStyle.parse(null).hasRenderableEffect, isFalse);
      expect(HighlightStyle.parse('').hasRenderableEffect, isFalse);
      expect(HighlightStyle.parse('not-json').hasRenderableEffect, isFalse);
      expect(HighlightStyle.parse('[1,2]').hasRenderableEffect, isFalse);
    });

    test('负数 ARGB 归一化为无符号 32 位', () {
      // 原版 0x80FFF176.toInt() = -2130710154
      final style = HighlightStyle.parse('{"fill":-2130710154}');
      expect(style.fill, 0x80FFF176);
      expect(style.hasRenderableEffect, isTrue);
    });

    test('前景色/填充/下划线/删除线字段完整解析', () {
      final style = HighlightStyle.parse(
        '{"textColor":-16777216,"fill":-2130710154,'
        '"fillShape":"rounded","underline":{"kind":"wavy",'
        '"color":-1754827,"width":2.5,"distance":3},'
        '"strike":{"color":-6381922},"bold":true,"italic":true}',
      );
      expect(style.textColor, 0xFF000000);
      expect(style.fill, 0x80FFF176);
      expect(style.fillShape, 'ROUNDED');
      expect(style.underline, isNotNull);
      expect(style.underline!.kind, 'WAVY');
      expect(style.underline!.color, 0xFFE53935);
      expect(style.underline!.width, 2.5);
      expect(style.underline!.distance, 3);
      expect(style.strike, isTrue);
      expect(style.strikeColor, 0xFF9E9E9E);
      // bold/italic 解析但不参与 MVP 渲染判定
      expect(style.bold, isTrue);
      expect(style.italic, isTrue);
    });

    test('未知键保留在 extra（再次序列化不丢）', () {
      final style = HighlightStyle.parse(
        '{"fill":1,"fontPath":"/fonts/a.ttf","shadow":{"radius":3},'
        '"futureKey":{"x":1}}',
      );
      // 已建模但不参与 MVP 渲染的键不进 extra，未知键原样保留
      expect(style.extra.containsKey('fontPath'), isFalse);
      expect(style.extra['futureKey'], {'x': 1});
      final roundTrip = style.toMap();
      expect(roundTrip['futureKey'], {'x': 1});
    });

    test('仅 bold/italic 不算可渲染效果（不改字体度量）', () {
      final style = HighlightStyle.parse('{"bold":true,"italic":true}');
      expect(style.hasRenderableEffect, isFalse);
    });
  });

  group('HighlightMatch 解析', () {
    test('正常数组按 start 升序，非法条目跳过', () {
      final matches = parseHighlightMatches(
        '[{"ruleId":2,"start":5,"end":8,"order":3,'
        '"styleJson":"{\\"fill\\":1}"},'
        '{"ruleId":1,"start":0,"end":2,"order":1,"styleJson":"{}"},'
        '{"ruleId":9,"start":4,"end":4,"order":1,"styleJson":"{}"},'
        '{"ruleId":8,"start":-1,"end":2,"order":1,"styleJson":"{}"}]',
      );
      expect(matches.length, 2);
      expect(matches[0].ruleId, 1);
      expect(matches[1].ruleId, 2);
      expect(matches[1].style.fill, 1);
      expect(matches[1].length, 3);
    });

    test('空串/null/非法 JSON 返回空列表', () {
      expect(parseHighlightMatches(''), isEmpty);
      expect(parseHighlightMatches('null'), isEmpty);
      expect(parseHighlightMatches('{'), isEmpty);
      expect(parseHighlightMatches('{"a":1}'), isEmpty);
    });
  });
}
