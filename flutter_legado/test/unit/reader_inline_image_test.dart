// 批16：正文行内图片混排纯逻辑单测 — 全栈工程师
//
// 覆盖：
// 1. img 分段（复合 URL `,{json}`、单双引号、data-src），文本 run 拼接
//    后与「原文移除 img 标签」逐字一致；
// 2. 相对地址绝对化（相对路径 / 根路径 / 协议相对 / 已绝对化）；
// 3. 宽度解析（%、px、裸数值、非法值）；
// 4. 小图行内 vs 大图独立、显式 style/书级 imageStyle、SINGLE 分页标记、
//    测量失败占位高度；
// 5. 排版引擎混排分页：图片行高、不丢字、失败占位、纯文本零变化。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_legado/src/utils/reader_inline_image.dart';
import 'package:flutter_legado/src/widgets/paragraph_layout_engine.dart';

const _defaultConfig = ParagraphConfig(
  fontSize: 16,
  lineHeight: 1.5,
  paragraphSpacing: 8,
  backgroundColor: Colors.white,
  textColor: Colors.black,
);

final _imgTagRegex = RegExp(
  r'''<img[^>]*\ssrc\s*=\s*['"]([^'"{>]*\{(?:[^{}]|\{[^}>]+\})+\})['"][^>]*>'''
  r'''|<img[^>]*\sdata-(?:src|original|srcset)\s*=\s*['"]([^'">]+)['"][^>]*>'''
  r'''|<img[^>]*\ssrc\s*=\s*"([^">]+)"[^>]*>'''
  r'''|<img[^>]*\s(?:data-[^=>]*|src)=\s*['"]([^'">]*)['"][^>]*>''',
  caseSensitive: false,
);

String _stripImages(String content) => content.replaceAll(_imgTagRegex, '');

