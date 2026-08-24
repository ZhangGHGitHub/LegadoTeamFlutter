import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/utils/book_progress_utils.dart';

void main() {
  group('bookInfoReadProgressPercent', () {
    test('无阅读进度时返回 null', () {
      const book = Book(
        bookUrl: 'u1',
        name: '书',
        totalChapterNum: 10,
        durChapterIndex: 0,
        durChapterPos: 0,
      );
      expect(bookInfoReadProgressPercent(book), isNull);
    });

    test('仅 1 章时不显示百分比（对齐原版 resolveBookInfoReadProgress）', () {
      const book = Book(
        bookUrl: 'u1',
        name: '书',
        totalChapterNum: 1,
        durChapterIndex: 0,
        durChapterPos: 100,
      );
      expect(bookInfoReadProgressPercent(book), isNull);
    });

    test('读到中间章节时返回整数百分比', () {
      const book = Book(
        bookUrl: 'u1',
        name: '书',
        totalChapterNum: 11,
        durChapterIndex: 5,
        durChapterPos: 0,
      );
      expect(bookInfoReadProgressPercent(book), 50);
    });
  });
}
