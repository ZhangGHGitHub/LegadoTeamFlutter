import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/screens/reader_comic_screen.dart';
import 'package:flutter_legado/src/services/mock_book_api.dart';
import 'package:flutter_legado/src/widgets/loading_indicator.dart';
import 'package:flutter_test/flutter_test.dart';

import 'comic_test_helpers.dart';

/// [STAGE-UI-P43UNIFY1 B2] 漫画加载环 / 骨架块主题槽断言
///
/// 取证（参考版 legado-with-MD3，docs/LOADING_ASSETS_UNIFY_SURVEY_20260930.md
/// §1/§2.2）：
/// - 单页加载环 = 参考版主题色环（MangaReaderOverlays.kt:754 裸
///   CircularProgressIndicator 取主题色；MangaReaderScreen.kt:1618-1645
///   单页加载卡内 AppCircularProgressIndicator 同为主题色默认）→ 我方环
///   应用主题槽（color == null → 主题 primary），而非硬编码 0xFF666666；
/// - 加载态不整面压黑（参考版 #2082：加载/排队态不再整页压黑罩，仅小
///   45% 黑圆角卡；我方漫画页恒纯黑底，该卡在纯黑底上不可见，故不加
///   卡、仅去除硬编码 0xFF1A1A1A 整面底色）；
/// - 参考版漫画场景无骨架屏（grep ui/book/ 零命中），「参考版同场景
///   固定深灰」不可确证 → 骨架块硬编码灰改主题槽等价（参考版
///   SkeletonPlaceholders.kt:54-56 surfaceContainerHighest 取证，与
///   我方 SkeletonBox 参数对齐）；
/// - 参考版漫画页背景 = 用户设置（默认 Color.Black，
///   MangaReaderContract.kt:119），我方屏幕固定纯黑
///   （Scaffold backgroundColor: Colors.black）——主题色环在深底上的
///   可见性取舍与参考版一致（参考版单页加载卡同样是深底 + 主题色环），
///   按参考版形态从之并在此注明。
const String _kErrorAsset = 'assets/images/image_loading_error.png';

/// 1x1 透明 PNG（作为 FFI 解码结果 base64，供 Image.memory 渲染；
/// 同 reader_comic_chapter_error_test 先例）
const _kPngBase64 =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGNgYGBgAAAABQAB'
    'h6FO1AAAAABJRU5ErkJggg==';

/// 种子色（Material 3 标准紫）：dark/light 双主题均从同一种子派生，
/// 保证主题槽断言在两态下都可比较
const _kSeedColor = Color(0xFF6750A4);

Book _book({
  String origin = 'https://manga.example.com',
  String url = 'mock://comic/p43unify/ring',
}) {
  return Book(
    bookUrl: url,
    tocUrl: '$url/toc',
    name: 'P43UNIFY漫画',
    origin: origin,
    originName: '测试漫画源',
    canUpdate: true,
    totalChapterNum: 1,
    bookType: BookType.image,
    durChapterIndex: 0,
    durChapterPos: 0,
  );
}

List<BookChapter> _chapters(String baseUrl) => [
      BookChapter(
        index: 0,
        url: '$baseUrl/ch/1',
        title: '第一章',
      ),
    ];

/// 图一/二：FFI 解码链路，解码延迟 300ms（fake 时钟）→ 加载环驻留
/// 足够长可断言。[tag] 隔离静态解码缓存（ComicImageDecodeCache 以
/// bookSourceUrl+url 为键），避免 dark/light 两用例互相命中缓存。
class _SlowDecodeMockApi extends MockBookApi {
  _SlowDecodeMockApi(this.book, this.chapters, this.tag);

  final Book book;
  final List<BookChapter> chapters;
  final String tag;

  @override
  Future<List<BookSource>> getBookSources() async => [
        BookSource(
          bookSourceUrl: book.origin,
          bookSourceName: book.originName,
          bookSourceType: 2,
          enabled: true,
          ruleContent: const ContentRule(content: '.comics@img@html'),
          customOrder: 0,
          lastUpdateTime: 0,
          respondTime: 0,
          weight: 0,
        ),
      ];