void main() {
  setUp(() {
    ReaderImageSizeCache.clearForTest();
    ReaderImageBytesCache.clearForTest();
  });
  tearDown(ReaderImageSizeCache.clearForTest);

  group('分段（splitReaderParagraphRuns）', () {
    test('文本/图片 run 顺序与文本拼接不丢字', () {
      const paragraph =
          '前文甲<img src="https://cdn.example.com/a.jpg">中间乙'
          '<img data-src="https://cdn.example.com/b.jpg">后文丙';
      final runs = splitReaderParagraphRuns(paragraph);
      expect(runs.whereType<ReaderImageRun>().length, 2);
      final joined = runs
          .whereType<ReaderTextRun>()
          .map((run) => run.text)
          .join();
      expect(joined, _stripImages(paragraph));
      expect(joined, '前文甲中间乙后文丙');
    });

    test('复合 URL（含嵌套 headers JSON）完整保留 ,{json} 后缀', () {
      const raw =
          'https://cdn.example.com/a.webp,'
          '{"headers":{"Referer":"https://x/"}}';
      const paragraph = '<img src="$raw">';
      final runs = splitReaderParagraphRuns(paragraph);
      expect(runs.length, 1);
      final image = (runs.single as ReaderImageRun).image;
      expect(image.rawSrc, raw);
      expect(image.url, 'https://cdn.example.com/a.webp');
      expect(image.headers, {'Referer': 'https://x/'});
    });

    test('单引号 src 与 data-src 懒加载属性均可解析', () {
      final runs = splitReaderParagraphRuns(
        "<img src='https://a.com/1.png'><img data-src=\"https://a.com/2.png\">",
      );
      final images = runs.whereType<ReaderImageRun>().toList();
      expect(images.length, 2);
      expect(images[0].image.url, 'https://a.com/1.png');
      expect(images[1].image.url, 'https://a.com/2.png');
    });

    test('无 src 的 img 标签不产生图片 run，也不吞掉相邻文本', () {
      final runs = splitReaderParagraphRuns('甲<img>乙');
      expect(runs.whereType<ReaderImageRun>(), isEmpty);
      expect(
        runs.whereType<ReaderTextRun>().map((r) => r.text).join(),
        '甲<img>乙',
      );
    });
  });

  group('相对地址绝对化', () {
    test('相对路径按章节地址 resolve', () {
      expect(
        resolveReaderImageUrl('img/a.jpg', 'https://book.com/ch/1.html'),
        'https://book.com/ch/img/a.jpg',
      );
      expect(
        resolveReaderImageUrl('../a.jpg', 'https://book.com/ch/1.html'),
        'https://book.com/a.jpg',
      );
    });

    test('根路径与协议相对路径', () {
      expect(
        resolveReaderImageUrl('/img/a.jpg', 'https://book.com/ch/1.html'),
        'https://book.com/img/a.jpg',
      );
      expect(
        resolveReaderImageUrl('//cdn.example.com/a.jpg', 'https://book.com/'),
        'https://cdn.example.com/a.jpg',
      );
    });

    test('已绝对化/data/cbz 地址原样保留', () {
      for (final url in [
        'https://cdn.example.com/a.jpg',
        'http://cdn.example.com/a.jpg',
        'data:image/png;base64,AAAA',
        'cbz://page-1.jpg',
        'file:///tmp/a.jpg',
      ]) {
        expect(resolveReaderImageUrl(url, 'https://book.com/'), url);
      }
    });

    test('复合 URL 绝对化后仍保留 JSON 后缀', () {
      const raw = 'img/a.jpg,{"click":"act()"}';
      final image = parseReaderInlineImage(
        raw,
        baseUrl: 'https://book.com/ch/1.html',
      )!;
      expect(image.rawSrc, 'https://book.com/ch/img/a.jpg,{"click":"act()"}');
      expect(image.url, 'https://book.com/ch/img/a.jpg');
      expect(image.click, 'act()');
    });

    test('章节标题图基址优先 baseUrl，其次 url，最后 bookUrl', () {
      final byBase = readerChapterTitleImage(
        imgUrl: 't.jpg',
        chapterBaseUrl: 'https://book.com/ch/',
        chapterUrl: 'https://book.com/ch/1.html',
        bookUrl: 'https://book.com',
      )!;
      expect(byBase.url, 'https://book.com/ch/t.jpg');
      final byUrl = readerChapterTitleImage(
        imgUrl: 't.jpg',
        chapterUrl: 'https://book.com/ch/1.html',
        bookUrl: 'https://book.com',
      )!;
      expect(byUrl.url, 'https://book.com/ch/t.jpg');
      final byBook = readerChapterTitleImage(
        imgUrl: 'https://cdn.com/t.jpg',
        bookUrl: 'https://book.com',
      )!;
      expect(byBook.url, 'https://cdn.com/t.jpg');
    });
  });

  group('宽度解析（parseReaderImageWidth）', () {
    test('% 按可用宽换算', () {
      expect(parseReaderImageWidth('50%', 400), 200);
      expect(parseReaderImageWidth(' 25 % ', 400), 100);
    });

    test('px 与裸数值按像素', () {
      expect(parseReaderImageWidth('120px', 400), 120);
      expect(parseReaderImageWidth('120', 400), 120);
      expect(parseReaderImageWidth('120PX', 400), 120);
    });

    test('非法/非正/空值返回 null', () {
      for (final raw in [null, '', ' ', 'abc', '0', '0%', '-5', '10pxx']) {
        expect(parseReaderImageWidth(raw, 400), isNull, reason: 'raw=$raw');
      }
    });
  });

  group('图片布局判定（resolveReaderImageLayout）', () {
    ReaderInlineImage image(String src, {String? style, String? width}) {
      final suffix = <String, String>{'style': ?style, 'width': ?width};
      final raw = suffix.isEmpty ? src : '$src,${_json(suffix)}';
      return parseReaderInlineImage(raw)!;
    }

    ReaderImageLayout layout(
      ReaderInlineImage image, {
      double availableWidth = 300,
      double maxHeight = 600,
      String? bookImageStyle,
      bool forceStandalone = false,
    }) {
      return resolveReaderImageLayout(
        image: image,
        availableWidth: availableWidth,
        maxHeight: maxHeight,
        textLineHeight: 24,
        inlineSlotWidth: 16,
        bookImageStyle: bookImageStyle,
        forceStandalone: forceStandalone,
      );
    }

    test('固有尺寸宽高均 <80px → 行内小图', () {
      final img = image('https://c.com/small.png');
      ReaderImageSizeCache.put(img.rawSrc, const ReaderImageSize(40, 40));
      final result = layout(img);
      expect(result.placement, ReaderImagePlacement.inline);
      expect(result.width, 16);
      expect(result.height, 16);
      expect(result.placeholder, isFalse);
    });

    test('大图 → 独立变高行，按可用宽缩放居中', () {
      final img = image('https://c.com/big.png');
      ReaderImageSizeCache.put(img.rawSrc, const ReaderImageSize(400, 300));
      final result = layout(img);
      expect(result.placement, ReaderImagePlacement.standalone);
      expect(result.width, 300);
      expect(result.height, 225);
      expect(result.alignment, ReaderImageAlignment.center);
      expect(result.placeholder, isFalse);
    });

    test('默认样式保留固有宽度（小于可用宽）', () {
      final img = image('https://c.com/mid.png');
      ReaderImageSizeCache.put(img.rawSrc, const ReaderImageSize(200, 100));
      final result = layout(img);
      expect(result.width, 200);
      expect(result.height, 100);
    });

    test('显式 style=text 的大图强制行内', () {
      final img = image('https://c.com/text.png', style: 'text');
      ReaderImageSizeCache.put(img.rawSrc, const ReaderImageSize(400, 300));
      expect(layout(img).placement, ReaderImagePlacement.inline);
    });

    test('显式 style=FULL 的小图强制独立行', () {
      final img = image('https://c.com/full.png', style: 'FULL');
      ReaderImageSizeCache.put(img.rawSrc, const ReaderImageSize(40, 40));
      final result = layout(img);
      expect(result.placement, ReaderImagePlacement.standalone);
      expect(result.width, 300);
      expect(result.height, 300);
    });

    test('书级 imageStyle=TEXT 时全部行内', () {
      final img = image('https://c.com/big2.png');
      ReaderImageSizeCache.put(img.rawSrc, const ReaderImageSize(400, 300));
      expect(
        layout(img, bookImageStyle: 'TEXT').placement,
        ReaderImagePlacement.inline,
      );
    });

    test('SINGLE 样式带前后分页标记', () {
      final img = image('https://c.com/single.png', style: 'SINGLE');
      ReaderImageSizeCache.put(img.rawSrc, const ReaderImageSize(400, 300));
      final result = layout(img);
      expect(result.pageBreakBefore, isTrue);
      expect(result.pageBreakAfter, isTrue);
    });

    test('% 与 px 宽度参与独立图计算', () {
      final percent = image('https://c.com/p.png', width: '50%');
      ReaderImageSizeCache.put(percent.rawSrc, const ReaderImageSize(400, 200));
      final percentLayout = layout(percent, availableWidth: 400);
      expect(percentLayout.width, 200);
      expect(percentLayout.height, 100);

      final px = image('https://c.com/px.png', width: '120px');
      ReaderImageSizeCache.put(px.rawSrc, const ReaderImageSize(240, 120));
      final pxLayout = layout(px);
      expect(pxLayout.width, 120);
      expect(pxLayout.height, 60);
    });

    test('未测量 → 占位高度（16:9 且不超过页高）', () {
      final img = image('https://c.com/unknown.png');
      final result = layout(img, availableWidth: 300, maxHeight: 600);
      expect(result.placement, ReaderImagePlacement.standalone);
      expect(result.placeholder, isTrue);
      expect(result.height, 300 * 9 / 16);
    });

    test('测量失败 → 占位高度且标记 placeholder', () {
      final img = image('https://c.com/failed.png');
      ReaderImageSizeCache.putFailure(img.rawSrc);
      final result = layout(img);
      expect(result.placeholder, isTrue);
      expect(result.height, 300 * 9 / 16);
    });

    test('标题图 forceStandalone 覆盖行内判定', () {
      final img = image('https://c.com/small-title.png');
      ReaderImageSizeCache.put(img.rawSrc, const ReaderImageSize(20, 20));
      final result = layout(img, forceStandalone: true);
      expect(result.placement, ReaderImagePlacement.standalone);
      expect(result.width, 20);
      expect(result.height, 20);
    });

    test('图片高度超过页高时按页高裁剪并保持宽高比', () {
      final img = image('https://c.com/tall.png');
      ReaderImageSizeCache.put(img.rawSrc, const ReaderImageSize(300, 1200));
      final result = layout(img, availableWidth: 300, maxHeight: 400);
      expect(result.height, 400);
      expect(result.width, 100);
    });
  });

  group('排版引擎混排分页', () {
    ParagraphLayoutEngine engine([ParagraphConfig config = _defaultConfig]) =>
        ParagraphLayoutEngine(config: config, context: _FakeBuildContext());

    test('大图独立变高行且高度=显示高度', () {
      const content = '第一段文字。\n<img src="https://c.com/big.png">\n第三段文字。';
      final img = parseReaderInlineImage('https://c.com/big.png')!;
      ReaderImageSizeCache.put(img.rawSrc, const ReaderImageSize(400, 300));

      final pages = engine().paginateChapter(content, 300, 600);
      final imageLines = [
        for (final page in pages)
          for (final para in page.paragraphs)
            for (final line in para.lines)
              if (line.imageLayout != null) line,
      ];
      expect(imageLines.length, 1);
      expect(imageLines.single.height, 225);
      expect(imageLines.single.imageLayout!.width, 300);
    });

    test('小图行内：占位符进入文本行，不产生独立图片行', () {
      const content = '前文<img src="https://c.com/small.png">后文';
      final img = parseReaderInlineImage('https://c.com/small.png')!;
      ReaderImageSizeCache.put(img.rawSrc, const ReaderImageSize(24, 24));

      final pages = engine().paginateChapter(content, 300, 600);
      final lines = [
        for (final page in pages)
          for (final para in page.paragraphs) ...para.lines,
      ];
      expect(lines.any((line) => line.imageLayout != null), isFalse);
      final inlineLines = lines.where((line) => line.inlineImages.isNotEmpty);
      expect(inlineLines.length, 1);
      expect(
        inlineLines.single.inlineImages.single.placement,
        ReaderImagePlacement.inline,
      );
      expect(
        lines.map((line) => line.words.join('')).join(),
        contains(readerImagePlaceholderChar),
      );
    });

    test('分页不丢字：文本拼接后与原文（去 img 标签）一致', () {
      final content = List.generate(6, (i) {
        return '第$i段正文文字，用于验证混排分页不会丢字。'
            '<img src="https://c.com/img$i.png">'
            '图片之后的文字仍然必须完整保留。';
      }).join('\n\n');
      for (var i = 0; i < 6; i++) {
        final img = parseReaderInlineImage('https://c.com/img$i.png')!;
        ReaderImageSizeCache.put(
          img.rawSrc,
          ReaderImageSize(300.0 + i * 10, 200.0 + i * 10),
        );
      }

      final pages = engine().paginateChapter(content, 280, 360);
      expect(pages.length, greaterThan(1));
      final renderedText = pages
          .expand((page) => page.paragraphs)
          .expand((para) => para.lines)
          .where((line) => line.imageLayout == null)
          .map((line) => line.words.join(''))
          .join()
          .replaceAll(readerImagePlaceholderChar, '')
          .replaceAll(RegExp(r'\s'), '');
      final expected = _stripImages(content).replaceAll(RegExp(r'\s'), '');
      expect(renderedText, expected);
    });

    test('测量失败时图片行用占位高度，不吞掉后续段落', () {
      const content = '<img src="https://c.com/broken.png">\n后续段落文字必须保留。';
      final img = parseReaderInlineImage('https://c.com/broken.png')!;
      ReaderImageSizeCache.putFailure(img.rawSrc);

      final pages = engine().paginateChapter(content, 300, 600);
      final imageLine = pages
          .expand((page) => page.paragraphs)
          .expand((para) => para.lines)
          .firstWhere((line) => line.imageLayout != null);
      expect(imageLine.height, 300 * 9 / 16);
      final text = pages
          .expand((page) => page.paragraphs)
          .expand((para) => para.lines)
          .map((line) => line.words.join(''))
          .join();
      expect(text, contains('后续段落文字必须保留。'));
    });

    test('SINGLE 图片另起一页：前文与图片不在同一页', () {
      const content =
          '前文文字。\n<img src="https://c.com/single.png,{"style":"SINGLE"}">';
      final img = parseReaderInlineImage(
        'https://c.com/single.png,{"style":"SINGLE"}',
      )!;
      ReaderImageSizeCache.put(img.rawSrc, const ReaderImageSize(300, 200));

      final pages = engine().paginateChapter(content, 300, 600);
      expect(pages.length, greaterThanOrEqualTo(2));
      final firstPageHasImage = pages.first.paragraphs
          .expand((para) => para.lines)
          .any((line) => line.imageLayout != null);
      expect(firstPageHasImage, isFalse);
      final secondPageHasImage = pages[1].paragraphs
          .expand((para) => para.lines)
          .any((line) => line.imageLayout != null);
      expect(secondPageHasImage, isTrue);
    });

    test('纯文本段落不产生图片字段且行高与既有公式一致', () {
      final pages = engine().paginateChapter('纯文本内容。\n第二段。', 300, 600);
      for (final page in pages) {
        for (final para in page.paragraphs) {
          for (final line in para.lines) {
            expect(line.imageLayout, isNull);
            expect(line.inlineImages, isEmpty);
            expect(line.height, 16 * 1.5);
          }
        }
      }
    });

    test('尺寸缓存更新后重排：占位高度切换为真实显示高度', () {
      const content = '<img src="https://c.com/late.png">';
      final img = parseReaderInlineImage('https://c.com/late.png')!;

      final before = engine().paginateChapter(content, 300, 600);
      final beforeLine = before.single.paragraphs.single.lines.single;
      expect(beforeLine.height, 300 * 9 / 16);

      ReaderImageSizeCache.put(img.rawSrc, const ReaderImageSize(300, 150));
      final after = engine().paginateChapter(content, 300, 600);
      final afterLine = after.single.paragraphs.single.lines.single;
      expect(afterLine.height, 150);
      expect(afterLine.imageLayout!.placeholder, isFalse);
    });
  });
}

String _json(Map<String, String> map) {
  final body = map.entries
      .map((entry) => '"${entry.key}":"${entry.value}"')
      .join(',');
  return '{$body}';
}

class _FakeBuildContext extends Fake implements BuildContext {}
