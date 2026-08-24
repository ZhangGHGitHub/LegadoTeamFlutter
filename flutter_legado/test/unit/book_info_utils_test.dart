import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/utils/book_info_utils.dart';

void main() {
  group('applyBookInfoCanUpdateToggle', () {
    const baseBook = Book(
      bookUrl: 'u1',
      name: '书',
      canUpdate: true,
      bookType: BookType.text | BookType.updateError,
    );

    test('在架关闭自动更新时清除 updateError 位（对齐 menu_can_update）', () {
      final result =
          applyBookInfoCanUpdateToggle(baseBook, inBookshelf: true);
      expect(result.canUpdate, isFalse);
      expect(result.bookType & BookType.updateError, 0);
      expect(result.bookType & BookType.text, BookType.text);
    });

    test('在架开启自动更新时保留 updateError 位', () {
      const book = Book(
        bookUrl: 'u1',
        name: '书',
        canUpdate: false,
        bookType: BookType.text | BookType.updateError,
      );
      final result = applyBookInfoCanUpdateToggle(book, inBookshelf: true);
      expect(result.canUpdate, isTrue);
      expect(result.bookType & BookType.updateError, BookType.updateError);
    });

    test('未在架关闭自动更新时不清除 updateError 位', () {
      final result =
          applyBookInfoCanUpdateToggle(baseBook, inBookshelf: false);
      expect(result.canUpdate, isFalse);
      expect(result.bookType & BookType.updateError, BookType.updateError);
    });
  });
}
