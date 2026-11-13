/// 手动高亮（highlights 表）正文渲染数据链测试
///
/// 覆盖 style 映射（参考版 `{"type":"background","color":"#AARRGGBB"}` 与
/// 原版 HighlightStyle JSON）、chapterPos 坐标换算（含 layoutTitleLength
/// 标题偏移）、越界裁剪/坏记录跳过，以及三方合并层级优先级。
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/services/book_marking_render.dart';
import 'package:flutter_legado/src/services/saved_highlight_render.dart';

Map<String, dynamic> highlightRecord({
  required int chapterPos,
  required int chapterPosEnd,
  String style = '{"type":"background","color":"#33FF0000"}',
  int layoutTitleLength = 0,
  String bookText = '',
}) {
  return {
    'time': 1,
    'bookUrl': 'https://src.com/book/1',
    'chapterUrl': 'u0',
    'bookName': '测试书',
    'bookAuthor': '作者A',
    'chapterIndex': 0,
    'chapterPos': chapterPos,
    'chapterPosEnd': chapterPosEnd,
    'layoutTitleLength': layoutTitleLength,
    'chapterName': '第一章',
    'bookText': bookText,
    'style': style,
    'note': '',
  };
}

HighlightMatch savedMatch(
  int start,
  int end, {
  int ruleId = -1,
  int order = kSavedHighlightMatchOrderBase,
  int fill = 0x3300FF00,
}) {
  return HighlightMatch(
    ruleId: ruleId,
    start: start,
    end: end,
    order: order,
    style: HighlightStyle(fill: fill),
  );
}

HighlightMatch ruleMatch(
  int start,
  int end, {
  int ruleId = 1,
  int order = 0,
  int fill = 0x110000FF,
}) {
  return HighlightMatch(
    ruleId: ruleId,
    start: start,
    end: end,
    order: order,
    style: HighlightStyle(fill: fill),
  );
}

HighlightMatch markMatch(
  int start,
  int end, {
  int ruleId = -100,
  int order = kBookMarkingMatchOrderBase,
  int fill = 0x33FF0000,
}) {
  return HighlightMatch(
    ruleId: ruleId,
    start: start,
    end: end,
    order: order,
    style: HighlightStyle(fill: fill),
  );
}

List<(int, int, int)> ranges(List<HighlightMatch> matches) =>
    matches.map((m) => (m.start, m.end, m.ruleId)).toList();

