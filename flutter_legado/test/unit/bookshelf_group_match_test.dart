// 书架分组匹配（2026-11-06 设备修复）
//
// 新分组 group_id = 2^n，按 books.group 位掩码匹配；存量时间戳/任意 ID
// 按 exact 兼容；旧书籍 group 值（> 位掩码上限）只做 exact，避免低位
// 误命中新分组。另覆盖「按分组显示」组名 key。
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/providers/bookshelf/bookshelf_state.dart';

void main() {
  const all = BookGroup(groupId: BookGroupId.all, groupName: '全部');
  const sciFi = BookGroup(groupId: 1, groupName: '科幻', order: 1);
  const fantasy = BookGroup(groupId: 2, groupName: '玄幻', order: 2);
  const legacyId = 1793904884364;
  const legacy = BookGroup(groupId: legacyId, groupName: '旧组', order: 3);

  group('isPowerOfTwoGroupId', () {
    test('2 的幂为 true，0/负数/非 2 的幂为 false', () {
      expect(isPowerOfTwoGroupId(1), isTrue);
      expect(isPowerOfTwoGroupId(2), isTrue);
      expect(isPowerOfTwoGroupId(4), isTrue);
      expect(isPowerOfTwoGroupId(1 << 30), isTrue);
      expect(isPowerOfTwoGroupId(3), isFalse);
      expect(isPowerOfTwoGroupId(0), isFalse);
      expect(isPowerOfTwoGroupId(-1), isFalse);
      expect(isPowerOfTwoGroupId(legacyId), isFalse);
    });
  });

  group('bookBelongsToCustomGroup 混合语义', () {
    test('2^n 组按位掩码匹配多组', () {
      const book = Book(bookUrl: 'u1', group: 1 | 4);
      expect(bookBelongsToCustomGroup(book, 1), isTrue);
      expect(bookBelongsToCustomGroup(book, 4), isTrue);
      expect(bookBelongsToCustomGroup(book, 2), isFalse);
      expect(bookBelongsToCustomGroup(book, 8), isFalse);
    });

    test('旧时间戳组只 exact 匹配自己', () {
      const book = Book(bookUrl: 'u2', group: legacyId);
      expect(bookBelongsToCustomGroup(book, legacyId), isTrue);
      // 旧值低位可能包含 2^n 位，但旧书籍只做 exact，不应命中新组
      expect(bookBelongsToCustomGroup(book, 1), isFalse);
      expect(bookBelongsToCustomGroup(book, 4), isFalse);
      expect(bookBelongsToCustomGroup(book, legacyId + 1), isFalse);
    });

    test('0/负数/超上限边界', () {
      const zero = Book(bookUrl: 'u3', group: 0);
      const negative = Book(bookUrl: 'u4', group: -1);
      expect(bookBelongsToCustomGroup(zero, 1), isFalse);
      expect(bookBelongsToCustomGroup(zero, 0), isFalse);
      expect(bookBelongsToCustomGroup(zero, -1), isFalse);
      expect(bookBelongsToCustomGroup(negative, 1), isFalse);
      expect(bookBelongsToCustomGroup(negative, -99), isFalse);
      // 非 2 的幂 groupId（含 >上限）走 exact
      expect(bookBelongsToCustomGroup(zero, 99), isFalse);
      expect(
        bookBelongsToCustomGroup(const Book(bookUrl: 'u5', group: 99), 99),
        isTrue,
      );
    });
  });

  group('分组分配/移除位运算', () {
    test('2^n 组分配保留其它位，移除只清对应位', () {
      const book = Book(bookUrl: 'a', group: 1 | 4);
      expect(nextGroupMaskOnAssign(book, 2), 1 | 2 | 4);
      expect(nextGroupMaskOnRemove(book, 4), 1);
      expect(nextGroupMaskOnRemove(book, 8), 1 | 4);
    });

    test('旧时间戳书籍分配新组时改为新组值，移除旧组清 0', () {
      const legacyBook = Book(bookUrl: 'b', group: legacyId);
      expect(nextGroupMaskOnAssign(legacyBook, 1), 1);
      expect(nextGroupMaskOnRemove(legacyBook, legacyId), 0);
      expect(nextGroupMaskOnRemove(legacyBook, 1), legacyId);
    });

    test('非正 groupId 不改值', () {
      const book = Book(bookUrl: 'c', group: 3);
      expect(nextGroupMaskOnAssign(book, 0), 3);
      expect(nextGroupMaskOnRemove(book, -1), 3);
    });
  });

  group('booksInGroup 过滤', () {
    final state = BookshelfState(
      groups: const [all, sciFi, fantasy, legacy],
      selectedGroupIndex: 1,
      books: const [
        Book(bookUrl: 'b1', name: '位掩码书', group: 1 | 2),
        Book(bookUrl: 'b2', name: '旧时间戳书', group: legacyId),
        Book(bookUrl: 'b3', name: '未分组', group: 0),
      ],
    );

    test('2^n 组位掩码命中', () {
      expect(state.booksInGroup(sciFi).map((b) => b.bookUrl), ['b1']);
      expect(state.booksInGroup(fantasy).map((b) => b.bookUrl), ['b1']);
    });

    test('旧时间戳组 exact 只命中自身', () {
      expect(state.booksInGroup(legacy).map((b) => b.bookUrl), ['b2']);
      // 旧书低位即使包含 sciFi 位，也不会因时间戳组而串组
      expect(state.booksInGroup(sciFi).any((b) => b.bookUrl == 'b2'), isFalse);
    });

    test('0/未知负数自定义组返回空', () {
      expect(
        state.booksInGroup(const BookGroup(groupId: 0, groupName: '零')),
        isEmpty,
      );
      expect(
        state.booksInGroup(const BookGroup(groupId: -99, groupName: '未知')),
        isEmpty,
      );
    });
  });

  group('bookGroupNames（管理页/详情页组名）', () {
    const newGroup = BookGroup(groupId: 1, groupName: '新组1', order: 1);
    const legacyBook = Book(bookUrl: 'n1', group: legacyId);
    const bitBook = Book(bookUrl: 'n2', group: 3);

    test('旧时间戳书不会命中新 2^n 组，只显示真实旧组名', () {
      expect(
        bookGroupNames(legacyBook, const [newGroup, legacy]),
        ['旧组'],
      );
      expect(bookGroupNames(legacyBook, const [newGroup]), isEmpty);
    });

    test('2^n 多组书显示多个组名', () {
      expect(
        bookGroupNames(bitBook, const [sciFi, fantasy]),
        ['科幻', '玄幻'],
      );
    });
  });

  group('按分组显示标题使用组名', () {
    final state = BookshelfState(
      groups: const [all, sciFi, fantasy, legacy],
      groupMode: GroupMode.byGroup,
      books: const [
        Book(bookUrl: 'm1', name: '多组', group: 3),
        Book(bookUrl: 'm2', name: '旧组书', group: legacyId),
        Book(bookUrl: 'm3', name: '无名字组', group: 64),
        Book(bookUrl: 'm4', name: '未分组', group: 0),
      ],
    );

    test('位掩码多组显示「组名、组名」', () {
      final grouped = state.groupedBooksOf(state.books);
      expect(grouped.containsKey('科幻、玄幻'), isTrue);
    });

    test('旧时间戳组显示组名，找不到组名回落「分组」', () {
      final grouped = state.groupedBooksOf(state.books);
      expect(grouped.containsKey('旧组'), isTrue);
      expect(grouped.containsKey('分组'), isTrue);
      expect(grouped.keys.any((k) => RegExp(r'^\d+$').hasMatch(k)), isFalse);
    });

    test('未分组回落「默认」', () {
      final grouped = state.groupedBooksOf(state.books);
      expect(grouped.containsKey('默认'), isTrue);
    });
  });
}
