import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/routes.dart';
import 'package:flutter_legado/src/utils/book_open_utils.dart';
import 'package:flutter_legado/src/utils/comic_image_utils.dart';

void main() {
  group('BookOpenUtils 类型分流（对齐 startActivityForBook）', () {
    test('typeBitsForSource 映射书源类型', () {
      expect(BookOpenUtils.typeBitsForSource(0), BookType.text);
      expect(BookOpenUtils.typeBitsForSource(1), BookType.audio);
      expect(BookOpenUtils.typeBitsForSource(2), BookType.image);
      expect(BookOpenUtils.typeBitsForSource(3),
          BookType.text | BookType.webFile);
      expect(BookOpenUtils.typeBitsForSource(4), BookType.video);
    });

    test('routeForTypeBits 按位标记选路由', () {
      expect(BookOpenUtils.routeForTypeBits(BookType.video), AppRoutes.video);
      expect(BookOpenUtils.routeForTypeBits(BookType.audio), AppRoutes.audio);
      expect(
          BookOpenUtils.routeForTypeBits(BookType.image), AppRoutes.readerComic);
      expect(BookOpenUtils.routeForTypeBits(BookType.text), AppRoutes.reader);
      expect(BookOpenUtils.routeForTypeBits(0), AppRoutes.reader);
    });

    test('argumentsForRoute 漫画传 bookUrl，音视频传 Book', () {
      const book = Book(
        bookUrl: 'https://ex.com/b',
        name: '测',
        bookType: BookType.image,
      );
      expect(
        BookOpenUtils.argumentsForRoute(AppRoutes.readerComic, book),
        book.bookUrl,
      );
      expect(
        BookOpenUtils.argumentsForRoute(AppRoutes.video, book),
        same(book),
      );
      expect(
        BookOpenUtils.argumentsForRoute(AppRoutes.reader, book),
        isNull,
      );
    });
  });

  group('parseComicImageUrls 复合 URL', () {
    test('双引号 src 含 JSON headers 完整抽出（不截断在第一个引号）', () {
      const html =
          r'''<img src="https://cdn.example.com/a.webp,{"headers":{"Referer":"https://site.com/"}}">''';
      final urls = parseComicImageUrls(html);
      expect(urls, hasLength(1));
      expect(
        urls.first,
        r'https://cdn.example.com/a.webp,{"headers":{"Referer":"https://site.com/"}}',
      );
      expect(urls.first, isNot(contains(RegExp(r',\s*\{$'))));
      expect(urls.first.endsWith('}'), isTrue);
    });

    test('单引号复合 URL 完整抽出', () {
      const html =
          r'''<img src='https://cdn.example.com/b.jpg,{"headers":{"User-Agent":"X"}}'>''';
      final urls = parseComicImageUrls(html);
      expect(urls, hasLength(1));
      expect(urls.first, startsWith('https://cdn.example.com/b.jpg,{'));
      expect(urls.first, contains('"User-Agent"'));
    });

    test('普通 src 不受影响', () {
      const html = '<img src="https://cdn.example.com/plain.png">';
      expect(parseComicImageUrls(html), ['https://cdn.example.com/plain.png']);
    });

    test('旧截断正则会失败的样例：复合 URL 不被切成 url,{', () {
      const truncatedBad = 'https://cdn.example.com/a.webp,{';
      const html =
          r'''<p><img src="https://cdn.example.com/a.webp,{"headers":{"Referer":"https://x/"}}"></p>''';
      final urls = parseComicImageUrls(html);
      expect(urls.first, isNot(equals(truncatedBad)));
      expect(isCompositeImageUrl(urls.first), isTrue);
    });

    test('行解析兜底识别复合图片 URL', () {
      const line =
          r'https://cdn.example.com/pic/1.webp,{"headers":{"Referer":"https://x/"}}';
      expect(looksLikeImageUrl(line), isTrue);
      expect(parseComicImageUrls(line), [line]);
    });
  });
}
