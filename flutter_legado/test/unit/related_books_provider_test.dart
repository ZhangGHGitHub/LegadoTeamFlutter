// 相关书 Provider 单元测试（R42 阶段 1，契约 §2.55）
//
// 覆盖 JSON 解析与降级的边界：Rust `WebSearchResult` 是 snake_case 序列化，
// 与 `SearchBook.fromJson` 的 camelCase 键不一致，必须显式归一化，否则
// bookUrl/origin/coverUrl 会丢（详情页无法联网补全）。
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_legado/src/providers/book_info/related_books_provider.dart';

void main() {
  group('parseRelatedBooksJson', () {
    test('解析两个模块（snake_case books）', () {
      final raw = jsonEncode({
        'modules': [
          {
            'key': 'similar',
            'title': '相似推荐',
            'url': '/related/similar',
            'resolvedUrl': 'https://src.com/related/similar',
            'books': [
              {
                'name': '书甲',
                'author': '作者甲',
                'book_url': 'https://src.com/book/a',
                'cover_url': 'https://img.com/a.jpg',
                'source_url': 'https://src.com',
                'latest_chapter': '第一百章',
                'word_count': '12.00万字',
                'type': 0,
              },
            ],
          },
          {
            'key': 'author',
            'title': '作者其他作品',
            'url': '/related/author',
            'resolvedUrl': 'https://src.com/related/author',
            'books': [
              {
                'name': '书丙',
                'author': '作者丙',
                'book_url': 'https://src.com/book/c',
                'cover_url': null,
                'source_url': 'https://src.com',
              },
            ],
          },
        ],
      });

      final modules = parseRelatedBooksJson(raw);
      expect(modules, hasLength(2));
      expect(modules[0].key, 'similar');
      expect(modules[0].title, '相似推荐');
      expect(modules[0].resolvedUrl, 'https://src.com/related/similar');
      final first = modules[0].books.single;
      expect(first.name, '书甲');
      expect(first.author, '作者甲');
      expect(first.bookUrl, 'https://src.com/book/a');
      expect(first.origin, 'https://src.com');
      expect(first.coverUrl, 'https://img.com/a.jpg');
      expect(first.latestChapterTitle, '第一百章');
      expect(first.wordCount, '12.00万字');
      expect(modules[1].books.single.name, '书丙');
      expect(modules[1].books.single.coverUrl, isNull);
    });

    test('camelCase books 同样兼容（防御上游序列化变化）', () {
      final raw = jsonEncode({
        'modules': [
          {
            'key': 'k',
            'title': 't',
            'url': 'u',
            'resolvedUrl': 'ru',
            'books': [
              {
                'name': '书乙',
                'author': '作者乙',
                'bookUrl': 'https://src.com/book/b',
                'coverUrl': 'https://img.com/b.jpg',
                'origin': 'https://src.com',
              },
            ],
          },
        ],
      });

      final modules = parseRelatedBooksJson(raw);
      expect(modules, hasLength(1));
      final book = modules.single.books.single;
      expect(book.bookUrl, 'https://src.com/book/b');
      expect(book.coverUrl, 'https://img.com/b.jpg');
      expect(book.origin, 'https://src.com');
    });

    test('相对书址按 source_url 补齐为绝对地址', () {
      final raw = jsonEncode({
        'modules': [
          {
            'title': 't',
            'books': [
              {
                'name': '书甲',
                'author': '作者甲',
                'book_url': '/book/a',
                'cover_url': '/img/a.jpg',
                'source_url': 'https://src.com',
              },
            ],
          },
        ],
      });

      final book = parseRelatedBooksJson(raw).single.books.single;
      expect(book.bookUrl, 'https://src.com/book/a');
      expect(book.coverUrl, 'https://src.com/img/a.jpg');
    });

    test('无书的模块被跳过（对齐参考版 takeIf { isNotEmpty }）', () {
      final raw = jsonEncode({
        'modules': [
          {'key': 'empty', 'title': '空模块', 'books': <dynamic>[]},
          {
            'key': 'ok',
            'title': '有效模块',
            'books': [
              {
                'name': '书甲',
                'author': '作者甲',
                'book_url': 'https://src.com/book/a',
                'source_url': 'https://src.com',
              },
            ],
          },
        ],
      });

      final modules = parseRelatedBooksJson(raw);
      expect(modules, hasLength(1));
      expect(modules.single.key, 'ok');
    });

    test('单本无效条目被跳过，同模块其余书保留', () {
      final raw = jsonEncode({
        'modules': [
          {
            'title': 't',
            'books': [
              {'name': '', 'author': '无书名', 'book_url': 'https://s/b'},
              {'name': '无书址', 'author': '作者', 'book_url': ''},
              {
                'name': '书甲',
                'author': '作者甲',
                'book_url': 'https://src.com/book/a',
                'source_url': 'https://src.com',
              },
            ],
          },
        ],
      });

      final books = parseRelatedBooksJson(raw).single.books;
      expect(books, hasLength(1));
      expect(books.single.name, '书甲');
    });

    test('空数组 / 非法 JSON / 结构不符一律返回空列表（不抛错）', () {
      expect(parseRelatedBooksJson('{"modules":[]}'), isEmpty);
      expect(parseRelatedBooksJson(''), isEmpty);
      expect(parseRelatedBooksJson('not json'), isEmpty);
      expect(parseRelatedBooksJson('[]'), isEmpty);
      expect(parseRelatedBooksJson('{"modules":"oops"}'), isEmpty);
      expect(parseRelatedBooksJson('{"modules":[1,2,3]}'), isEmpty);
    });
  });
}
