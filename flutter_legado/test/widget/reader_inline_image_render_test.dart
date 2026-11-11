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

import 'dart:async';
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
import 'package:flutter_legado/src/widgets/reader/click_img_tap_detector.dart';
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
const _img1 = 'https://cdn.example.com/1.png';
const _img2 = 'https://cdn.example.com/2.png';
const _img3 = 'https://cdn.example.com/3.png';
const _imgB = 'https://cdn.example.com/book-b.png';
// 不预置字节缓存：用于验证「测量在途/失败」不依赖渲染成功回填
const _imgA = 'https://cdn.example.com/inflight-a.png';
const _failImg = 'https://cdn.example.com/fail.png';
final List<String> _manyImgs = List.generate(
  6,
  (i) => 'https://cdn.example.com/many-$i.png',
);

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

ReaderState _readerState(
  String content, {
  double fontSize = 16,
  String bookUrl = 'https://book.example.com/1',
  String origin = 'https://source.example.com',
  String? chapterImgUrl,
  int chapterIndex = 0,
  bool isLoading = false,
  List<BookChapter>? chapters,
}) {
  final chapterList =
      chapters ??
      [
        BookChapter(
          url: '$bookUrl/c1',
          title: '第一章 混排',
          index: 0,
          imgUrl: chapterImgUrl,
        ),
      ];
  return ReaderState(
    currentBook: Book(
      bookUrl: bookUrl,
      name: '混排测试书',
      author: '作者',
      origin: origin,
      bookType: BookType.text,
    ),
    chapters: chapterList,
    currentChapterIndex: chapterIndex,
    chapterContent: content,
    fontSize: fontSize,
    lineHeight: 1.5,
    isLoading: isLoading,
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
  String cacheOrigin = '',
  VoidCallback? onSizeResolved,
  String clickImgWay = '1',
  ClickImgActionRunner? onRunAction,
}) {
  return ReaderImageRenderConfig(
    loader: (image) async => _pngBytes,
    clickImgWay: clickImgWay,
    onPreview: onPreview ?? (_) {},
    onRunAction: onRunAction,
    cacheOrigin: cacheOrigin,
    onSizeResolved: onSizeResolved,
  );
}

