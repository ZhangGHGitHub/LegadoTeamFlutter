// 书架 6 种排序 × 升降序（设置批6a-1）
//
// 对齐参考版 BookshelfRepository.sortBooks：阅读时间 / 更新时间 / 书名 /
// 手动 / 综合 / 作者；书名与作者用 pinyin（中文全拼 + 非中文 Unicode），
// 空串排最前，相同主键保持稳定顺序。
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_legado/src/models/book.dart';
import 'package:flutter_legado/src/utils/bookshelf_sort.dart';

void main() {
  List<String> namesOf(List<Book> books) => [for (final b in books) b.name];

  group('pinyin 比较', () {
    test('中文按全拼（无音调）', () {
      expect(bookshelfPinyinKey('张三'), 'zhangsan');
      expect(bookshelfPinyinKey('李四'), 'lisi');
      expect(bookshelfPinyinKey('阿'), 'a');
      expect(bookshelfCnCompare('阿', '张三'), lessThan(0));
      expect(bookshelfCnCompare('张三', '李四'), greaterThan(0));
    });

    test('英文大小写不敏感并回落 Unicode', () {
      expect(bookshelfPinyinKey('Apple'), 'apple');
      expect(bookshelfCnCompare('apple', 'Banana'), lessThan(0));
      expect(bookshelfCnCompare('Banana', 'cherry'), lessThan(0));
    });

    test('空串按最小键处理', () {
      expect(bookshelfCnCompare('', '阿'), lessThan(0));
      expect(bookshelfCnCompare('阿', ''), greaterThan(0));
    });
  });

  group('sortBookshelfBooks', () {
    final books = [
      const Book(
        name: '张三',
        author: '王五',
        bookUrl: 'u1',
        durChapterTime: 100,
        latestChapterTime: 500,
        order: 2,
      ),
      const Book(
        name: '李四',
        author: '张三',
        bookUrl: 'u2',
        durChapterTime: 300,
        latestChapterTime: 100,
        order: 0,
      ),
      const Book(
        name: '阿',
        author: '李四',
        bookUrl: 'u3',
        durChapterTime: 200,
        latestChapterTime: 300,
        order: 1,
      ),
      const Book(
        name: '',
        author: '',
        bookUrl: 'u4',
        durChapterTime: 200,
        latestChapterTime: 400,
        order: 3,
      ),
    ];

    test('阅读时间升序/降序（durChapterTime）', () {
      expect(
        namesOf(sortBookshelfBooks(books,
            sort: BookshelfSortMode.readTime,
            sortOrder: BookshelfSortOrder.ascending)),
        ['张三', '阿', '', '李四'],
      );
      expect(
        namesOf(sortBookshelfBooks(books,
            sort: BookshelfSortMode.readTime,
            sortOrder: BookshelfSortOrder.descending)),
        ['李四', '阿', '', '张三'],
      );
    });

    test('更新时间升序/降序（latestChapterTime）', () {
      expect(
        namesOf(sortBookshelfBooks(books,
            sort: BookshelfSortMode.updateTime,
            sortOrder: BookshelfSortOrder.ascending)),
        ['李四', '阿', '', '张三'],
      );
      expect(
        namesOf(sortBookshelfBooks(books,
            sort: BookshelfSortMode.updateTime,
            sortOrder: BookshelfSortOrder.descending)),
        ['张三', '', '阿', '李四'],
      );
    });

    test('书名升序/降序（中文拼音 + 空串最前）', () {
      expect(
        namesOf(sortBookshelfBooks(books,
            sort: BookshelfSortMode.name,
            sortOrder: BookshelfSortOrder.ascending)),
        ['', '阿', '李四', '张三'],
      );
      expect(
        namesOf(sortBookshelfBooks(books,
            sort: BookshelfSortMode.name,
            sortOrder: BookshelfSortOrder.descending)),
        ['张三', '李四', '阿', ''],
      );
    });

    test('手动排序升序/降序（order）', () {
      expect(
        namesOf(sortBookshelfBooks(books,
            sort: BookshelfSortMode.manual,
            sortOrder: BookshelfSortOrder.ascending)),
        ['李四', '阿', '张三', ''],
      );
      expect(
        namesOf(sortBookshelfBooks(books,
            sort: BookshelfSortMode.manual,
            sortOrder: BookshelfSortOrder.descending)),
        ['', '张三', '阿', '李四'],
      );
    });

    test('综合排序取 max(更新时间, 阅读时间)', () {
      // 综合值：u1=500, u2=300, u3=300, u4=400
      expect(
        namesOf(sortBookshelfBooks(books,
            sort: BookshelfSortMode.comprehensive,
            sortOrder: BookshelfSortOrder.ascending)),
        ['李四', '阿', '', '张三'],
      );
      expect(
        namesOf(sortBookshelfBooks(books,
            sort: BookshelfSortMode.comprehensive,
            sortOrder: BookshelfSortOrder.descending)),
        ['张三', '', '李四', '阿'],
      );
    });

    test('作者升序/降序（作者拼音，空作者最前）', () {
      expect(
        namesOf(sortBookshelfBooks(books,
            sort: BookshelfSortMode.author,
            sortOrder: BookshelfSortOrder.ascending)),
        ['', '阿', '张三', '李四'],
      );
      expect(
        namesOf(sortBookshelfBooks(books,
            sort: BookshelfSortMode.author,
            sortOrder: BookshelfSortOrder.descending)),
        ['李四', '张三', '阿', ''],
      );
    });

    test('相同主键保持原始顺序（稳定排序）', () {
      final sorted = sortBookshelfBooks(books,
          sort: BookshelfSortMode.readTime,
          sortOrder: BookshelfSortOrder.ascending);
      expect(namesOf(sorted).sublist(1, 3), ['阿', ''],
          reason: 'durChapterTime 同为 200 时保持输入顺序');
      final desc = sortBookshelfBooks(books,
          sort: BookshelfSortMode.readTime,
          sortOrder: BookshelfSortOrder.descending);
      expect(namesOf(desc).sublist(1, 3), ['阿', ''],
          reason: '降序的相同主键同样保持输入顺序');
    });

    test('入参列表不被修改', () {
      final copy = List<Book>.from(books);
      sortBookshelfBooks(books,
          sort: BookshelfSortMode.name,
          sortOrder: BookshelfSortOrder.ascending);
      expect(namesOf(books), namesOf(copy));
    });
  });

  test('拼音键每本书只生成一次（审查 P2 性能）', () {
    final list = [
      for (var i = 0; i < 200; i++)
        Book(
          bookUrl: 'p$i',
          name: '书${i % 50}',
          author: '作者${i % 20}',
        ),
    ];
    var nameCalls = 0;
    sortBookshelfBooks(
      list,
      sort: BookshelfSortMode.name,
      sortOrder: BookshelfSortOrder.ascending,
      pinyinKeyBuilder: (text) {
        nameCalls++;
        return bookshelfPinyinKey(text);
      },
    );
    expect(nameCalls, list.length, reason: '每本书只生成一次书名拼音键');

    var authorCalls = 0;
    sortBookshelfBooks(
      list,
      sort: BookshelfSortMode.author,
      sortOrder: BookshelfSortOrder.descending,
      pinyinKeyBuilder: (text) {
        authorCalls++;
        return bookshelfPinyinKey(text);
      },
    );
    expect(authorCalls, list.length, reason: '每本书只生成一次作者拼音键');
  });

  test('大列表（2000 本）书名排序耗时可接受', () {
    final list = [
      for (var i = 0; i < 2000; i++)
        Book(bookUrl: 'b$i', name: '测试书籍${2000 - i}'),
    ];
    final watch = Stopwatch()..start();
    final sorted = sortBookshelfBooks(
      list,
      sort: BookshelfSortMode.name,
      sortOrder: BookshelfSortOrder.ascending,
    );
    watch.stop();
    expect(sorted, hasLength(2000));
    expect(sorted.first.name, '测试书籍1');
    expect(watch.elapsed, lessThan(const Duration(seconds: 2)));
  });
}
