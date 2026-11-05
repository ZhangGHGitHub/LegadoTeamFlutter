// 书架排序（设置批6a-1）
//
// 对齐参考版 `BookshelfRepository.sortBooks`（`BookshelfRepository.kt:9-50`）：
// 6 种模式 + 升降序，在 Dart 列表层完成（不改 Rust/SQL）。
// 书名/作者使用 `pinyin` 纯 Dart 依赖：中文按不带声调的全拼比较，
// 非中文字符回落 Unicode（原字符小写后比较）；空串按最小键处理。
//
// 组内排序覆盖（`BookGroup.bookSort`）另立项，本批只读全局设置。
//
// 编写：全栈工程师（设置批6a-1） ｜ 2026-11-06
import 'dart:math' as math;

import 'package:pinyin/pinyin.dart';

import '../models/book.dart';

/// 排序模式（与参考版 PreferKey.bookshelfSort 取值一致）
class BookshelfSortMode {
  static const readTime = 0;
  static const updateTime = 1;
  static const name = 2;
  static const manual = 3;
  static const comprehensive = 4;
  static const author = 5;

  static const labels = <String>[
    '按阅读时间',
    '按更新时间',
    '按书名',
    '手动排序',
    '综合排序',
    '按作者',
  ];
}

/// 排序方向（0 升序 / 1 降序，默认降序）
class BookshelfSortOrder {
  static const ascending = 0;
  static const descending = 1;

  static const labels = <String>['升序', '降序'];
}

/// 中文/英文混合比较键（中文 → 无音调全拼，其它 → 原字符小写）
String bookshelfPinyinKey(String text) {
  if (text.isEmpty) return '';
  final buffer = StringBuffer();
  for (final rune in text.runes) {
    final char = String.fromCharCode(rune);
    if (ChineseHelper.isChinese(char)) {
      final pinyin = PinyinHelper.convertToPinyinArray(
        char,
        PinyinFormat.WITHOUT_TONE,
      );
      if (pinyin.isNotEmpty) {
        buffer.write(pinyin.first.toLowerCase());
        continue;
      }
    }
    buffer.write(char.toLowerCase());
  }
  return buffer.toString();
}

/// 中英文混合比较（对齐 Kotlin `String.cnCompare` 的排序意图）
///
/// 拼音键相同时回落原始 Unicode 比较，保证确定性；空串自然排在最前
/// （升序）。
int bookshelfCnCompare(String a, String b) {
  final byPinyin = bookshelfPinyinKey(a).compareTo(bookshelfPinyinKey(b));
  if (byPinyin != 0) return byPinyin;
  return a.compareTo(b);
}

/// 按设置排序书籍列表（返回新列表，不修改入参）
///
/// [sortOrder] 0 = 升序，1 = 降序；相同主键按原始顺序稳定排列
/// （Dart `List.sort` 不稳定，显式用原始下标兜底，语义对齐 Kotlin
/// 稳定排序）。
/// 拼音键生成器（测试可注入计数包装，生产默认 [bookshelfPinyinKey]）
typedef BookshelfPinyinKeyBuilder = String Function(String text);

List<Book> sortBookshelfBooks(
  List<Book> books, {
  required int sort,
  required int sortOrder,
  BookshelfPinyinKeyBuilder pinyinKeyBuilder = bookshelfPinyinKey,
}) {
  final indexed = <({int index, Book book})>[
    for (var i = 0; i < books.length; i++) (index: i, book: books[i]),
  ];

  int compareValues(int a, int b) => a.compareTo(b);
  final descending = sortOrder == BookshelfSortOrder.descending;

  // [审查 P2] 书名/作者模式先一次性生成 (原始下标 → 拼音键) 装饰表，
  // 排序比较只做字符串 compareTo；避免每次比较都重复转换整串拼音。
  if (sort == BookshelfSortMode.name || sort == BookshelfSortMode.author) {
    final keys = <int, String>{
      for (final item in indexed)
        item.index: pinyinKeyBuilder(
          sort == BookshelfSortMode.name ? item.book.name : item.book.author,
        ),
    };
    indexed.sort((x, y) {
      final keyX = keys[x.index]!;
      final keyY = keys[y.index]!;
      var byPrimary = keyX.compareTo(keyY);
      if (byPrimary == 0) {
        // 拼音键相同回落原始 Unicode，保证确定性
        byPrimary = sort == BookshelfSortMode.name
            ? x.book.name.compareTo(y.book.name)
            : x.book.author.compareTo(y.book.author);
      }
      if (byPrimary != 0) return descending ? -byPrimary : byPrimary;
      return x.index.compareTo(y.index);
    });
    return [for (final item in indexed) item.book];
  }

  int Function(Book a, Book b) primary;
  switch (sort) {
    case BookshelfSortMode.updateTime:
      primary = (a, b) => compareValues(a.latestChapterTime, b.latestChapterTime);
    case BookshelfSortMode.manual:
      primary = (a, b) => compareValues(a.order, b.order);
    case BookshelfSortMode.comprehensive:
      primary = (a, b) => compareValues(
            math.max(a.latestChapterTime, a.durChapterTime),
            math.max(b.latestChapterTime, b.durChapterTime),
          );
    case BookshelfSortMode.readTime:
    default:
      primary = (a, b) => compareValues(a.durChapterTime, b.durChapterTime);
  }

  indexed.sort((x, y) {
    final byPrimary = primary(x.book, y.book);
    if (byPrimary != 0) return descending ? -byPrimary : byPrimary;
    return x.index.compareTo(y.index);
  });
  return [for (final item in indexed) item.book];
}
