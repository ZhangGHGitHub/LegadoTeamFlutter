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

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_legado/src/services/local_book_store.dart';
import 'package:flutter_legado/src/utils/reader_inline_image.dart';
import 'package:flutter_legado/src/widgets/paragraph_layout_engine.dart';
import 'package:flutter_legado/src/widgets/reader/reader_bookmark_policy.dart';

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

    test('复合 JSON 的数字型 style/width 不被丢弃（P3-11）', () {
      final image = parseReaderInlineImage(
        'https://c.com/a.png,{"width":120,"style":1}',
      )!;
      expect(image.widthSpec, '120');
      expect(image.style, '1');
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

  group('本地读盘安全（P2-3）', () {
    test('准入按书文件真实存在 + 围栏，不依赖类型位/来源', () async {
      // 在线 bookUrl（含 ://）不指向本地文件 → 拒绝
      expect(
        await resolveReaderLocalImageFile(
          url: 'file:///tmp/a.png',
          bookFilePath: 'https://book.example.com/book',
        ),
        isNull,
      );
      // 空 bookUrl → 拒绝
      expect(
        await resolveReaderLocalImageFile(url: '/tmp/a.png', bookFilePath: ''),
        isNull,
      );
    });

    test('本地路径识别：file/盘符/绝对路径/UNC', () {
      for (final url in [
        'file:///data/local/tmp/a.jpg',
        'C:\\books\\a.jpg',
        '/data/books/a.jpg',
        '\\\\host\\share\\a.jpg',
        '//host/share/a.jpg',
      ]) {
        expect(isReaderLocalFilePath(url), isTrue, reason: url);
      }
      expect(isReaderLocalFilePath('https://c.com/a.jpg'), isFalse);
      expect(isReaderLocalFilePath('content://media/a.jpg'), isFalse);
      expect(isReaderLocalFilePath('cbz://page1.jpg'), isFalse);
    });

    test('路径围栏：子目录允许，穿越/外部/UNC 拒绝', () async {
      final root = await Directory.systemTemp.createTemp('reader_img_fence_');
      addTearDown(() => root.delete(recursive: true));
      final book = File('${root.path}${Platform.pathSeparator}book.txt');
      await book.writeAsString('book');
      final insideDir = Directory(
        '${root.path}${Platform.pathSeparator}images',
      );
      await insideDir.create();
      final inside = File('${insideDir.path}${Platform.pathSeparator}ok.png');
      await inside.writeAsBytes([1, 2, 3]);
      final outsideDir = await Directory.systemTemp.createTemp(
        'reader_img_outside_',
      );
      addTearDown(() => outsideDir.delete(recursive: true));
      final outside = File(
        '${outsideDir.path}${Platform.pathSeparator}evil.png',
      );
      await outside.writeAsBytes([1, 2, 3]);

      final allowed = await resolveReaderLocalImageFile(
        url: inside.path,
        bookFilePath: book.path,
      );
      expect(allowed, isNotNull);
      expect(allowed!.path, inside.path);

      final traversal = await resolveReaderLocalImageFile(
        url: '../${outside.parent.uri.pathSegments.last}/evil.png',
        bookFilePath: book.path,
      );
      expect(traversal, isNull);

      final absoluteOutside = await resolveReaderLocalImageFile(
        url: 'file:///${outside.path.replaceAll('\\', '/')}',
        bookFilePath: book.path,
      );
      expect(absoluteOutside, isNull);

      for (final unc in ['//host/share/a.png', '\\\\host\\share\\a.png']) {
        expect(
          await resolveReaderLocalImageFile(url: unc, bookFilePath: book.path),
          isNull,
        );
      }
    });

    test('iOS 相对 bookUrl 经 resolveSync 后本地图可解析（P3-8）', () async {
      final docs = await Directory.systemTemp.createTemp('reader_docs_sync_');
      addTearDown(() => docs.delete(recursive: true));
      final books = Directory('${docs.path}${Platform.pathSeparator}books');
      final images = Directory('${books.path}${Platform.pathSeparator}img');
      await images.create(recursive: true);
      final bookFile = File('${books.path}${Platform.pathSeparator}book.txt');
      await bookFile.writeAsString('book');
      final imageFile = File('${images.path}${Platform.pathSeparator}a.png');
      await imageFile.writeAsBytes([1, 2, 3]);
      LocalBookStore.warmWith(docs);

      final resolvedBook = LocalBookStore.resolveSync('books/book.txt');
      final resolvedUrl = resolveReaderImageUrl('img/a.png', resolvedBook);
      final file = await resolveReaderLocalImageFile(
        url: resolvedUrl,
        bookFilePath: resolvedBook,
      );
      expect(file, isNotNull);
      expect(file!.path, imageFile.path);
    });

    test('data URI 本地解码（P3-10）与非法输入', () {
      expect(decodeReaderDataUriImage('data:image/png;base64,AAEC'), [0, 1, 2]);
      expect(decodeReaderDataUriImage('data:image/png,AAEC'), isNull);
      expect(decodeReaderDataUriImage('data:image/png;base64,%%%'), isNull);
      expect(decodeReaderDataUriImage('https://c.com/a.png'), isNull);
    });

    test('HTTP 兜底仅 http/https（P3-12）', () {
      expect(isReaderHttpImageUrl('http://c.com/a.png'), isTrue);
      expect(isReaderHttpImageUrl('https://c.com/a.png'), isTrue);
      expect(isReaderHttpImageUrl('content://media/a.png'), isFalse);
      expect(isReaderHttpImageUrl('ftp://c.com/a.png'), isFalse);
      expect(isReaderHttpImageUrl('data:image/png;base64,AA'), isFalse);
    });
  });

  group('图片字节缓存预算（P1-3）', () {
    test('超总字节预算按 LRU 淘汰且单张超预算不缓存', () {
      ReaderImageBytesCache.clearForTest();
      final sevenMb = Uint8List(7 * 1024 * 1024);
      ReaderImageBytesCache.put('o', 'a', sevenMb);
      ReaderImageBytesCache.put('o', 'b', sevenMb);
      expect(ReaderImageBytesCache.entryCount, 2);
      ReaderImageBytesCache.put('o', 'c', sevenMb);
      expect(ReaderImageBytesCache.entryCount, 2);
      expect(ReaderImageBytesCache.totalBytes, 14 * 1024 * 1024);
      expect(ReaderImageBytesCache.get('o', 'a'), isNull);
      expect(ReaderImageBytesCache.get('o', 'c'), isNotNull);

      ReaderImageBytesCache.put(
        'o',
        'huge',
        Uint8List(ReaderImageBytesCache.maxTotalBytes + 1),
      );
      expect(ReaderImageBytesCache.get('o', 'huge'), isNull);
    });

    test('尺寸在途生命周期：start/complete/cancel', () {
      expect(ReaderImageSizeCache.beginMeasure('u'), isTrue);
      expect(ReaderImageSizeCache.isMeasuring('u'), isTrue);
      expect(ReaderImageSizeCache.beginMeasure('u'), isFalse);
      ReaderImageSizeCache.cancelMeasure('u');
      expect(ReaderImageSizeCache.isMeasuring('u'), isFalse);
      expect(ReaderImageSizeCache.hasResult('u'), isFalse);

      expect(ReaderImageSizeCache.beginMeasure('u'), isTrue);
      expect(
        ReaderImageSizeCache.completeMeasure(
          'u',
          const ReaderImageSize(10, 20),
        ),
        isTrue,
      );
      expect(ReaderImageSizeCache.lookup('u')!.width, 10);
      expect(ReaderImageSizeCache.beginMeasure('u'), isFalse);
      expect(
        ReaderImageSizeCache.completeMeasure(
          'u',
          const ReaderImageSize(99, 99),
        ),
        isFalse,
        reason: '已有成功结果不被覆盖',
      );
    });

    test('失败分类：网络失败跨章可重试，解码失败永久（P3-7）', () {
      expect(ReaderImageSizeCache.beginMeasure('net'), isTrue);
      ReaderImageSizeCache.completeMeasure('net', null, retryable: true);
      expect(ReaderImageSizeCache.lookup('net')!.failed, isTrue);
      expect(ReaderImageSizeCache.lookup('net')!.retryable, isTrue);
      expect(
        ReaderImageSizeCache.beginMeasure('net'),
        isTrue,
        reason: '网络类失败允许跨章重试',
      );
      ReaderImageSizeCache.cancelMeasure('net');

      expect(ReaderImageSizeCache.beginMeasure('bad'), isTrue);
      ReaderImageSizeCache.completeMeasure('bad', null, retryable: false);
      expect(ReaderImageSizeCache.lookup('bad')!.retryable, isFalse);
      expect(
        ReaderImageSizeCache.beginMeasure('bad'),
        isFalse,
        reason: '解码/格式失败永久不重试',
      );
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

    test('LEFT/RIGHT/CENTER 只决定对齐，不铺满可用宽（P2-4）', () {
      for (final entry in {
        'LEFT': ReaderImageAlignment.left,
        'RIGHT': ReaderImageAlignment.right,
        'CENTER': ReaderImageAlignment.center,
      }.entries) {
        final img = image(
          'https://c.com/${entry.key.toLowerCase()}.png',
          style: entry.key,
        );
        ReaderImageSizeCache.put(img.rawSrc, const ReaderImageSize(100, 50));
        final result = layout(img, availableWidth: 300);
        expect(result.placement, ReaderImagePlacement.standalone);
        expect(result.width, 100, reason: entry.key);
        expect(result.height, 50, reason: entry.key);
        expect(result.alignment, entry.value, reason: entry.key);
      }
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

    test('maxHeight=0 视为不可用（零尺寸占位，P3-6）', () {
      final img = image('https://c.com/no-height.png');
      ReaderImageSizeCache.put(img.rawSrc, const ReaderImageSize(300, 200));
      final result = layout(img, availableWidth: 300, maxHeight: 0);
      expect(result.width, 0);
      expect(result.height, 0);
      expect(result.placeholder, isTrue);
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

    test('SINGLE 仅图片前分页：图片前文本填满当前页（P2-6）', () {
      // 同一段落内「长文本 + SINGLE 图片」：旧实现会让整段先换页，
      // 首页只剩空白；回修后文本段留在当前页，图片独占下一页。
      final text = '甲' * 240;
      final content =
          '$text<img src="https://c.com/single2.png,{"style":"SINGLE"}">'
          '乙乙乙';
      final img = parseReaderInlineImage(
        'https://c.com/single2.png,{"style":"SINGLE"}',
      )!;
      ReaderImageSizeCache.put(img.rawSrc, const ReaderImageSize(300, 200));

      final pages = engine().paginateChapter(content, 300, 600);
      final firstPageLines = pages.first.paragraphs
          .expand((para) => para.lines)
          .toList();
      final firstPageText = firstPageLines
          .map((line) => line.words.join(''))
          .join();
      expect(firstPageText, isNotEmpty, reason: '图片前文本应填当前页');
      expect(firstPageText.replaceAll(RegExp(r'\s'), ''), text);
      expect(firstPageLines.any((line) => line.imageLayout != null), isFalse);
      // 图片页应只有图片行（SINGLE 独占一页）
      final imagePage = pages.firstWhere(
        (page) => page.paragraphs
            .expand((para) => para.lines)
            .any((line) => line.imageLayout != null),
      );
      final imagePageLines = imagePage.paragraphs
          .expand((para) => para.lines)
          .toList();
      expect(imagePageLines.length, 1);
      expect(imagePageLines.single.imageLayout, isNotNull);
    });

    test('图片行建立章节偏移映射，不回落整段（P2-5）', () {
      const content = '前文<img src="https://c.com/map.png">后文';
      final img = parseReaderInlineImage('https://c.com/map.png')!;
      ReaderImageSizeCache.put(img.rawSrc, const ReaderImageSize(300, 200));

      final pages = engine().paginateChapter(content, 300, 600);
      final line = pages
          .expand((page) => page.paragraphs)
          .expand((para) => para.lines)
          .firstWhere((line) => line.imageLayout != null);
      final tagStart = content.indexOf('<img');
      expect(line.highlightMapped, isTrue);
      expect(line.chapterStartIndex, tagStart);
      expect(line.startIndex, tagStart);
      expect(line.endIndex, content.indexOf('>') + 1);

      final range = readerBookmarkRangeForPage(
        PageInfo(
          paragraphs: [
            ParagraphInfo(
              lines: [line],
              totalHeight: line.height,
              startIndex: 0,
              endIndex: content.length,
            ),
          ],
          totalHeight: line.height,
        ),
      );
      expect(range.start, tagStart);
      expect(range.end, content.indexOf('>') + 1);
      expect(range.isEmpty, isFalse);
    });

    test('行内小图之后的文本章节偏移按标签长度补偿（P2-5）', () {
      const content = '前文<img src="https://c.com/inline.png">后文';
      final img = parseReaderInlineImage('https://c.com/inline.png')!;
      ReaderImageSizeCache.put(img.rawSrc, const ReaderImageSize(24, 24));

      final pages = engine().paginateChapter(content, 300, 600);
      final line = pages
          .expand((page) => page.paragraphs)
          .expand((para) => para.lines)
          .firstWhere((line) => line.inlineImages.isNotEmpty);
      final text = line.words.join('');
      final afterIndex = text.indexOf('后');
      expect(afterIndex, greaterThan(0));
      expect(line.chapterOffsetAt(afterIndex), content.indexOf('后'));
      expect(
        line.chapterOffsetAt(0),
        content.indexOf('前'),
        reason: '行首文本映射不受占位符影响',
      );
    });

    test('独立图片之后的文本行章节起点准确（P2-5）', () {
      const content = '甲<img src="https://c.com/big-map.png">乙';
      final img = parseReaderInlineImage('https://c.com/big-map.png')!;
      ReaderImageSizeCache.put(img.rawSrc, const ReaderImageSize(300, 200));

      final pages = engine().paginateChapter(content, 300, 600);
      final lines = pages
          .expand((page) => page.paragraphs)
          .expand((para) => para.lines)
          .toList();
      final imageIndex = lines.indexWhere((line) => line.imageLayout != null);
      expect(imageIndex, greaterThanOrEqualTo(0));
      final afterText = lines[imageIndex + 1];
      expect(afterText.words.join(), contains('乙'));
      expect(afterText.chapterStartIndex, content.indexOf('乙'));
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

  group('设备回修（批16 验收 P1/P2）', () {
    // 与设备验收书一致的混合分段：首段含大图，随后 6 段单换行分段，
    // 空行分隔后又 8 段单换行。旧实现因含 \n\n 而按空行分段，把单换行
    // 段落合并为超长段，\n 留在行内导致 Text(maxLines:1) 裁掉后续前缀。
    String deviceLikeChapter() {
      final first = List.generate(
        6,
        (i) =>
            '第一大段第${i + 1}句：这是用于翻页对照的普通文本，内容与图片无关，'
            '确保本页有足够多的文字行可以验证图片前后文字没有丢失，'
            '也确保分页器有可翻页的空间。',
      ).join('\n');
      final second = List.generate(
        8,
        (i) =>
            '第二大段第${i + 1}句：图片之后的段落继续存在，翻页后应当仍能看到'
            '连续的文字，不出现空白页，也不出现文字被图片挤出可视区域的情况。',
      ).join('\n');
      return '前文字。<img src="https://c.com/device-big.png">后文字。\n\n'
          '$first\n\n$second';
    }

    ParagraphLayoutEngine deviceEngine() => ParagraphLayoutEngine(
      config: const ParagraphConfig(
        fontSize: 20,
        lineHeight: 1.6,
        paragraphSpacing: 8,
        indent: 40,
        indentCount: 2,
        backgroundColor: Colors.white,
        textColor: Colors.black,
        imageStyle: 'FULL',
      ),
      context: _FakeBuildContext(),
    );

    test('混排章节跨页不丢字：行内无换行符且第 2 页首行前缀完整', () {
      final content = deviceLikeChapter();
      final img = parseReaderInlineImage('https://c.com/device-big.png')!;
      ReaderImageSizeCache.put(img.rawSrc, const ReaderImageSize(800, 600));

      final pages = deviceEngine().paginateChapter(content, 320, 540);
      expect(pages.length, greaterThan(1));

      for (final page in pages) {
        for (final para in page.paragraphs) {
          for (final line in para.lines) {
            final text = line.words.join('');
            expect(
              text.contains('\n') || text.contains('\r'),
              isFalse,
              reason: '行内不得残留换行符（会 Text maxLines:1 裁字）: $text',
            );
          }
        }
      }

      // 任何以段落前缀开头的行都必须是完整的「　　第N大段第M句：」，
      // 不允许出现被换行/分页切成半截的前缀（设备 P1 形态）。
      for (final page in pages) {
        for (final para in page.paragraphs) {
          for (final line in para.lines) {
            final text = line.words.join('');
            if (text.startsWith('　　') && text.contains('大段')) {
              expect(
                RegExp(r'^　　第[一二]大段第\d+句').hasMatch(text),
                isTrue,
                reason: '段落前缀不完整: $text',
              );
            }
          }
        }
      }

      // 第 2 页首行必须是原文的连续子串（允许是跨页段落的中段）
      final page2FirstLine = pages[1].paragraphs.first.lines.first.words.join(
        '',
      );
      expect(page2FirstLine, isNotEmpty);
      expect(
        _stripImages(content).contains(page2FirstLine.trim()),
        isTrue,
        reason: '第 2 页首行应为原文连续子串: $page2FirstLine',
      );

      final rendered = pages
          .expand((page) => page.paragraphs)
          .expand((para) => para.lines)
          .map((line) => line.words.join(''))
          .join()
          .replaceAll(RegExp(r'\s'), '');
      expect(
        rendered,
        _stripImages(content).replaceAll(RegExp(r'\s'), ''),
        reason: '逐字符比对：全章文本不得丢失（图片标签本身不入正文）',
      );
    });

    test('含图章节首页利用率：图片段后继续放后续文本段（同页 ≥2 段）', () {
      final content = deviceLikeChapter();
      final img = parseReaderInlineImage('https://c.com/device-big.png')!;
      ReaderImageSizeCache.put(img.rawSrc, const ReaderImageSize(800, 600));

      final pages = deviceEngine().paginateChapter(content, 320, 540);
      expect(
        pages.first.paragraphs.length,
        greaterThanOrEqualTo(2),
        reason: '首屏应为「图片段 + 至少 1 个文本段」',
      );
      expect(pages.first.totalHeight, greaterThan(540 * 0.7));
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
