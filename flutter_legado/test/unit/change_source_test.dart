import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_legado/src/screens/change_source_screen.dart';

void main() {
  group('SourceMatchItem model', () {
    test('fromJson 解析 Rust SourceMatch 的 snake_case 字段', () {
      final json = {
        'source_url': 'https://source.example.com',
        'source_name': '笔趣阁',
        'book_url': 'https://source.example.com/book/1',
        'book_name': '斗破苍穹',
        'author': '天蚕土豆',
        'latest_chapter': '第一千六百章 大结局',
        'word_count': '530万字',
        'score': 87.5,
      };

      final item = SourceMatchItem.fromJson(json);

      expect(item.sourceUrl, equals('https://source.example.com'));
      expect(item.sourceName, equals('笔趣阁'));
      expect(item.bookUrl, equals('https://source.example.com/book/1'));
      expect(item.bookName, equals('斗破苍穹'));
      expect(item.author, equals('天蚕土豆'));
      expect(item.latestChapter, equals('第一千六百章 大结局'));
      expect(item.wordCount, equals('530万字'));
      expect(item.score, equals(87.5));
    });

    test('fromJson 可选字段缺失时为 null，score 默认 0', () {
      final item = SourceMatchItem.fromJson({
        'source_url': 'https://a.com',
        'source_name': 'A源',
        'book_url': 'https://a.com/b',
        'book_name': '测试',
        'author': '',
      });

      expect(item.latestChapter, isNull);
      expect(item.wordCount, isNull);
      expect(item.score, equals(0.0));
    });

    test('fromJson score 为整数时正确转为 double', () {
      final item = SourceMatchItem.fromJson({
        'source_url': 'https://a.com',
        'source_name': 'A源',
        'book_url': 'https://a.com/b',
        'book_name': '测试',
        'author': '',
        'score': 95,
      });

      expect(item.score, equals(95.0));
    });

    test('fromJson 空 map 使用默认值', () {
      final item = SourceMatchItem.fromJson({});
      expect(item.sourceUrl, equals(''));
      expect(item.sourceName, equals(''));
      expect(item.bookUrl, equals(''));
      expect(item.score, equals(0.0));
    });
  });
}
