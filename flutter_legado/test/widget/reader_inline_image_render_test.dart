// 批16：正文行内图片混排渲染 Widget 测试 — 全栈工程师
//
// 覆盖：
// 1. 大图独立变高行渲染（图片存在、前后文字未丢）；
// 2. 小图行内 WidgetSpan 渲染（文本仍完整）；
// 3. 章节标题图渲染；
// 4. 360dp + font_scale 1.3 不溢出；
// 5. 字号变更重排后仍不丢字/不溢出；前后翻页不抛异常；
// 6. 纯文本页无图片组件（零回归）。
library;

import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/providers/reader/reader_notifier.dart';
import 'package:flutter_legado/src/services/mock_book_api.dart';
import 'package:flutter_legado/src/utils/reader_inline_image.dart';
import 'package:flutter_legado/src/widgets/paragraph_layout_engine.dart';
import 'package:flutter_legado/src/widgets/reader/reader_inline_image_widget.dart';
import 'package:flutter_legado/src/widgets/reader/reader_page_chrome.dart';
import 'package:flutter_legado/src/widgets/reader/reader_page_view.dart';
import 'package:flutter_legado/src/widgets/reader/reader_text_content.dart';

/// 1x1 透明 PNG（真实可解码字节，Image.memory 可完成解码）
final Uint8List _pngBytes = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk'
  'YPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==',
);

const _bigImg = 'https://cdn.example.com/big.png';
const _smallImg = 'https://cdn.example.com/small.png';

class _FixedReaderNotifier extends ReaderNotifier {
  _FixedReaderNotifier(this.initial);

  ReaderState initial;

  @override
  ReaderState build() => initial;
}

class _SwitchableReaderNotifier extends _FixedReaderNotifier {
  _SwitchableReaderNotifier(super.initial);

  void switchTo(ReaderState next) {
    initial = next;
    state = next;
  }
}

ReaderState _readerState(String content, {double fontSize = 16}) {
  return ReaderState(
    currentBook: const Book(
      bookUrl: 'https://book.example.com/1',
      name: '混排测试书',
      author: '作者',
      origin: 'https://source.example.com',
      bookType: BookType.text,
    ),
    chapters: const [
      BookChapter(
        url: 'https://book.example.com/1/c1',
        title: '第一章 混排',
        index: 0,
      ),
    ],
    currentChapterIndex: 0,
    chapterContent: content,
    fontSize: fontSize,
    lineHeight: 1.5,
  );
}

ParagraphConfig _paragraphConfig({double fontSize = 16}) => ParagraphConfig(
  fontSize: fontSize,
  lineHeight: 1.5,
  paragraphSpacing: 8,
  indent: fontSize * 2,
  indentCount: 2,
  backgroundColor: Colors.white,
  textColor: Colors.black,
  imageStyle: 'FULL',
);

ReaderImageRenderConfig _renderConfig({
  void Function(ReaderInlineImage)? onPreview,
}) {
  return ReaderImageRenderConfig(
    loader: (image) async => _pngBytes,
    clickImgWay: '1',
    onPreview: onPreview ?? (_) {},
  );
}

Widget _page({
  required String content,
  double fontSize = 16,
  double width = 300,
  double height = 600,
  TextScaler textScaler = TextScaler.noScaling,
  ReaderImageLayout? titleImageLayout,
  void Function(ReaderInlineImage)? onPreview,
}) {
  final engine = ParagraphLayoutEngine(
    config: _paragraphConfig(
      fontSize: fontSize,
    ).copyWith(textScaler: textScaler),
    context: _FakeBuildContext(),
  );
  final pages = engine.paginateChapter(content, width, height);
  return MediaQuery(
    data: const MediaQueryData(
      size: Size(360, 640),
    ).copyWith(textScaler: textScaler),
    child: MaterialApp(
      home: Scaffold(
        body: ReaderTypographicPage(
          pageInfo: pages.first,
          pageIndex: 0,
          totalPages: pages.length,
          chapterTitle: '第一章 混排',
          fontSize: fontSize,
          lineHeight: 1.5,
          paragraphSpacing: 8,
          backgroundColor: Colors.white,
          textColor: Colors.black,
          imageConfig: _renderConfig(onPreview: onPreview),
          titleImageLayout: titleImageLayout,
          contentPadding: const EdgeInsets.all(12),
        ),
      ),
    ),
  );
}

