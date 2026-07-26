import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_legado/src/models/book.dart';
import 'package:flutter_legado/src/models/book_source.dart';

void main() {
  group('Book model', () {
    test('Book model serialization', () {
      const book = Book(
        bookUrl: 'https://example.com/book/1',
        name: '斗破苍穹',
        author: '天蚕土豆',
        origin: 'loc_book',
        originName: '起点',
        bookType: 0,
        totalChapterNum: 1648,
        durChapterIndex: 100,
        canUpdate: true,
      );

      final json = book.toJson();

      expect(json['bookUrl'], equals('https://example.com/book/1'));
      expect(json['name'], equals('斗破苍穹'));
      expect(json['author'], equals('天蚕土豆'));
      expect(json['origin'], equals('loc_book'));
      expect(json['originName'], equals('起点'));
      expect(json['type'], equals(0));
      expect(json['totalChapterNum'], equals(1648));
      expect(json['durChapterIndex'], equals(100));
      expect(json['canUpdate'], isTrue);
    });

    test('Book model deserialization', () {
      final json = {
        'bookUrl': 'https://example.com/book/2',
        'tocUrl': '',
        'origin': 'loc_book',
        'originName': '纵横',
        'name': '完美世界',
        'author': '辰东',
        'type': 0,
        'group': 0,
        'totalChapterNum': 1800,
        'durChapterIndex': 50,
        'canUpdate': false,
      };

      final book = Book.fromJson(json);

      expect(book.bookUrl, equals('https://example.com/book/2'));
      expect(book.name, equals('完美世界'));
      expect(book.author, equals('辰东'));
      expect(book.totalChapterNum, equals(1800));
      expect(book.canUpdate, isFalse);
    });

    test('Book round-trip serialization', () {
      const original = Book(
        bookUrl: 'https://example.com/book/3',
        name: '遮天',
        author: '辰东',
        totalChapterNum: 2100,
      );

      final json = original.toJson();
      final restored = Book.fromJson(json);

      expect(restored.bookUrl, equals(original.bookUrl));
      expect(restored.name, equals(original.name));
      expect(restored.author, equals(original.author));
      expect(restored.totalChapterNum, equals(original.totalChapterNum));
    });
  });

  group('BookSource model', () {
    test('BookSource model serialization', () {
      const source = BookSource(
        bookSourceUrl: 'https://source.example.com',
        bookSourceName: '测试书源',
        bookSourceType: 0,
        enabled: true,
        enabledExplore: true,
        customOrder: 10,
      );

      final json = source.toJson();

      expect(json['bookSourceUrl'], equals('https://source.example.com'));
      expect(json['bookSourceName'], equals('测试书源'));
      expect(json['bookSourceType'], equals(0));
      expect(json['enabled'], isTrue);
      expect(json['enabledExplore'], isTrue);
      expect(json['customOrder'], equals(10));
    });

    test('BookSource model deserialization', () {
      final json = {
        'bookSourceUrl': 'https://source2.example.com',
        'bookSourceName': '第二书源',
        'bookSourceType': 1,
        'enabled': false,
        'enabledExplore': false,
        'customOrder': 20,
      };

      final source = BookSource.fromJson(json);

      expect(source.bookSourceUrl, equals('https://source2.example.com'));
      expect(source.bookSourceName, equals('第二书源'));
      expect(source.bookSourceType, equals(1));
      expect(source.enabled, isFalse);
      expect(source.customOrder, equals(20));
    });

    test('BookSource round-trip serialization', () {
      const original = BookSource(
        bookSourceUrl: 'https://source3.example.com',
        bookSourceName: '第三书源',
        bookSourceType: 0,
        enabled: true,
      );

      final json = original.toJson();
      final restored = BookSource.fromJson(json);

      expect(restored.bookSourceUrl, equals(original.bookSourceUrl));
      expect(restored.bookSourceName, equals(original.bookSourceName));
      expect(restored.enabled, equals(original.enabled));
    });
  });
}
