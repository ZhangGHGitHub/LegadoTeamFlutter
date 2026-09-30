import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/screens/reader_comic_screen.dart';
import 'package:flutter_legado/src/services/mock_book_api.dart';
import 'package:flutter_test/flutter_test.dart';

import 'comic_test_helpers.dart';

/// [STAGE-UI-P43UNIFY1 B1] 漫画图片加载失败/占位形态断言
///
/// 取证（参考版 legado-with-MD3，docs/LOADING_ASSETS_UNIFY_SURVEY_20260930.md
/// §2.4/§3.3）：
/// - 图片加载失败形态 = 直接显示 `image_loading_error.png` 素材图（原版
///   `res/drawable/image_loading_error.png` 6933B；参考版
///   ImageProvider.kt:39 阅读错误 bitmap、PhotoDialog.kt:61 /
///   PhotoSheet.kt:57 / VerificationCodeDialog.kt:91 Coil `.error()`），
///   而非图标代替；
/// - 漫画单页失败态 = 55% 黑罩 + 居中重试按钮（MangaReaderScreen.kt
///   MangaImageLoadOverlay，`Color.Black.copy(alpha = 0.55f)`）。
///
/// 我方三处 `Icons.broken_image`/`Icons.image` 图标引用（骨架块 /
/// 双错误占位）改用同名素材图（Image.asset，64px 保留原图标位），
/// 失败占位底色对齐参考版 55% 黑罩。
const String _kErrorAsset = 'assets/images/image_loading_error.png';