/// 生成指定尺寸的真实 PNG（预测量解码用）
Future<Uint8List> _encodePng(int width, int height) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawRect(
    Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    Paint()..color = const Color(0xFF336699),
  );
  final picture = recorder.endRecording();
  final image = await picture.toImage(width, height);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  picture.dispose();
  return data!.buffer.asUint8List();
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    ReaderImageSizeCache.clearForTest();
    ReaderImageBytesCache.clearForTest();
    ReaderImageBytesCache.put('', _bigImg, _pngBytes);
    ReaderImageBytesCache.put('', _smallImg, _pngBytes);
    ReaderImageBytesCache.put('https://source.example.com', _bigImg, _pngBytes);
    ReaderImageBytesCache.put(
      'https://source.example.com',
      _smallImg,
      _pngBytes,
    );
  });

  testWidgets('大图独立变高行：图片渲染且前后文字未丢', (tester) async {
    ReaderImageSizeCache.put(_bigImg, const ReaderImageSize(400, 300));
    final content = '图片前文字。<img src="$_bigImg">图片后文字。';

    await tester.pumpWidget(_page(content: content));
    await tester.pumpAndSettle();

    expect(find.byType(ReaderInlineImageWidget), findsOneWidget);
    expect(find.byType(Image), findsOneWidget);
    expect(find.textContaining('图片前文字'), findsWidgets);
    expect(find.textContaining('图片后文字'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('小图行内 WidgetSpan：图片与文本在同一行渲染', (tester) async {
    ReaderImageSizeCache.put(_smallImg, const ReaderImageSize(24, 24));
    final content = '前文<img src="$_smallImg">后文';

    await tester.pumpWidget(_page(content: content));
    await tester.pumpAndSettle();

    expect(find.byType(ReaderInlineImageWidget), findsOneWidget);
    expect(find.byType(Image), findsOneWidget);
    // 行内图片行的文字走 Text.rich（findRichText 才能命中）
    expect(find.textContaining('前文', findRichText: true), findsWidgets);
    expect(find.textContaining('后文', findRichText: true), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('章节标题图：首屏标题下方渲染图片', (tester) async {
    ReaderImageSizeCache.put(_bigImg, const ReaderImageSize(200, 100));
    final image = parseReaderInlineImage(_bigImg)!;
    final titleLayout = resolveReaderImageLayout(
      image: image,
      availableWidth: 300,
      maxHeight: 600,
      textLineHeight: 24,
      inlineSlotWidth: 16,
      bookImageStyle: 'FULL',
      forceStandalone: true,
    );

    await tester.pumpWidget(
      _page(content: '正文内容。', titleImageLayout: titleLayout),
    );
    await tester.pumpAndSettle();

    expect(find.byType(ReaderInlineImageWidget), findsOneWidget);
    expect(find.text('第一章 混排'), findsOneWidget);
    expect(find.textContaining('正文内容'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('decodeReaderImageSize 从真实 PNG 字节解码固有尺寸', (tester) async {
    final bytes = await tester.runAsync(() => _encodePng(120, 60));
    expect(bytes, isNotNull);
    final size = await tester.runAsync(() => decodeReaderImageSize(bytes!));
    expect(size, isNotNull);
    expect(size!.width, 120);
    expect(size.height, 60);
  });

  testWidgets('纯文本页不出现图片组件（零回归）', (tester) async {
    await tester.pumpWidget(_page(content: '纯文本第一段。\n纯文本第二段。'));
    await tester.pumpAndSettle();

    expect(find.byType(ReaderInlineImageWidget), findsNothing);
    expect(find.textContaining('纯文本第一段'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  group('ReaderPageView 集成（含重排/翻页）', () {
    Future<ProviderContainer> pumpReader(
      WidgetTester tester, {
      required ReaderState state,
      _SwitchableReaderNotifier? notifier,
    }) async {
      final container = ProviderContainer(
        overrides: [
          bookApiProvider.overrideWithValue(MockBookApi()),
          readerNotifierProvider.overrideWith(
            () => notifier ?? _FixedReaderNotifier(state),
          ),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MediaQuery(
            data: const MediaQueryData(
              size: Size(360, 640),
              textScaler: TextScaler.linear(1.3),
            ),
            child: MaterialApp(
              home: ReaderPageView(
                paragraphSpacing: 8,
                marginTop: 12,
                marginBottom: 12,
                marginLeft: 12,
                marginRight: 12,
                pageChrome: const ReaderPageChromeConfig(),
                readBodyToLh: false,
                imageStyle: 'FULL',
                clickImgWay: '1',
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return container;
    }

    testWidgets('360dp + font_scale 1.3：混排正文不溢出且图片存在', (tester) async {
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      ReaderImageSizeCache.put(_bigImg, const ReaderImageSize(400, 300));
      ReaderImageSizeCache.markAttempted(_bigImg);
      final content =
          '${'混排正文测试文字，用于验证 360dp 与系统字体缩放下的排版。' * 8}'
          '<img src="$_bigImg">'
          '${'图片之后的正文必须完整保留。' * 6}';

      await pumpReader(tester, state: _readerState(content));

      expect(find.byType(ReaderPageView), findsOneWidget);
      expect(find.byType(ReaderInlineImageWidget), findsWidgets);
      expect(tester.takeException(), isNull);
    });

    testWidgets('字号变更重排后仍不溢出且文本保留', (tester) async {
      ReaderImageSizeCache.put(_bigImg, const ReaderImageSize(400, 300));
      ReaderImageSizeCache.markAttempted(_bigImg);
      final notifier = _SwitchableReaderNotifier(
        _readerState('字号重排前文字。<img src="$_bigImg">字号重排后文字。'),
      );

      await pumpReader(tester, state: notifier.initial, notifier: notifier);
      expect(tester.takeException(), isNull);

      notifier.switchTo(
        _readerState('字号重排前文字。<img src="$_bigImg">字号重排后文字。', fontSize: 22),
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('字号重排前文字'), findsWidgets);
      expect(find.byType(ReaderInlineImageWidget), findsWidgets);
      expect(tester.takeException(), isNull);
    });

    testWidgets('前后翻页不抛异常且页面仍渲染正文', (tester) async {
      ReaderImageSizeCache.put(_bigImg, const ReaderImageSize(400, 300));
      ReaderImageSizeCache.markAttempted(_bigImg);
      final content = List.generate(
        6,
        (i) =>
            '${'第$i段翻页测试文字。' * 6}'
            '<img src="$_bigImg">'
            '${'后续文字。' * 4}',
      ).join('\n\n');

      await pumpReader(tester, state: _readerState(content));
      final pageView = tester.state<ReaderPageViewState>(
        find.byType(ReaderPageView),
      );
      expect(pageView.pageCount, greaterThan(1));

      pageView.nextPageOrChapter();
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      pageView.prevPageOrChapter();
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.textContaining('翻页测试文字'), findsWidgets);
    });
  });
}

class _FakeBuildContext extends Fake implements BuildContext {}
