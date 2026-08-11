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

    test('必应漫画类 type=0 抽图规则提升为 image → comic 路由', () {
      const source = BookSource(
        bookSourceUrl: 'https://www.biyingmh.com',
        bookSourceName: '必应漫画',
        bookSourceType: 0,
        ruleContent: ContentRule(
          content: '.img@img@html',
          imageStyle: 'FULL',
        ),
      );
      expect(BookOpenUtils.looksLikeImageHtmlContentRule('.img@img@html'), isTrue);
      expect(BookOpenUtils.isImageHtmlContentSource(source), isTrue);
      final bits = BookOpenUtils.promoteImageContentSource(
        BookOpenUtils.typeBitsForSource(0),
        source,
      );
      expect(bits, BookType.image);
      expect(BookOpenUtils.routeForTypeBits(bits), AppRoutes.readerComic);
    });

    test('长 JS 小说正文规则不误提升为漫画', () {
      final longJs = 'a' * 200 + '@html img';
      expect(BookOpenUtils.looksLikeImageHtmlContentRule(longJs), isFalse);
      const novel = BookSource(
        bookSourceUrl: 'https://example.com',
        bookSourceName: '小说',
        bookSourceType: 0,
        ruleContent: ContentRule(
          content: 'id.content@html',
          imageStyle: 'FULL',
        ),
      );
      expect(BookOpenUtils.isImageHtmlContentSource(novel), isFalse);
    });

    test('非凡等 type=0 MacCMS 影视频源 → video，不被抽图启发式升漫画', () {
      const ffzy = BookSource(
        bookSourceUrl: 'http://23.225.142.42',
        bookSourceName: '非凡资源网-www.ffzy.tv',
        bookSourceGroup: '影视频源',
        bookSourceType: 0,
        searchUrl: '/api.php/provide/vod/?ac=detail&wd={{key}}&pg={{page}}',
        ruleToc: TocRule(
          chapterList:
              r'@js:var data=JSON.parse(src);var vod=data.list[0];var playUrl=vod.vod_play_url;',
          chapterName: 'text',
          chapterUrl: 'href',
        ),
        ruleContent: ContentRule(
          content:
              r'''@js:java.startBrowser(baseUrl, book.name);result = baseUrl;''',
        ),
      );
      expect(BookOpenUtils.looksLikeVideoSource(ffzy), isTrue);
      expect(BookOpenUtils.isImageHtmlContentSource(ffzy), isFalse);
      // 旧库误标 image / text 也应被纠正为 video
      expect(
        BookOpenUtils.resolveTypeBits(BookType.image, ffzy),
        BookType.video,
      );
      expect(
        BookOpenUtils.resolveTypeBits(BookType.text, ffzy),
        BookType.video,
      );
      expect(
        BookOpenUtils.routeForTypeBits(
          BookOpenUtils.resolveTypeBits(0, ffzy),
        ),
        AppRoutes.video,
      );
    });

    test('红牛等 type=2 误标图片 + 影视频源 + m3u8 → video，不进 comic', () {
      // 设备导出：bookSourceType=2，group=影视频源，正文规则抽 m3u8
      const hongniu = BookSource(
        bookSourceUrl: 'https://hongniuziyuan.com',
        bookSourceName: '红牛资源',
        bookSourceGroup: '影视频源',
        bookSourceType: 2,
        searchUrl:
            'https://hongniuziyuan.com/index.php/vod/search.html?wd={{key}}&submit=search',
        ruleToc: TocRule(
          chapterList: r'@css:.vodplayinfo>div>div>ul>li',
          chapterName: r'@css:a@text##(.+)\$(.+)##$1',
          chapterUrl: r'@css:a@text##(.+)\$(.+)##$2',
        ),
        ruleContent: ContentRule(
          content: r'''<js>
var url="";
if(/.*\.m3u8.*/.test(baseUrl)){url=baseUrl}
else{
jm=java.htmlFormat(result).match(/.*(\{.*\}).*/)[1];
url=baseUrl.match(/(.*)\/share.*/)[1]+jm.match(/.*url\":\"(.*)\".*/)[1];
}
url
</js>''',
        ),
      );
      expect(BookOpenUtils.looksLikeVideoSource(hongniu), isTrue);
      expect(BookOpenUtils.isImageHtmlContentSource(hongniu), isFalse);
      // 关键：不得因 type=2 直接走 typeBitsForSource → image/comic
      expect(
        BookOpenUtils.resolveTypeBits(BookType.image, hongniu),
        BookType.video,
      );
      expect(
        BookOpenUtils.routeForTypeBits(
          BookOpenUtils.resolveTypeBits(BookType.image, hongniu),
        ),
        AppRoutes.video,
      );
    });

    test('U酷 type=2 影视频源 + m3u8 → video', () {
      const uku = BookSource(
        bookSourceUrl: 'https://ukuzy.com/',
        bookSourceName: 'U酷资源',
        bookSourceGroup: '影视频源',
        bookSourceType: 2,
        ruleContent: ContentRule(
          content: r'@js:result=/.*\.m3u8.*/.test(baseUrl)?baseUrl:"";',
        ),
      );
      expect(BookOpenUtils.resolveTypeBits(0, uku), BookType.video);
    });

    test('显式 bookSourceType=4 优先于书籍旧 image 位', () {
      const qmao = BookSource(
        bookSourceUrl: 'https://www.qmao.net',
        bookSourceName: '伪七猫影视',
        bookSourceType: 4,
        ruleContent: ContentRule(
          content: r'@js:result=data.url',
          sourceRegex: r'.*\.(m3u8|mp4|flv).*',
        ),
      );
      expect(
        BookOpenUtils.resolveTypeBits(BookType.image | BookType.text, qmao),
        BookType.video,
      );
    });

    test('必应漫画抽图提升仍生效（非视频）', () {
      const source = BookSource(
        bookSourceUrl: 'https://www.biyingmh.com',
        bookSourceName: '必应漫画',
        bookSourceType: 0,
        ruleContent: ContentRule(
          content: '.img@img@html',
          imageStyle: 'FULL',
        ),
      );
      expect(
        BookOpenUtils.resolveTypeBits(0, source),
        BookType.image,
      );
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

    test('必应漫画样例：纯 img HTML 判定为图片主导正文', () {
      const html = '''
<img src="https://www.jjmhw6.top/static/upload/book/714/30286/1135571.jpg">
<img src="https://www.jjmhw6.top/static/upload/book/714/30286/1135572.jpg">
<img src="https://www.jjmhw6.top/static/upload/book/714/30286/1135573.jpg">
''';
      expect(isImageDominantContent(html), isTrue);
      expect(parseComicImageUrls(html), hasLength(3));
    });

    test('图文混排不判定为图片主导', () {
      const html =
          '<p>这是一段足够长的小说正文，用来避免被误判成纯图片章节。</p><img src="https://cdn.example.com/a.jpg">';
      expect(isImageDominantContent(html), isFalse);
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

    test('m3u8/视频 URL 不判定为图片', () {
      expect(
        looksLikeImageUrl(
          'https://vip.ffzy-plays.com/2025/49109/index.m3u8',
        ),
        isFalse,
      );
      expect(isImageDominantContent('https://cdn.example/v.m3u8'), isFalse);
    });
  });

  group('looksLikeImageBytes 魔数', () {
    test('识别 JPEG/PNG/GIF/WEBP，拒绝密文', () {
      expect(looksLikeImageBytes([0xFF, 0xD8, 0xFF, 0xE0]), isTrue);
      expect(looksLikeImageBytes([0x89, 0x50, 0x4E, 0x47]), isTrue);
      expect(looksLikeImageBytes([0x47, 0x49, 0x46, 0x38]), isTrue);
      expect(
        looksLikeImageBytes([
          0x52, 0x49, 0x46, 0x46, 0, 0, 0, 0, 0x57, 0x45, 0x42, 0x50,
        ]),
        isTrue,
      );
      expect(looksLikeImageBytes([0x01, 0x02, 0x03, 0x04]), isFalse);
      expect(looksLikeImageBytes([]), isFalse);
    });
  });
}
