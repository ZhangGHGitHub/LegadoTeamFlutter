// 书架内搜索过滤（搜索直达）派生过滤单测
//
// 对齐参考版 BookshelfViewModel.matchesSearchKey：书名/作者/来源名/分类/
// 自定义标签任一包含关键词即命中（大小写不敏感）；过滤态可先剔除私密
// 未授权书（避免「能否搜到书名」泄露私密内容）。
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/providers/bookshelf/bookshelf_state.dart';

void main() {
  BookshelfState shelf(
    List<Book> books, {
    bool filterMode = true,
    String q = '',
  }) {
    return BookshelfState(
      books: books,
      groups: const [
        BookGroup(groupId: BookGroupId.all, groupName: '全部', order: -10),
      ],
      selectedGroupIndex: 0,
      isFilterMode: filterMode,
      filterQuery: q,
    );
  }

  const books = [
    Book(bookUrl: 'u1', name: '斗破苍穹', author: '天蚕土豆', originName: '起点'),
    Book(bookUrl: 'u2', name: 'Perfect World', author: '辰东', kind: '玄幻'),
    Book(bookUrl: 'u3', name: '遮天', author: '辰东', customTag: '已读'),
  ];

  test('未开过滤或关键词为空：原样返回全部书籍', () {
    expect(shelf(books, filterMode: false, q: '斗破').filterBooks(books), books);
    expect(shelf(books, q: '   ').filterBooks(books), books);
    expect(shelf(books, filterMode: false, q: '遮天').isFiltering, isFalse);
  });

  test('匹配书名（大小写不敏感）', () {
    final state = shelf(books, q: '斗破');
    expect(state.isFiltering, isTrue);
    expect(state.filterBooks(books).map((b) => b.bookUrl), ['u1']);

    // 英文书名忽略大小写
    expect(
      shelf(books, q: 'perfect').filterBooks(books).map((b) => b.bookUrl),
      ['u2'],
    );
  });

  test('匹配作者', () {
    final result = shelf(books, q: '辰东').filterBooks(books);
    expect(result.map((b) => b.bookUrl), ['u2', 'u3']);
  });

  test('匹配来源名/分类/自定义标签（对齐参考版五字段口径）', () {
    expect(shelf(books, q: '起点').filterBooks(books).single.bookUrl, 'u1');
    expect(shelf(books, q: '玄幻').filterBooks(books).single.bookUrl, 'u2');
    expect(shelf(books, q: '已读').filterBooks(books).single.bookUrl, 'u3');
  });

  test('无匹配返回空列表（UI 据此呈现空态）', () {
    expect(shelf(books, q: '不存在的书').filterBooks(books), isEmpty);
  });

  test('清除关键词/退出过滤后恢复全部', () {
    final filtered = shelf(books, q: '遮天');
    expect(filtered.filterBooks(books), hasLength(1));
    // 清除关键词（过滤模式仍开）→ 恢复
    final cleared = filtered.copyWith(filterQuery: '');
    expect(cleared.filterBooks(books), books);
    // 退出过滤模式 → filterQuery 语义上不再生效
    final exited = filtered.copyWith(isFilterMode: false, filterQuery: '');
    expect(exited.filterBooks(books), books);
  });

  test('exclude 回调先剔除私密未授权书（命中关键词也不返回）', () {
    final state = shelf(books, q: '辰东');
    final result = state.filterBooks(
      books,
      exclude: (book) => book.bookUrl == 'u3',
    );
    expect(result.map((b) => b.bookUrl), ['u2']);
  });
}