void main() {
  group('parseSavedHighlightStyle', () {
    test('type=background + #AARRGGBB → fill', () {
      final style = parseSavedHighlightStyle(
        '{"type":"background","color":"#33FF0000"}',
      );
      expect(style, isNotNull);
      expect(style!.fill, 0x33FF0000);
      expect(style.hasRenderableEffect, isTrue);
    });

    test('#RRGGBB 视为不透明；0x 前缀同样支持', () {
      expect(
        parseSavedHighlightStyle(
          '{"type":"background","color":"#AABBCC"}',
        )!.fill,
        0xFFAABBCC,
      );
      expect(
        parseSavedHighlightStyle(
          '{"type":"background","color":"0x80112233"}',
        )!.fill,
        0x80112233,
      );
    });

    test('type=underline/strike/text 映射到既有渲染能力', () {
      final underline = parseSavedHighlightStyle(
        '{"type":"underline","color":"#FF00FF00","kind":"wavy","width":2}',
      );
      expect(underline!.underline?.kind, 'WAVY');
      expect(underline.underline?.color, 0xFF00FF00);
      expect(underline.underline?.width, 2);

      final strike = parseSavedHighlightStyle(
        '{"type":"strike","color":"#FF333333"}',
      );
      expect(strike!.strike, isTrue);
      expect(strike.strikeColor, 0xFF333333);

      final text = parseSavedHighlightStyle(
        '{"type":"text","color":"#FF0000FF"}',
      );
      expect(text!.textColor, 0xFF0000FF);
    });

    test('无法映射的 type / 非法 JSON / 空样式返回 null', () {
      expect(
        parseSavedHighlightStyle('{"type":"gradient","color":"#FF00FF00"}'),
        isNull,
      );
      expect(parseSavedHighlightStyle('not json'), isNull);
      expect(parseSavedHighlightStyle(''), isNull);
      expect(parseSavedHighlightStyle(null), isNull);
    });

    test('兼容原版 HighlightStyle JSON（无 type 键）', () {
      final style = parseSavedHighlightStyle(
        jsonEncode(const HighlightStyle(fill: 0x3300FF00).toMap()),
      );
      expect(style!.fill, 0x3300FF00);
      expect(
        parseSavedHighlightStyle(jsonEncode(const HighlightStyle().toMap())),
        isNull,
        reason: '无任何可渲染效果时应跳过',
      );
    });
  });

  group('buildSavedHighlightMatches', () {
    test('chapterPos..chapterPosEnd 直接映射为 UTF-16 区间', () {
      const content = '高亮文字其余正文';
      final matches = buildSavedHighlightMatches(
        content: content,
        rawJson: jsonEncode([highlightRecord(chapterPos: 0, chapterPosEnd: 4)]),
      );
      expect(matches, hasLength(1));
      final match = matches.single;
      expect(content.substring(match.start, match.end), '高亮文字');
      expect(match.style.fill, 0x33FF0000);
      expect(match.ruleId, lessThan(0));
      expect(match.order, greaterThanOrEqualTo(kSavedHighlightMatchOrderBase));
    });

    test('layoutTitleLength 为标题偏移：渲染前扣除', () {
      // 原版 chapterPos 含标题长度；我方 content 不含标题
      final matches = buildSavedHighlightMatches(
        content: '正文内容',
        rawJson: jsonEncode([
          highlightRecord(
            chapterPos: 2,
            chapterPosEnd: 4,
            layoutTitleLength: 2,
          ),
        ]),
      );
      expect(matches, hasLength(1));
      expect(matches.single.start, 0);
      expect(matches.single.end, 2);
      expect(matches.single.end <= '正文内容'.length, isTrue);
    });

    test('越界区间按正文长度裁剪；裁剪后退化则跳过', () {
      final matches = buildSavedHighlightMatches(
        content: '四个字呀',
        rawJson: jsonEncode([
          highlightRecord(chapterPos: 2, chapterPosEnd: 10),
          highlightRecord(
            chapterPos: 10,
            chapterPosEnd: 20,
            style: '{"type":"background","color":"#FF00FF00"}',
          ),
          highlightRecord(chapterPos: -2, chapterPosEnd: 1),
        ]),
      );
      // 第一条 2..4；第三条 -2..1 裁剪为 0..1；第二条完全越界跳过。
      // 输出保持数据库顺序（chapterPos,time 升序），由合并函数统一排序。
      expect(ranges(matches).map((r) => (r.$1, r.$2)).toList(), [
        (2, 4),
        (0, 1),
      ]);
    });

    test('样式无法映射/坏记录跳过，不连累其它记录', () {
      final matches = buildSavedHighlightMatches(
        content: '甲乙丙丁',
        rawJson: jsonEncode([
          highlightRecord(
            chapterPos: 0,
            chapterPosEnd: 2,
            style: '{"type":"gradient","color":"#FF00FF00"}',
          ),
          highlightRecord(chapterPos: 2, chapterPosEnd: 4),
          'not a map',
        ]),
      );
      expect(matches, hasLength(1));
      expect(matches.single.start, 2);
      expect(matches.single.end, 4);
    });

    test('空正文/空 JSON/非数组返回空', () {
      expect(
        buildSavedHighlightMatches(
          content: '',
          rawJson: jsonEncode([
            highlightRecord(chapterPos: 0, chapterPosEnd: 2),
          ]),
        ),
        isEmpty,
      );
      expect(buildSavedHighlightMatches(content: '正文', rawJson: ''), isEmpty);
      expect(
        buildSavedHighlightMatches(content: '正文', rawJson: '{"a":1}'),
        isEmpty,
      );
    });
  });

  group('mergeHighlightMarkingAndSavedMatches', () {
    test('saved 为空：等价于两方合并（标记仍压规则）', () {
      final merged = mergeHighlightMarkingAndSavedMatches(
        rules: [ruleMatch(0, 10)],
        marks: [markMatch(2, 8)],
        saved: const [],
      );
      expect(ranges(merged), [(0, 2, 1), (2, 8, -100), (8, 10, 1)]);
    });

    test('手动高亮优先于规则，规则保留未覆盖部分', () {
      final merged = mergeHighlightMarkingAndSavedMatches(
        rules: [ruleMatch(0, 10)],
        marks: const [],
        saved: [savedMatch(2, 8, ruleId: -1)],
      );
      expect(ranges(merged), [(0, 2, 1), (2, 8, -1), (8, 10, 1)]);
    });

    test('笔记标记仍优先于手动高亮（既有 7b-2b 语义不回退）', () {
      final merged = mergeHighlightMarkingAndSavedMatches(
        rules: const [],
        marks: [markMatch(0, 10)],
        saved: [savedMatch(2, 8, ruleId: -1)],
      );
      expect(ranges(merged), [(0, 10, -100)]);
    });

    test('手动高亮之间：列表靠后者（同位置更晚创建）优先', () {
      final merged = mergeHighlightMarkingAndSavedMatches(
        rules: const [],
        marks: const [],
        saved: [
          savedMatch(0, 10, ruleId: -1, fill: 0x3300FF00),
          savedMatch(5, 15, ruleId: -2, fill: 0x33FF0000),
        ],
      );
      expect(ranges(merged), [(0, 5, -1), (5, 15, -2)]);
    });

    test('输出按 start 升序且互不重叠', () {
      final merged = mergeHighlightMarkingAndSavedMatches(
        rules: [ruleMatch(10, 20)],
        marks: [markMatch(0, 5)],
        saved: [savedMatch(3, 12, ruleId: -1)],
      );
      expect(ranges(merged), [(0, 5, -100), (5, 12, -1), (12, 20, 1)]);
    });
  });
}