Book _book({
  String origin = 'https://manga.example.com',
  String url = 'mock://comic/p43unify/err',
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

/// 素材占位图定位器（Image.asset 路径断言，不依赖图片实际解码完成）
Finder _assetFinder() {
  // Image.asset 产物是 AssetImage（ImageProvider），按资产名匹配
  return find.byWidgetPredicate(
    (w) => w is Image &&
        w.image is AssetImage &&
        (w.image as AssetImage).assetName == _kErrorAsset,
  );
}

/// 图一：有书源，FFI 解码链路 `fetchImageWithDecode` 抛异常
/// （页项经 `_DecodedComicImage` 失败 → 父级 `_failedIndices` 标记 →
/// `_buildImageErrorPlaceholder` 展示重试形态；解码异常文案本身不驻留，
/// 落定态为固定文案「图片加载失败」+ 重试）。
class _FailingDecodeMockApi extends MockBookApi {
  _FailingDecodeMockApi(this.book, this.chapters, this.imageSrc);

  final Book book;
  final List<BookChapter> chapters;
  final String imageSrc;

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
    return '<img src="$imageSrc">';
  }

  @override
  Future<String> fetchImageWithDecode(String url, String sourceJson) async {
    throw StateError('图片解码失败（模拟）');
  }
}

/// 图二/三：无书源。
/// - [book.origin] 非空 → 直连被禁（密文/防盗链语义），页项直接进
///   `_buildImageErrorPlaceholder`；
/// - [book.origin] 为空 → 走 CachedNetworkImage 直连（加载占位 = 骨架块）。
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

Widget _buildApp(ProviderContainer container) {
  return UncontrolledProviderScope(
    container: container,
    child: const MaterialApp(
      home: ReaderComicScreen(bookUrl: 'mock://comic/p43unify/err'),
    ),
  );
}

void main() {
  testWidgets('B1 图一：FFI 解码失败 → 错误占位用素材图 + 55% 黑底 + 重试',
      (tester) async {
    final book = _book(origin: 'https://manga.example.com/p43unify/err');
    final api = _FailingDecodeMockApi(
      book,
      _chapters('https://manga.example.com/p43unify/err'),
      'https://cdn.example.com/p43unify/err/ch1/0.jpg',
    );
    final container =
        ProviderContainer(overrides: [bookApiProvider.overrideWithValue(api)]);
    addTearDown(container.dispose);

    await tester.pumpWidget(_buildApp(container));
    await tester.pumpAndSettle();

    // 解码失败 → 页项进错误占位（固定文案「图片加载失败」+ 重试按钮）
    expect(find.text('图片加载失败'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);

    // 图标位已换为素材图（对齐参考版失败形态），且不再出现 broken_image 图标
    expect(_assetFinder(), findsOneWidget);
    final img = tester.widget<Image>(_assetFinder());
    expect(img.width, 64, reason: '素材图保留原图标 64px 位，不放大不拉伸');
    expect(find.byIcon(Icons.broken_image), findsNothing,
        reason: 'broken_image 图标引用应已替换为素材图');

    // 失败占位底色 = 55% 黑罩（参考版 MangaReaderScreen.kt
    // MangaImageLoadOverlay 取证），非硬编码 0xFF1A1A1A
    final holder = tester.widget<Container>(
      find.ancestor(of: _assetFinder(), matching: find.byType(Container)).first,
    );
    expect(holder.color, Colors.black.withValues(alpha: 0.55),
        reason: '失败占位底色应对齐参考版 55% 黑罩');
  });

  testWidgets('B1 图二：无书源（origin 非空）→ 直连禁用语义错误占位同形态',
      (tester) async {
    final book = _book(
      origin: 'https://manga.example.com',
      url: 'mock://comic/p43unify/nosrc',
    );
    final api = _NoSourceMockApi(
      book,
      _chapters('https://manga.example.com/p43unify/nosrc'),
      'https://cdn.example.com/p43unify/nosrc/ch1/0.jpg',
    );
    final container =
        ProviderContainer(overrides: [bookApiProvider.overrideWithValue(api)]);
    addTearDown(container.dispose);

    await tester.pumpWidget(_buildApp(container));
    await tester.pumpAndSettle();

    // 有 origin 却无书源：页项直接进错误占位（固定文案 + 重试）
    expect(find.text('图片加载失败'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
    expect(_assetFinder(), findsOneWidget);

    // 同图一形态：素材图 + 55% 黑底
    final holder = tester.widget<Container>(
      find.ancestor(of: _assetFinder(), matching: find.byType(Container)).first,
    );
    expect(holder.color, Colors.black.withValues(alpha: 0.55));
  });

  testWidgets('B1 图三：无书源无 origin → 直连链路骨架块图标位换素材',
      (tester) async {
    // 本机挂起 HTTP 服务器：下载恒定「进行中」→ 骨架块驻留（不依赖外网）
    // binding.runAsync 返回 Future<HttpServer?> → 需显式 ! 解包
    final server = (await tester.runAsync(startPendingImageServer))!;
    mockPathProvider(tester);
    final book = _book(origin: '', url: 'mock://comic/p43unify/nosrc2');
    final api = _NoSourceMockApi(
      book,
      _chapters('http://127.0.0.1:${server.port}/p43unify/nosrc2'),
      'http://127.0.0.1:${server.port}/p43unify/nosrc2/ch1/0.jpg',
    );
    final container =
        ProviderContainer(overrides: [bookApiProvider.overrideWithValue(api)]);
    addTearDown(container.dispose);

    await tester.pumpWidget(_buildApp(container));
    // 骨架块接管需要若干微任务冲刷（章节加载完成 → 页项构建 → 加载占位）；
    // 树内含不定长加载指示器，勿用 pumpAndSettle，改有界 pump
    var pumps = 0;
    while (tester.widgetList(_assetFinder()).isEmpty && pumps < 20) {
      await tester.pump();
      pumps++;
    }

    // 骨架块内图标位（原 Icons.image）已换素材图
    expect(_assetFinder(), findsOneWidget,
        reason: '骨架块图标位应替换为素材图（B1 三处之一）');
    // 骨架块保留确定性进度条（进度非空时显示 % 文案）
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
  });
}
