/// 书签标记锚点解析测试（批7b-2b）
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/services/book_marking_range_resolver.dart';

BookMarkingAnchor anchor(
  String selectedText, {
  int? position,
  String before = '',
  String after = '',
}) {
  return buildBookMarkingAnchor(
    chapterIndex: 0,
    chapterPosition: position ?? 0,
    selectedText: selectedText,
    contextBefore: before,
    contextAfter: after,
  );
}

void main() {
  group('精确匹配', () {
    test('唯一命中返回正确 UTF-16 半开区间', () {
      const content = '开头关键词结尾';
      final range = resolveBookMarkingRange(
        content,
        anchor('关键词', position: 2),
      );
      expect(range, isNotNull);
      expect(content.substring(range!.start, range.end), '关键词');
      expect(range.start, 2);
      expect(range.end, 5);
    });

    test('多次命中取离 chapterPosition 最近的一次', () {
      const content = '关键词A关键词B关键词C';
      // 第 2 个出现在 index 4
      final range = resolveBookMarkingRange(
        content,
        anchor('关键词', position: 5),
      );
      expect(range!.start, 4);
      expect(range.end, 7);

      final first = resolveBookMarkingRange(
        content,
        anchor('关键词', position: 0),
      );
      expect(first!.start, 0);

      final last = resolveBookMarkingRange(
        content,
        anchor('关键词', position: 99),
      );
      expect(last!.start, 8);
    });

    test('chapterPosition 为 null 时按 0 就近', () {
      const content = 'x标记y标记';
      final range = resolveBookMarkingRange(content, anchor('标记'));
      expect(range!.start, 1);
    });

    test('前后文不参与匹配（缺失/错误也不影响）', () {
      const content = '完全无关的正文，目标文本在这里。';
      final range = resolveBookMarkingRange(
        content,
        anchor('目标文本', position: 99, before: '错误前文', after: '错误后文'),
      );
      expect(range, isNotNull);
      expect(content.substring(range!.start, range.end), '目标文本');
    });

    test('代理对（emoji）区间不切半', () {
      const content = '😀关键词😀';
      final range = resolveBookMarkingRange(content, anchor('关键词'));
      expect(range, isNotNull);
      expect(range!.start, 2, reason: 'emoji 占 2 个 UTF-16 code unit');
      expect(range.end, 5);
      expect(content.substring(range.start, range.end), '关键词');

      final withEmoji = resolveBookMarkingRange(content, anchor('😀关键词'));
      expect(withEmoji!.start, 0);
      expect(withEmoji.end, 5, reason: 'emoji 2 + 关键词 3 = 5 code unit');
      expect(content.substring(withEmoji.start, withEmoji.end), '😀关键词');
    });
  });

  group('归一化回退', () {
    test('换行/多空格差异：折叠空白后映射回原文完整区间', () {
      const content = '前缀 一段    文本 后缀';
      // 存储文本含换行，与正文多空格不同 → 精确匹配失败，走归一化
      final range = resolveBookMarkingRange(
        content,
        anchor('一段\n文本', position: 3),
      );
      expect(range, isNotNull);
      expect(
        content.substring(range!.start, range.end),
        '一段    文本',
        reason: '映射应覆盖原文空白整段，不截断',
      );
    });

    test('全角空格差异可匹配', () {
      const content = '前\u3000\u3000文';
      final range = resolveBookMarkingRange(content, anchor('前 文'));
      expect(range, isNotNull);
      expect(content.substring(range!.start, range.end), '前\u3000\u3000文');
    });

    test('归一化多次命中取最近位置', () {
      const content = 'foo  bar ..... foo bar';
      final secondStart = content.lastIndexOf('foo');
      final range = resolveBookMarkingRange(
        content,
        anchor('foo\nbar', position: secondStart),
      );
      expect(range!.start, secondStart);
      expect(content.substring(range.start, range.end), 'foo bar');
    });

    test('精确匹配优先于归一化回退', () {
      // 原文精确命中 index 2；归一化后的 "A B" 另有出现
      const content = 'x A\nB y A B';
      final range = resolveBookMarkingRange(
        content,
        anchor('A\nB', position: 2),
      );
      expect(range!.start, 2);
      expect(content.substring(range.start, range.end), 'A\nB');
    });
  });

  group('失败与边界', () {
    test('缺失文本返回 null', () {
      expect(resolveBookMarkingRange('这里是正文', anchor('不存在的文本')), isNull);
    });

    test('空正文/空候选返回 null', () {
      expect(resolveBookMarkingRange('', anchor('文本')), isNull);
      expect(resolveBookMarkingRange('正文', anchor('   ')), isNull);
    });

    test('候选为空白变体且正文只有空白 → null', () {
      expect(resolveBookMarkingRange(' \u3000 \n ', anchor('  ')), isNull);
    });
  });
}
