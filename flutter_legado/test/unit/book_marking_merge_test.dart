/// 规则命中 + 书签标记命中合并测试（批7b-2b）
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/services/book_marking_render.dart';

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
  int ruleId = -1,
  int order = kBookMarkingMatchOrderBase,
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

List<(int, int, int)> ranges(List<HighlightMatch> matches) =>
    matches.map((m) => (m.start, m.end, m.ruleId)).toList();

BookMarking marking({
  required String id,
  required String anchorJson,
  String? styleJson,
  bool enabled = true,
  int chapterIndex = 0,
}) {
  return BookMarking(
    id: id,
    bookUrl: 'https://src.com/book/1',
    bookName: '测试书',
    bookAuthor: '作者A',
    chapterIndex: chapterIndex,
    anchorJson: anchorJson,
    styleJson: styleJson,
    enabled: enabled,
  );
}

String anchorJson(String text, {int position = 0}) => buildBookMarkingAnchor(
  chapterIndex: 0,
  chapterPosition: position,
  selectedText: text,
).encode();

void main() {
  group('mergeHighlightAndMarkingMatches', () {
    test('marks 为空：返回规则列表副本', () {
      final rules = [ruleMatch(0, 5), ruleMatch(5, 10, ruleId: 2)];
      final merged = mergeHighlightAndMarkingMatches(rules: rules, marks: []);
      expect(merged, rules);
      expect(identical(merged, rules), isFalse);
    });

    test('双空输入返回空列表', () {
      expect(mergeHighlightAndMarkingMatches(rules: [], marks: []), isEmpty);
    });

    test('mark 内嵌 rule：rule 被切成前后两段', () {
      final merged = mergeHighlightAndMarkingMatches(
        rules: [ruleMatch(0, 100)],
        marks: [markMatch(40, 60, ruleId: -1)],
      );
      expect(ranges(merged), [(0, 40, 1), (40, 60, -1), (60, 100, 1)]);
    });

    test('mark 跨两个 rules：mark 优先，规则保留两侧', () {
      final merged = mergeHighlightAndMarkingMatches(
        rules: [ruleMatch(0, 10, ruleId: 1), ruleMatch(20, 30, ruleId: 2)],
        marks: [markMatch(5, 25, ruleId: -1)],
      );
      expect(ranges(merged), [(0, 5, 1), (5, 25, -1), (25, 30, 2)]);
    });

    test('两个重叠 marks：列表靠后者优先', () {
      final merged = mergeHighlightAndMarkingMatches(
        rules: const [],
        marks: [
          markMatch(0, 50, ruleId: -1, fill: 0x3300FF00),
          markMatch(25, 75, ruleId: -2, fill: 0x33FF0000),
        ],
      );
      expect(ranges(merged), [(0, 25, -1), (25, 75, -2)]);
    });

    test('相邻同样式段合并（跨不同 ruleId）', () {
      final merged = mergeHighlightAndMarkingMatches(
        rules: const [],
        marks: [markMatch(0, 10, ruleId: -1), markMatch(10, 20, ruleId: -2)],
      );
      expect(ranges(merged), [(0, 20, -1)]);
    });

    test('规则同 order：先出现者优先', () {
      final merged = mergeHighlightAndMarkingMatches(
        rules: [
          ruleMatch(0, 20, ruleId: 1, order: 1, fill: 0x110000FF),
          ruleMatch(10, 30, ruleId: 2, order: 1, fill: 0x11FF0000),
        ],
        marks: [markMatch(100, 110, ruleId: -1)],
      );
      expect(ranges(merged).where((r) => r.$1 < 100).toList(), [
        (0, 20, 1),
        (20, 30, 2),
      ]);
    });

    test('mark 优先于高 order 规则', () {
      final merged = mergeHighlightAndMarkingMatches(
        rules: [ruleMatch(0, 10, ruleId: 1, order: 1 << 30)],
        marks: [markMatch(2, 8, ruleId: -1)],
      );
      expect(ranges(merged), [(0, 2, 1), (2, 8, -1), (8, 10, 1)]);
    });

    test('非法区间被忽略；输出按 start 升序', () {
      final merged = mergeHighlightAndMarkingMatches(
        rules: [ruleMatch(20, 30), ruleMatch(5, 5)],
        marks: [markMatch(0, 10, ruleId: -1), markMatch(-1, 3, ruleId: -2)],
      );
      expect(ranges(merged), [(0, 10, -1), (20, 30, 1)]);
    });
  });

  group('buildMarkingMatches', () {
    const content = '开头顶部 关键词 目标文本 结尾';

    test('解析锚点并转换样式；跳过禁用/无法定位/无样式标记', () {
      final markings = [
        marking(
          id: 'm1',
          anchorJson: anchorJson('关键词', position: 4),
          styleJson: const BookMarkingStyle(textColor: 0xFFFF0000).encode(),
        ),
        marking(
          id: 'm2',
          anchorJson: anchorJson('目标文本'),
          styleJson: const BookMarkingStyle(
            underlineMode: 3,
            underlineColor: 0xFF00FF00,
          ).encode(),
          enabled: false,
        ),
        marking(
          id: 'm3',
          anchorJson: anchorJson('不存在'),
          styleJson: const BookMarkingStyle(textColor: 0xFFFF0000).encode(),
        ),
        marking(
          id: 'm4',
          anchorJson: anchorJson('结尾'),
          styleJson: const BookMarkingStyle().encode(),
        ),
        marking(id: 'm5', anchorJson: 'not json', styleJson: '{}'),
      ];
      final matches = buildMarkingMatches(content: content, markings: markings);
      expect(matches, hasLength(1));
      final match = matches.single;
      expect(content.substring(match.start, match.end), '关键词');
      expect(match.ruleId, -1);
      expect(match.order, greaterThanOrEqualTo(kBookMarkingMatchOrderBase));
      expect(match.style.textColor, 0xFFFF0000);
      expect(match.styleJson, isNotEmpty);
    });

    test('多标记按列表顺序递增 ruleId/order；空白变体可定位', () {
      const text = '第一段    文本\n第二段';
      final markings = [
        marking(
          id: 'm1',
          anchorJson: anchorJson('第一段\n文本'),
          styleJson: const BookMarkingStyle(textColor: 0xFF111111).encode(),
        ),
        marking(
          id: 'm2',
          anchorJson: anchorJson('第二段'),
          styleJson: const BookMarkingStyle(bgColor: 0x33FF0000).encode(),
        ),
      ];
      final matches = buildMarkingMatches(content: text, markings: markings);
      expect(matches, hasLength(2));
      expect(matches[0].ruleId, -1);
      expect(matches[1].ruleId, -2);
      expect(matches[1].order, greaterThan(matches[0].order));
      expect(text.substring(matches[0].start, matches[0].end), '第一段    文本');
      expect(text.substring(matches[1].start, matches[1].end), '第二段');
    });

    test('空正文/空列表返回空', () {
      expect(buildMarkingMatches(content: '', markings: const []), isEmpty);
      expect(
        buildMarkingMatches(
          content: '正文',
          markings: [
            marking(id: 'm', anchorJson: anchorJson('正文'), styleJson: '{}'),
          ],
        ),
        isEmpty,
      );
    });
  });
}