Widget _page({
  required String content,
  double fontSize = 16,
  double width = 300,
  double height = 600,
  int pageIndex = 0,
  double? firstPageHeight,
  TextScaler textScaler = TextScaler.noScaling,
  ReaderImageLayout? titleImageLayout,
  void Function(ReaderInlineImage)? onPreview,
  String clickImgWay = '1',
  ClickImgActionRunner? onRunAction,
}) {
  final engine = ParagraphLayoutEngine(
    config: _paragraphConfig(
      fontSize: fontSize,
    ).copyWith(textScaler: textScaler),
    context: _FakeBuildContext(),
  );
  final pages = engine.paginateChapter(
    content,
    width,
    height,
    firstPageHeight: firstPageHeight,
  );
  final safeIndex = pageIndex.clamp(0, pages.length - 1);
  return MediaQuery(
    data: const MediaQueryData(
      size: Size(360, 640),
    ).copyWith(textScaler: textScaler),
    child: MaterialApp(
      home: Scaffold(
        body: ReaderTypographicPage(
          pageInfo: pages[safeIndex],
          pageIndex: safeIndex,
          totalPages: pages.length,
          chapterTitle: '第一章 混排',
          fontSize: fontSize,
          lineHeight: 1.5,
          paragraphSpacing: 8,
          backgroundColor: Colors.white,
          textColor: Colors.black,
          imageConfig: _renderConfig(
            onPreview: onPreview,
            clickImgWay: clickImgWay,
            onRunAction: onRunAction,
          ),
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

/// 与设备验收书一致的混合分段内容（首段大图 + 单换行段组 + 空行分隔）
String _deviceLikeContent() {
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
  return '前文字。<img src="$_bigImg">后文字。\n\n$first\n\n$second';
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    ReaderImageSizeCache.clearForTest();
    ReaderImageBytesCache.clearForTest();
    ReaderPageViewState.debugRepaginationCount = 0;
    ReaderImageBytesCache.put('', _bigImg, _pngBytes);
    ReaderImageBytesCache.put('', _smallImg, _pngBytes);
    ReaderImageBytesCache.put('https://source.example.com', _bigImg, _pngBytes);
    ReaderImageBytesCache.put(
      'https://source.example.com',
      _smallImg,
      _pngBytes,
    );
    for (final url in [_img1, _img2, _img3, _imgB, ..._manyImgs]) {
      ReaderImageBytesCache.put('https://source.example.com', url, _pngBytes);
      ReaderImageBytesCache.put('https://source-b.example.com', url, _pngBytes);
    }
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

  testWidgets('P3-9 行内图片 onRunAction：点击执行完整 src 动作', (tester) async {
    ReaderImageSizeCache.put(_bigImg, const ReaderImageSize(400, 300));
    final actions = <String>[];
    final srcs = <String>[];
    final rawSrc = '$_bigImg,{"click":"act()"}';
    final content = '图片前文字。<img src="$rawSrc">图片后文字。';

    await tester.pumpWidget(
      _page(
        content: content,
        clickImgWay: '0',
        onRunAction: (action, imgSrc) async {
          actions.add(action);
          srcs.add(imgSrc);
        },
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byType(ReaderInlineImageWidget));
    await tester.pump();

    expect(actions, ['act()']);
    expect(srcs, [rawSrc], reason: 'P3-6：行内图片动作 result 传完整 src');
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

  testWidgets('混排段落跨页不丢字：第 2 页首行前缀完整（P1）', (tester) async {
    ReaderImageSizeCache.put(_bigImg, const ReaderImageSize(800, 600));
    await tester.pumpWidget(
      _page(
        content: _deviceLikeContent(),
        width: 320,
        height: 540,
        pageIndex: 1,
      ),
    );
    await tester.pumpAndSettle();

    final lineTexts = tester
        .widgetList<Text>(find.byType(Text))
        .map((text) => text.data ?? text.textSpan?.toPlainText() ?? '')
        .where((value) => value.isNotEmpty)
        .toList();
    for (final text in lineTexts) {
      expect(
        text.contains('\n') || text.contains('\r'),
        isFalse,
        reason: '行内换行会被 maxLines:1 裁掉后续段落前缀: $text',
      );
    }
    for (final text in lineTexts) {
      if (!text.startsWith('　　') || !text.contains('大段')) continue;
      expect(
        RegExp(r'^　　第[一二]大段第\d+句').hasMatch(text),
        isTrue,
        reason: '段落首行前缀被截断: $text',
      );
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('含图章节首页利用率：图片段后继续放文本段（P2）', (tester) async {
    ReaderImageSizeCache.put(_bigImg, const ReaderImageSize(800, 600));
    await tester.pumpWidget(
      _page(
        content: _deviceLikeContent(),
        width: 320,
        height: 540,
        firstPageHeight: 480,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(ReaderInlineImageWidget), findsOneWidget);
    expect(
      find.textContaining('第一大段第1句'),
      findsWidgets,
      reason: '首屏应同时包含图片段与后续文本段',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('图片旁单行文本不拉伸居中（P3）', (tester) async {
    ReaderImageSizeCache.put(_bigImg, const ReaderImageSize(400, 300));
    await tester.pumpWidget(_page(content: '前文字。<img src="$_bigImg">后文字。'));
    await tester.pumpAndSettle();

    final lineText = tester.widget<Text>(find.textContaining('前文字').first);
    final spacing = lineText.style?.letterSpacing;
    expect(
      spacing == null || spacing == 0,
      isTrue,
      reason: '图片上方单行文本不应被两端对齐拉伸，letterSpacing=$spacing',
    );
    expect(tester.takeException(), isNull);
  });

  group('ReaderPageView 集成（含重排/翻页）', () {
    Future<ProviderContainer> pumpReader(
      WidgetTester tester, {
      required ReaderState state,
      _SwitchableReaderNotifier? notifier,
      ReaderImageSizeMeasurer? measurer,
      Size size = const Size(360, 640),
    }) async {
      // 视口与 MediaQuery 尺寸一致（ReaderTypographicPage 用真实布局约束，
      // 只改 MediaQuery 会让分页宽度/高度与渲染约束错位）
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
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
            data: MediaQueryData(
              size: size,
              textScaler: const TextScaler.linear(1.3),
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
                imageMeasurer: measurer,
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

    testWidgets('第 3 图挂起时前两张尺寸已回填，批次结束统一重排（P1-1/P1-2）', (tester) async {
      tester.view.physicalSize = const Size(400, 1400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final c1 = Completer<ReaderImageSize?>();
      final c2 = Completer<ReaderImageSize?>();
      final c3 = Completer<ReaderImageSize?>();
      Future<ReaderImageSize?> measurer(ReaderInlineImage image) {
        return switch (image.url) {
          _img1 => c1.future,
          _img2 => c2.future,
          _ => c3.future,
        };
      }

      final content =
          '图一<img src="$_img1">文字<img src="$_img2">'
          '文字<img src="$_img3">结尾';
      await pumpReader(
        tester,
        state: _readerState(content),
        measurer: measurer,
        size: const Size(400, 1400),
      );
      expect(ReaderImageSizeCache.isMeasuring(_img1), isTrue);

      c1.complete(const ReaderImageSize(200, 100));
      await tester.pump(const Duration(milliseconds: 20));
      c2.complete(const ReaderImageSize(200, 100));
      await tester.pump(const Duration(milliseconds: 20));

      // [批16 三审 P1-2] 批次未结束不重排，但已完成尺寸已写回
      expect(ReaderImageSizeCache.lookup(_img1)?.width, 200);
      expect(ReaderImageSizeCache.lookup(_img2)?.width, 200);
      expect(ReaderImageSizeCache.hasResult(_img3), isFalse);

      c3.complete(const ReaderImageSize(200, 100));
      await tester.pump(const Duration(milliseconds: 20));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 20));

      final layouts = tester
          .widgetList<ReaderImageLineWidget>(find.byType(ReaderImageLineWidget))
          .map((w) => w.layout)
          .where(
            (l) =>
                l.image.url == _img1 ||
                l.image.url == _img2 ||
                l.image.url == _img3,
          )
          .toList();
      expect(layouts.length, greaterThanOrEqualTo(3));
      for (final layout in layouts) {
        expect(layout.placeholder, isFalse);
        expect(layout.height, closeTo(100 * 376 / 200, 1));
      }
      expect(tester.takeException(), isNull);
    });

    testWidgets('换书后取消在途测量，新章图片正常测量（P1-1）', (tester) async {
      final pendingA = Completer<ReaderImageSize?>();
      Future<ReaderImageSize?> measurer(ReaderInlineImage image) {
        if (image.url == _imgA) return pendingA.future;
        return Future.value(const ReaderImageSize(120, 60));
      }

      final notifier = _SwitchableReaderNotifier(
        _readerState('甲<img src="$_imgA">乙'),
      );
      await pumpReader(
        tester,
        state: notifier.initial,
        notifier: notifier,
        measurer: measurer,
      );
      expect(ReaderImageSizeCache.isMeasuring(_imgA), isTrue);

      notifier.switchTo(
        _readerState(
          '新书<img src="$_imgB">正文',
          bookUrl: 'https://book.example.com/b',
          origin: 'https://source-b.example.com',
        ),
      );
      await tester.pump(const Duration(milliseconds: 20));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 20));

      expect(ReaderImageSizeCache.isMeasuring(_imgA), isFalse);
      expect(ReaderImageSizeCache.lookup(_imgA), isNull);
      expect(ReaderImageSizeCache.lookup(_imgB)?.width, 120);
      expect(tester.takeException(), isNull);
    });

    testWidgets('测量失败不重复下载（P2-8）', (tester) async {
      var calls = 0;
      Future<ReaderImageSize?> measurer(ReaderInlineImage image) async {
        calls++;
        return null;
      }

      final notifier = _SwitchableReaderNotifier(
        _readerState('失败图<img src="$_failImg">正文'),
      );
      await pumpReader(
        tester,
        state: notifier.initial,
        notifier: notifier,
        measurer: measurer,
      );
      await tester.pump(const Duration(milliseconds: 20));
      expect(calls, 1);
      expect(ReaderImageSizeCache.lookup(_failImg)?.failed, isTrue);

      // 触发同章重排（字号变化），不得再次测量
      notifier.switchTo(
        _readerState('失败图<img src="$_failImg">正文', fontSize: 18),
      );
      await tester.pump(const Duration(milliseconds: 20));
      await tester.pumpAndSettle();
      expect(calls, 1);
      expect(tester.takeException(), isNull);
    });

    testWidgets('渲染成功回填失败尺寸并触发重排（P2-8）', (tester) async {
      ReaderImageSizeCache.putFailure(_img1);
      final state = _readerState('回填图<img src="$_img1">正文');
      await pumpReader(tester, state: state);

      // Image 解码/帧回调在真实时间维度完成
      await tester.runAsync(() async {
        for (var i = 0; i < 40; i++) {
          if (ReaderImageSizeCache.lookup(_img1)?.isValid == true) break;
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
      });
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 20));

      expect(ReaderImageSizeCache.lookup(_img1)?.isValid, isTrue);
      expect(tester.takeException(), isNull);
    });

    testWidgets('data URI 本地解码渲染，不走 HTTP（P3-10）', (tester) async {
      final raw = 'data:image/png;base64,${base64Encode(_pngBytes)}';
      ReaderImageSizeCache.put(raw, const ReaderImageSize(1, 1));
      final content = '数据图<img src="$raw">正文';

      await pumpReader(tester, state: _readerState(content));
      expect(find.byType(Image), findsWidgets);
      expect(tester.takeException(), isNull);
    });

    testWidgets('标题图容量扣除标题块与间距，不溢出（P2-7）', (tester) async {
      ReaderImageSizeCache.put(_bigImg, const ReaderImageSize(300, 1200));
      await pumpReader(
        tester,
        state: _readerState('正文内容。', chapterImgUrl: _bigImg),
      );

      expect(find.byType(ReaderImageLineWidget), findsWidgets);
      final titleImageLayout = tester
          .widgetList<ReaderImageLineWidget>(find.byType(ReaderImageLineWidget))
          .first
          .layout;
      expect(titleImageLayout.height, lessThan(640));
      expect(tester.takeException(), isNull);
    });

    testWidgets('异步 revision 重排保留当前页（P2-9）', (tester) async {
      final pending = Completer<ReaderImageSize?>();
      final content = List.generate(
        8,
        (i) =>
            '${'递增重排第$i段。' * 12}'
            '${i == 0 ? '<img src="$_img1">' : ''}',
      ).join('\n\n');
      await pumpReader(
        tester,
        state: _readerState(content),
        measurer: (image) => pending.future,
      );
      final pageView = tester.state<ReaderPageViewState>(
        find.byType(ReaderPageView),
      );
      expect(pageView.pageCount, greaterThan(2));
      pageView.goToPage(1);
      await tester.pumpAndSettle();
      final pageBefore = pageView.currentPageIndex;
      expect(pageBefore, 1);

      pending.complete(const ReaderImageSize(300, 150));
      await tester.pump(const Duration(milliseconds: 20));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 20));

      expect(pageView.currentPageIndex, pageBefore);
      expect(tester.takeException(), isNull);
    });

    testWidgets('全章测量并发上限=1，6 图仅统一重排一次（P1-1/P1-2）', (tester) async {
      tester.view.physicalSize = const Size(400, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final completers = [
        for (var i = 0; i < _manyImgs.length; i++)
          Completer<ReaderImageSize?>(),
      ];
      var active = 0;
      var maxActive = 0;
      Future<ReaderImageSize?> measurer(ReaderInlineImage image) {
        active++;
        if (active > maxActive) maxActive = active;
        final index = _manyImgs.indexOf(image.url);
        return completers[index].future.whenComplete(() => active--);
      }

      final content = List.generate(
        _manyImgs.length,
        (i) => '第$i图<img src="${_manyImgs[i]}">正文',
      ).join('\n\n');
      await pumpReader(
        tester,
        state: _readerState(content),
        measurer: measurer,
        size: const Size(400, 1600),
      );
      expect(active, 1);
      final baseCount = ReaderPageViewState.debugRepaginationCount;

      for (final completer in completers) {
        completer.complete(const ReaderImageSize(200, 100));
        await tester.pump(const Duration(milliseconds: 20));
      }
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 20));

      expect(maxActive, 1, reason: '重排不得重启测量协程');
      expect(
        ReaderPageViewState.debugRepaginationCount - baseCount,
        lessThanOrEqualTo(2),
        reason: '6 图批次应只在结束后统一重排一次',
      );
      for (final url in _manyImgs) {
        expect(ReaderImageSizeCache.lookup(url)?.width, 200);
      }
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });

    testWidgets('同书切章 loading 冻结期取消在途测量（P2-4）', (tester) async {
      final pendingA = Completer<ReaderImageSize?>();
      Future<ReaderImageSize?> measurer(ReaderInlineImage image) {
        if (image.url == _imgA) return pendingA.future;
        return Future.value(const ReaderImageSize(120, 60));
      }

      const bookUrl = 'https://book.example.com/1';
      final chapters = [
        const BookChapter(url: '$bookUrl/c1', title: '第一章', index: 0),
        const BookChapter(url: '$bookUrl/c2', title: '第二章', index: 1),
      ];
      final notifier = _SwitchableReaderNotifier(
        _readerState('甲<img src="$_imgA">乙', chapters: chapters),
      );
      await pumpReader(
        tester,
        state: notifier.initial,
        notifier: notifier,
        measurer: measurer,
      );
      expect(ReaderImageSizeCache.isMeasuring(_imgA), isTrue);

      // 切章进入 loading 冻结（旧分页仍渲染，repaginate=false）
      notifier.switchTo(
        _readerState('', chapterIndex: 1, isLoading: true, chapters: chapters),
      );
      await tester.pump();
      expect(
        ReaderImageSizeCache.isMeasuring(_imgA),
        isFalse,
        reason: 'loading 冻结期就必须取消旧章测量',
      );

      notifier.switchTo(
        _readerState(
          '新章<img src="$_imgB">正文',
          chapterIndex: 1,
          chapters: chapters,
        ),
      );
      await tester.pump(const Duration(milliseconds: 20));
      await tester.pump(const Duration(milliseconds: 20));
      expect(ReaderImageSizeCache.lookup(_imgB)?.width, 120);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });

    testWidgets('网络类失败同章不重试、回章可重试（P3-7）', (tester) async {
      var calls = 0;
      Future<ReaderImageSize?> measurer(ReaderInlineImage image) async {
        calls++;
        return null;
      }

      const bookUrl = 'https://book.example.com/1';
      final chapters = [
        const BookChapter(url: '$bookUrl/c1', title: '第一章', index: 0),
        const BookChapter(url: '$bookUrl/c2', title: '第二章', index: 1),
      ];
      final notifier = _SwitchableReaderNotifier(
        _readerState('失败<img src="$_failImg">正文', chapters: chapters),
      );
      await pumpReader(
        tester,
        state: notifier.initial,
        notifier: notifier,
        measurer: measurer,
      );
      await tester.pump(const Duration(milliseconds: 20));
      expect(calls, 1);
      expect(ReaderImageSizeCache.lookup(_failImg)?.retryable, isTrue);

      // 同章内触发重排：不得重试
      notifier.switchTo(
        _readerState(
          '失败<img src="$_failImg">正文',
          fontSize: 18,
          chapters: chapters,
        ),
      );
      await tester.pump(const Duration(milliseconds: 20));
      expect(calls, 1);

      // 切到无图章再回本章：网络类失败允许重试
      notifier.switchTo(
        _readerState('第二章正文', chapterIndex: 1, chapters: chapters),
      );
      await tester.pump(const Duration(milliseconds: 20));
      notifier.switchTo(
        _readerState('失败<img src="$_failImg">正文', chapters: chapters),
      );
      await tester.pump(const Duration(milliseconds: 20));
      await tester.pump(const Duration(milliseconds: 20));
      expect(calls, 2);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  });
}

class _FakeBuildContext extends Fake implements BuildContext {}