  @override
  Future<Book?> getBook(String bookUrl) async => book;

  @override
  Future<List<BookChapter>> getChapters(String bookUrl) async => chapters;

  @override
  Future<String> fetchChapterContent(
    String bookUrl,
    String chapterUrl,
    String sourceUrl,
  ) async {
    return '<img src="https://cdn.example.com/p43unify/ring-$tag/ch1/0.jpg">';
  }

  @override
  Future<String> fetchImageWithDecode(String url, String sourceJson) async {
    // 300ms 延迟（fake 时钟）：加载环态可被断言
    await Future<void>.delayed(const Duration(milliseconds: 300));
    return jsonEncode({'base64': _kPngBase64, 'len': 68});
  }
}

/// 图三：无书源、无 origin → 直连路径（CachedNetworkImage 骨架块）
class _NoSourceMockApi extends MockBookApi {
  _NoSourceMockApi(this.book, this.chapters, this.imageSrc);

  final Book book;
  final List<BookChapter> chapters;
  final String imageSrc;

  @override
  Future<List<BookSource>> getBookSources() async => const [];

  @override
  Future<Book?> getBook(String bookUrl) async => book;

  @override
  Future<List<BookChapter>> getChapters(String bookUrl) async => chapters;

  @override
  Future<String> fetchChapterContent(
    String bookUrl,
    String chapterUrl,
    String sourceUrl,
  ) async {
    return '<img src="$imageSrc">';
  }
}

Widget _buildApp(ProviderContainer container, {Brightness? brightness}) {
  const home = ReaderComicScreen(bookUrl: 'mock://comic/p43unify/ring');
  if (brightness == null) {
    return UncontrolledProviderScope(container: container, child: const MaterialApp(home: home));
  }
  final scheme = ColorScheme.fromSeed(seedColor: _kSeedColor, brightness: brightness);
  return UncontrolledProviderScope(
    container: container,
    child: MaterialApp(
      theme: ThemeData(colorScheme: scheme),
      home: home,
    ),
  );
}

/// 素材占位图定位器（与 reader_comic_error_placeholder_test 同式）
Finder _assetFinder() {
  // Image.asset 产物是 AssetImage（ImageProvider），按资产名匹配
  return find.byWidgetPredicate(
    (w) => w is Image &&
        w.image is AssetImage &&
        (w.image as AssetImage).assetName == _kErrorAsset,
  );
}

/// 加载环主题槽断言（dark/light 双主题各跑一次）
Future<void> _assertRingThemeSlots(WidgetTester tester, Brightness brightness) async {
  final tag = brightness.name;
  final api = _SlowDecodeMockApi(
    _book(
      origin: 'https://manga.example.com/p43unify/ring-$tag',
      url: 'mock://comic/p43unify/ring-$tag',
    ),
    _chapters('https://manga.example.com/p43unify/ring-$tag'),
    tag,
  );
  final container =
      ProviderContainer(overrides: [bookApiProvider.overrideWithValue(api)]);
  addTearDown(container.dispose);

  await tester.pumpWidget(_buildApp(container, brightness: brightness));

  // 等书籍级加载结束（LoadingIndicator 消失）→ 单页加载环接管
  var pumps = 0;
  while (tester.widgetList(find.byType(LoadingIndicator)).isNotEmpty && pumps < 20) {
    await tester.pump();
    pumps++;
  }
  expect(find.byType(LoadingIndicator), findsNothing, reason: '书籍级加载应已结束');
  expect(find.byType(CircularProgressIndicator), findsOneWidget,
      reason: '唯一不定长指示器应为单页加载环');

  final ring =
      tester.widget<CircularProgressIndicator>(find.byType(CircularProgressIndicator));
  expect(ring.color, isNull,
      reason: '环色应用主题槽（color == null → 主题 primary），'
          '非硬编码 0xFF666666');
  expect(ring.strokeWidth, 2.0,
      reason: '环宽 2 维持（2dp→4dp 宽度基线是 B4 项，不在本批）');

  // 加载态无整面底色（参考版 #2082：不整页压黑；原硬编码 0xFF1A1A1A）
  final holder = tester.widget<Container>(
    find.ancestor(
      of: find.byType(CircularProgressIndicator),
      matching: find.byType(Container),
    ).first,
  );
  expect(holder.color, isNull, reason: '加载占位不应有硬编码整面底色');

  // 让解码完成（fake 300ms + 引擎侧解码只在真实循环推进，
  // 同 reader_comic_chapter_error_test 的 _settleWithImageDecode 先例）
  await tester.pump(const Duration(milliseconds: 300));
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 300)),
  );
  await tester.pump();
  await tester.pump();
  expect(
    find.byWidgetPredicate((w) => w is Image && w.image is MemoryImage),
    findsOneWidget,
    reason: '解码完成后图片恢复显示',
  );
}

