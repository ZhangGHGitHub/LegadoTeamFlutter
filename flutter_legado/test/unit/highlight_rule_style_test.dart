// 高亮规则 style 字段解析与保存补丁单测（批33）
//
// 背景：原版 HighlightRule.style 是完整 HighlightStyle JSON（fill/fillShape/
// textColor/bold/italic/underline/strike/...）。我方编辑表单只编辑颜色，
// 旧保存路径重建 style 会丢失其余键；本测试固定「补丁式保存」与基础字段
// 解析（渲染专项后续批）。
//
// 编写：全栈工程师（批33） ｜ 2026-10-29
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_legado/src/providers/highlight_rules/highlight_rules_state.dart';

void main() {
  group('HighlightRule.styleMap 基础字段解析', () {
    const richStyle = '{"fill":-16711936,"fillShape":"ROUNDED",'
        '"textColor":-65536,"bold":true,"italic":true,'
        '"underline":{"kind":"WAVY","color":-65536},"strike":{"color":-1},'
        '"fontSize":22.5,"futureUnknownKey":42}';

    test('解析 textColor/fill/bold/italic/underline', () {
      const rule = HighlightRule(pattern: 'x', style: richStyle);
      expect(rule.styleTextColor, -65536);
      expect(rule.styleFill, -16711936);
      expect(rule.styleBold, isTrue);
      expect(rule.styleItalic, isTrue);
      expect(rule.styleUnderline, isTrue);
      expect(rule.styleMap?['fillShape'], 'ROUNDED');
      expect(rule.styleMap?['futureUnknownKey'], 42);
    });

    test('style 为空/非法/类型不符时安全回退', () {
      expect(const HighlightRule().styleTextColor, isNull);
      expect(const HighlightRule().styleFill, 0);
      expect(const HighlightRule().styleBold, isFalse);
      expect(const HighlightRule().styleUnderline, isFalse);
      expect(const HighlightRule(style: 'not-json').styleMap, isNull);
      expect(const HighlightRule(style: '[1,2]').styleMap, isNull);
      expect(
        const HighlightRule(style: '{"textColor":"red"}').styleTextColor,
        isNull,
      );
    });

    test('underline 缺省/null 视为未启用', () {
      const rule = HighlightRule(
        style: '{"textColor":1,"underline":null}',
      );
      expect(rule.styleUnderline, isFalse);
      expect(rule.styleTextColor, 1);
    });

    test('underline 按对象判定：false/数组不算启用，对象/空对象算启用', () {
      // [批33b] 原版 HighlightStyle.underline 是对象通道；JSON 里的
      // false/[] 不是启用态（旧实现「非 null 即启用」会误判）
      expect(
        const HighlightRule(style: '{"underline":false}').styleUnderline,
        isFalse,
      );
      expect(
        const HighlightRule(style: '{"underline":[]}').styleUnderline,
        isFalse,
      );
      expect(
        const HighlightRule(style: '{"underline":{}}').styleUnderline,
        isTrue,
      );
      expect(
        const HighlightRule(style: '{"underline":{"kind":"SOLID"}}')
            .styleUnderline,
        isTrue,
      );
    });
  });

  group('mergeHighlightStyleTextColor 补丁语义', () {
    test('只覆盖 textColor，其余键（含未知键）原样保留', () {
      const raw = '{"fill":-1,"textColor":-65536,"bold":true,'
          '"underline":{"kind":"SOLID"},"strike":{"color":2},'
          '"futureUnknownKey":[1,2,3]}';
      final merged =
          jsonDecode(mergeHighlightStyleTextColor(raw, 0xFF00FF00)) as Map;

      expect(merged['textColor'], 0xFF00FF00);
      expect(merged['fill'], -1);
      expect(merged['bold'], true);
      expect(merged['underline'], {'kind': 'SOLID'});
      expect(merged['strike'], {'color': 2});
      expect(merged['futureUnknownKey'], [1, 2, 3]);
    });

    test('空/非法 style 仅写入本次颜色，不抛错', () {
      expect(
        jsonDecode(mergeHighlightStyleTextColor(null, -65536)),
        {'textColor': -65536},
      );
      expect(
        jsonDecode(mergeHighlightStyleTextColor('', 1)),
        {'textColor': 1},
      );
      expect(
        jsonDecode(mergeHighlightStyleTextColor('broken{', 2)),
        {'textColor': 2},
      );
      expect(
        jsonDecode(mergeHighlightStyleTextColor('[1]', 3)),
        {'textColor': 3},
      );
    });
  });

  group('mergeHighlightStyleFields 富样式补丁（批7a）', () {
    test('写入 fill/underline/strike，未知键与 underline.distance 原样保留', () {
      const raw = '{"fill":-1,"textColor":-65536,"bold":true,'
          '"underline":{"kind":"SOLID","color":0,"width":1.0,"distance":2.5,'
          '"futureUnderlineKey":1},'
          '"strike":{"color":-1,"futureStrikeKey":2},'
          '"futureUnknownKey":{"nested":true}}';
      final merged = jsonDecode(mergeHighlightStyleFields(
        raw,
        fill: 0,
        underline: {
          'kind': 'DASHED',
          'color': 123,
          'width': 3.5,
          'distance': 2.5,
          'futureUnderlineKey': 1,
        },
        strike: {'color': 456, 'futureStrikeKey': 2},
      )) as Map<String, dynamic>;

      expect(merged['fill'], 0);
      expect(merged['textColor'], -65536, reason: '未传 textColor 不得改写');
      expect(merged['bold'], true);
      expect(merged['underline'], {
        'kind': 'DASHED',
        'color': 123,
        'width': 3.5,
        'distance': 2.5,
        'futureUnderlineKey': 1,
      });
      expect(merged['strike'], {'color': 456, 'futureStrikeKey': 2});
      expect(merged['futureUnknownKey'], {'nested': true});
    });

    test('关闭下划线/删除线时移除对应键', () {
      const raw = '{"textColor":1,'
          '"underline":{"kind":"WAVY","distance":4.0},'
          '"strike":{"color":-1},"fill":9}';
      final merged = jsonDecode(mergeHighlightStyleFields(
        raw,
        removeUnderline: true,
        removeStrike: true,
      )) as Map<String, dynamic>;

      expect(merged.containsKey('underline'), isFalse);
      expect(merged.containsKey('strike'), isFalse);
      expect(merged['textColor'], 1);
      expect(merged['fill'], 9);
    });

    test('textColor 未触碰保真（含 0）；显式 removeTextColor 才删除', () {
      const raw = '{"textColor":0,"fill":5}';
      final untouched = jsonDecode(mergeHighlightStyleFields(raw))
          as Map<String, dynamic>;
      expect(untouched['textColor'], 0);
      expect(untouched['fill'], 5);

      final removed = jsonDecode(
        mergeHighlightStyleFields(raw, removeTextColor: true),
      ) as Map<String, dynamic>;
      expect(removed.containsKey('textColor'), isFalse);
      expect(removed['fill'], 5);
    });

    test('空/非法 style 从空对象开始，只写本次显式属性', () {
      expect(
        jsonDecode(mergeHighlightStyleFields(null, fill: 0)),
        {'fill': 0},
      );
      expect(
        jsonDecode(mergeHighlightStyleFields('', fill: 0)),
        {'fill': 0},
      );
      expect(
        jsonDecode(mergeHighlightStyleFields('broken{', fill: 0)),
        {'fill': 0},
      );
      expect(
        jsonDecode(mergeHighlightStyleFields('[1]', underline: {'kind': 'SOLID'})),
        {
          'underline': {'kind': 'SOLID'}
        },
      );
    });

    test('删除标志优先于同组写入值', () {
      final merged = jsonDecode(mergeHighlightStyleFields(
        '{"textColor":1,"underline":{"kind":"SOLID"},"strike":{"color":2}}',
        textColor: 99,
        removeTextColor: true,
        removeUnderline: true,
        removeStrike: true,
      )) as Map<String, dynamic>;
      expect(merged.containsKey('textColor'), isFalse);
      expect(merged.containsKey('underline'), isFalse);
      expect(merged.containsKey('strike'), isFalse);
    });
  });
}
