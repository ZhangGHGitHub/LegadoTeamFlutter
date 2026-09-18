// [P2-8 | 台账] 换源后详情刷新取址与详情合并回归单测
//
// 根因：换源事务只更新 origin/originName/tocUrl，bookUrl（稳定主键）保留
// 旧源地址；详情「进入刷新」路径此前用旧地址 + 当前书源规则抓页，字段解析
// 为空/退化值，写回把 tocUrl 写坏。
// 修复：Book 新增 originBookUrl（换源事务写入，Rust 侧 legacy-db v109 迁移；
// 空值回退 bookUrl，存量库行为不变），「抓取书籍页」取址统一走
// BookOpenUtils.bookFetchUrl；mergeWebInfo 的「刷新守卫」降级为纵深防御。
//
// 编写：全栈工程师子代理 ｜ 2026-09-17

import 'dart:convert';

import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/utils/book_open_utils.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Book buildBook({
    String bookUrl = 'https://old.example.com/book/1',
    String originBookUrl = '',
    String name = '旧书名',
    String author = '旧作者',
    String tocUrl = 'https://old.example.com/book/1/toc',
    String? coverUrl,
    String? intro,
    String? wordCount,
    String? latestChapterTitle,
    String? kind,
  }) {
    return Book(
      bookUrl: bookUrl,
      originBookUrl: originBookUrl,
      name: name,
      author: author,
      tocUrl: tocUrl,
      coverUrl: coverUrl,
      intro: intro,
      wordCount: wordCount,
      latestChapterTitle: latestChapterTitle,
      kind: kind,
    );
  }

  /// WebBookInfo 的 FFI 返回为 snake_case（name/author/cover_url/intro/
  /// word_count/last_chapter/toc_url/kind）
  String webInfoJson({
    String? name = '新书名',
    String? author = '新作者',
    String? tocUrl = 'https://new.example.com/book/9/chapters',
    String? coverUrl = 'https://new.example.com/cover/9.png',
    String? intro = '新简介',
    String? wordCount = '298.6万字',
    String? lastChapter = '第五百章',
    String? kind = '轻小说',
  }) {
    return jsonEncode({
      'name': name,
      'author': author,
      'cover_url': coverUrl,
      'intro': intro,
      'word_count': wordCount,
      'last_chapter': lastChapter,
      'toc_url': tocUrl,
      'kind': kind,
    });
  }

  group('BookOpenUtils.bookFetchUrl（书籍页取址）', () {
    test('originBookUrl 非空 → 优先当前书源详情页（换源后刷新取址正确）', () {
      final book = buildBook(originBookUrl: 'https://new.example.com/book/9');
      expect(
        BookOpenUtils.bookFetchUrl(book),
        'https://new.example.com/book/9',
      );
    });

    test('originBookUrl 为空 → 回退 bookUrl（未换源书籍/存量库行为不变）', () {
      final book = buildBook(); // originBookUrl 默认 ''
      expect(BookOpenUtils.bookFetchUrl(book), book.bookUrl);
    });
  });

  group('BookOpenUtils.mergeWebInfo refresh=true（U7 进入刷新）', () {
    test('刷新解析出书名 → 覆盖式合并照常执行（守卫不误伤）', () {
      final book = buildBook(
        originBookUrl: 'https://new.example.com/book/9',
        tocUrl: 'https://old.example.com/book/1/toc', // 旧值（换源前残留）
        intro: '旧简介',
      );
      final merged = BookOpenUtils.mergeWebInfo(
        book,
        webInfoJson(),
        refresh: true,
      );
      // 覆盖式合并：新值覆盖全部字段，含把换源前残留的 tocUrl 刷正
      expect(merged.name, '新书名');
      expect(merged.author, '新作者');
      expect(merged.tocUrl, 'https://new.example.com/book/9/chapters');
      expect(merged.coverUrl, 'https://new.example.com/cover/9.png');
      expect(merged.intro, '新简介');
      expect(merged.wordCount, '298.6万字');
      expect(merged.latestChapterTitle, '第五百章');
      expect(merged.kind, '轻小说');
      // 稳定主键与取址字段不被合并逻辑触碰
      expect(merged.bookUrl, book.bookUrl);
      expect(merged.originBookUrl, book.originBookUrl);
    });

    test('刷新未解析出书名 → 整次刷新跳过，字段原样保留（纵深防御守卫仍有效）',
        () {
      final book = buildBook(
        tocUrl: 'https://new.example.com/book/9/chapters',
        intro: '新简介',
      );
      final merged = BookOpenUtils.mergeWebInfo(
        book,
        webInfoJson(name: null), // 错页/未解析到书籍页
        refresh: true,
      );
      expect(merged.name, book.name);
      expect(merged.tocUrl, book.tocUrl);
      expect(merged.coverUrl, book.coverUrl);
      expect(merged.intro, book.intro);
      expect(merged.author, book.author);
      expect(merged.wordCount, book.wordCount);
      expect(merged.kind, book.kind);
    });
  });

  group('BookOpenUtils.mergeWebInfo refresh=false（首屏补全）', () {
    test('仅补全当前缺失字段（非空字段不被新值覆盖）', () {
      final book = buildBook(
        coverUrl: 'https://old.example.com/cover/1.png',
        intro: '旧简介',
        // tocUrl 用详情解析出的权威值优先（2026-08-15 既有语义）
        tocUrl: 'https://old.example.com/chapter-list',
      );
      final merged = BookOpenUtils.mergeWebInfo(
        book,
        webInfoJson(coverUrl: null, intro: null, kind: null),
      );
      expect(merged.coverUrl, 'https://old.example.com/cover/1.png');
      expect(merged.intro, '旧简介');
      expect(merged.tocUrl, 'https://new.example.com/book/9/chapters');
      expect(merged.name, '旧书名'); // 已有书名不被覆盖
      expect(merged.kind, isNull); // 空新值不覆盖
    });

    test('缺失字段被新值补全', () {
      final book = buildBook();
      final merged = BookOpenUtils.mergeWebInfo(book, webInfoJson());
      expect(merged.name, '旧书名');
      expect(merged.author, '旧作者'); // 非空保留
      expect(merged.coverUrl, 'https://new.example.com/cover/9.png');
      expect(merged.intro, '新简介');
      expect(merged.wordCount, '298.6万字');
      expect(merged.latestChapterTitle, '第五百章');
      expect(merged.kind, '轻小说');
      expect(merged.tocUrl, 'https://new.example.com/book/9/chapters');
    });
  });

  group('Book.originBookUrl 序列化', () {
    test('toJson 使用 originBookUrl 键；旧版 JSON 缺字段时默认空串', () {
      final book = buildBook(originBookUrl: 'https://new.example.com/book/9');
      expect(book.toJson()['originBookUrl'], 'https://new.example.com/book/9');

      final legacy = Book.fromJson(
        const <String, dynamic>{'bookUrl': 'https://x.example.com/b/1'},
      );
      expect(legacy.originBookUrl, '');
      // 回退语义：缺字段书籍取址即 bookUrl
      expect(BookOpenUtils.bookFetchUrl(legacy), legacy.bookUrl);
    });
  });
}