void main() {
  testWidgets('B2 加载环（dark 主题）：环用主题槽 + 无硬编码底色', (tester) async {
    await _assertRingThemeSlots(tester, Brightness.dark);
  });

  testWidgets('B2 加载环（light 主题）：环用主题槽（双主题一致）', (tester) async {
    await _assertRingThemeSlots(tester, Brightness.light);
  });

  testWidgets('B2 骨架块主题槽：块底/进度轨/进度填充改主题槽 + 去整面底色',
      (tester) async {
    final scheme =
        ColorScheme.fromSeed(seedColor: _kSeedColor, brightness: Brightness.dark);

    // 本机挂起 HTTP 服务器：下载恒定「进行中」→ 骨架块驻留（不依赖外网）
    // binding.runAsync 返回 Future<HttpServer?> → 需显式 ! 解包
    final server = (await tester.runAsync(startPendingImageServer))!;
    mockPathProvider(tester);
    final book = _book(origin: '', url: 'mock://comic/p43unify/skel');
    final api = _NoSourceMockApi(
      book,
      _chapters('http://127.0.0.1:${server.port}/p43unify/skel'),
      'http://127.0.0.1:${server.port}/p43unify/skel/ch1/0.jpg',
    );
    final container =
        ProviderContainer(overrides: [bookApiProvider.overrideWithValue(api)]);
    addTearDown(container.dispose);

    await tester.pumpWidget(_buildApp(container, brightness: Brightness.dark));
    // 骨架块接管需要若干微任务冲刷；树内含不定长指示器，勿用 pumpAndSettle
    var pumps = 0;
    while (tester.widgetList(_assetFinder()).isEmpty && pumps < 20) {
      await tester.pump();
      pumps++;
    }
    expect(_assetFinder(), findsOneWidget,
        reason: '骨架块图标位已换素材图（B1 三处之一，须先于本断言完成）');
    expect(find.byType(LinearProgressIndicator), findsOneWidget);

    // 块底（原硬编码 0xFF2A2A2A）→ surfaceContainerHighest
    final block = tester.widget<Container>(
      find.ancestor(of: _assetFinder(), matching: find.byType(Container)).first,
    );
    expect(block.decoration, isA<BoxDecoration>(),
        reason: '骨架块底色走 BoxDecoration（带圆角）');
    expect(
      (block.decoration! as BoxDecoration).color,
      scheme.surfaceContainerHighest,
      reason: '块底应用主题槽 surfaceContainerHighest'
          '（参考版 SkeletonPlaceholders.kt:54-56 取证），非硬编码 0xFF2A2A2A',
    );

    // 进度条：轨 → surfaceContainerHighest、填充 → 主题 primary
    //（原 0xFF2A2A2A / 0xFF666666）
    final lp = tester.widget<LinearProgressIndicator>(
      find.byType(LinearProgressIndicator),
    );
    expect(lp.backgroundColor, scheme.surfaceContainerHighest);
    expect(lp.valueColor?.value, scheme.primary);

    // 加载占位无整面底色（原硬编码 0xFF1A1A1A，参考版 #2082 同据）
    final outer = tester.widget<Container>(
      find.ancestor(
        of: find.byType(LinearProgressIndicator),
        matching: find.byType(Container),
      ).first,
    );
    expect(outer.color, isNull, reason: '骨架块外层不应有硬编码整面底色');
  });
}
