import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_legado/src/screens/search_content_screen.dart';

/// 正文搜索命中区间纯函数测试（差异清单 C4 对齐项：替换/正则开关）
///
/// 对齐基准：原版 `SearchContentViewModel.searchPosition` 与
/// 重构版 `search_content_page.dart`（正则 findAll；非法正则返回空）。
void main() {
  group('findContentHits 普通模式', () {
    test('大小写不敏感子串查找，命中多处', () {
      final hits = findContentHits('Abc abc ABC', 'abc', useRegex: false);
      expect(hits.length, 3);
      expect(hits.map((h) => h.start).toList(), [0, 4, 8]);
      expect(hits.every((h) => h.end - h.start == 3), isTrue);
    });

    test('未命中返回空列表', () {
      expect(findContentHits('正文内容', '不存在', useRegex: false), isEmpty);
    });

    test('空关键词返回空列表（不产生全量命中）', () {
      expect(findContentHits('正文内容', '', useRegex: false), isEmpty);
    });

    test('maxHits 限流：超出上限即停止收集', () {
      final content = 'a' * 100;
      final hits = findContentHits(content, 'a', useRegex: false, maxHits: 5);
      expect(hits.length, 5);
    });
  });

  group('findContentHits 正则模式', () {
    test('按正则匹配并返回完整区间', () {
      final hits = findContentHits('第1章 第23章 第456章', r'第\d+章',
          useRegex: true);
      expect(hits.length, 3);
      expect(hits.map((h) => h.end - h.start).toList(), [3, 4, 5]);
    });

    test('非法正则返回空列表（对齐原版静默语义）', () {
      expect(findContentHits('正文', '([', useRegex: true), isEmpty);
    });

    test('正则不忽略大小写（对齐原版 Kotlin Regex 默认行为）', () {
      expect(findContentHits('ABC abc', 'abc', useRegex: true).length, 1);
    });
  });
}
