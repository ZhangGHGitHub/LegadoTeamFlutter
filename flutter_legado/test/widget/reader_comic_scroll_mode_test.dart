// [P4-3 E1] 漫画屏五翻页模式（对齐参考版 MangaScrollMode）
//
// 取证（参考版，legado-with-MD3）：
// - ui/book/manga/config/MangaScrollMode.kt L3-9：
//   PAGE_LEFT_TO_RIGHT=1 / PAGE_RIGHT_TO_LEFT=2 / PAGE_TOP_TO_BOTTOM=3 /
//   WEBTOON=4 / WEBTOON_WITH_GAP=5；
// - ui/book/manga/MangaReaderContract.kt L117：默认 WEBTOON=4；
// - ui/book/manga/MangaReaderScreen.kt L263-268：L2R/R2L → HorizontalMangaPager
//   （L941 reverseLayout=R2L），T2B → VerticalMangaPager，其余 → WebtoonMangaList；
//   L506/508/807-809：WEBTOON_WITH_GAP 页面间 8.dp 间距；
// - ui/book/manga/MangaSettingsPanel.kt 阅读模式下拉：
//   [条漫, 条漫（间隔）, 从左到右, 从右到左, 从上到下] = [4, 5, 1, 2, 3]。
//
// 本测试验证：
// 1. 默认（未配置）= 条漫 4：ListView 连续滚动路径，无 PageView；
// 2. 条漫带间距 5：仍为 ListView，页间 8px 间距（4+4 包裹 Padding）；
// 3. 单页式 L2R(1)：横向 PageView，左滑 → 下一页；
// 4. 单页式 R2L(2)：横向 PageView，首页在右（显示索引反转），右滑 → 下一页；
// 5. 单页式 T2B(3)：纵向 PageView，上滑 → 下一页；
// 6. 页级进度：单页模式翻页 chapterPos=页索引（精确）；
// 7. 页级进度恢复：durChapterPos 在单页模式下定位到记录页。
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/screens/reader_comic_screen.dart';
import 'package:flutter_legado/src/services/mock_book_api.dart';

/// 1x1 透明 PNG（解码结果 base64，同 reader_comic_decode_test）
const _kPngBase64 =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGNgYGBgAAAABQAB'
    'h6FO1AAAAABJRU5ErkJggg==';

/// 含 imageDecode 规则的漫画书源（对齐 favcomic 形态）
BookSource _buildComicSource() {
  return BookSource(
    bookSourceUrl: 'https://manga.example.com',
    bookSourceName: '测试漫画源',
    bookSourceGroup: '漫画',
    bookSourceType: 2,
    enabled: true,
    ruleContent: ContentRule(
      content: '.x',
      imageDecode: 'decode(result);',
    ),
    customOrder: 0,
    lastUpdateTime: 0,
    respondTime: 0,
    weight: 0,
  );
}

/// [P4-3 E1] 测试 Mock：可注入滚动模式配置 / 记录进度写入 / 控制图片数量
class _ScrollModeMockApi extends MockBookApi {
  _ScrollModeMockApi({
    required this.source,
    required this.progressCalls,
    Map<String, String>? configs,
    this.durChapterPos = 0,
    this.imageCount = 3,
  }) : _configs = configs ?? {};

  final BookSource source;
  /// 进度写入记录 [[chapterIndex, chapterPos], ...]
  final List<List<int>> progressCalls;
  final Map<String, String> _configs;
  final int durChapterPos;
  final int imageCount;
  final List<String> decodeCalls = [];

  @override
  Future<List<BookSource>> getBookSources() async => [source];

  @override
  Future<Book?> getBook(String bookUrl) async => Book(
        bookUrl: bookUrl,
        tocUrl: 'https://manga.example.com/comic/1/',
        name: '测试漫画',
        author: '作者',
        origin: source.bookSourceUrl,
        originName: source.bookSourceName,
        canUpdate: true,
        totalChapterNum: 1,
        durChapterPos: durChapterPos,
      );

  @override
  Future<List<BookChapter>> getChapters(String bookUrl) async => [
        BookChapter(
          index: 0,
          url: 'https://manga.example.com/comic/1/ch1.html',
          title: '第一章',
        ),
      ];

  @override
  Future<String> fetchChapterContent(
    String bookUrl,
    String chapterUrl,
    String sourceUrl,
  ) async {
    return List.generate(
      imageCount,
      (i) => '<p><img src="https://cdn.example.com/img/$i.jpg"></p>',
    ).join();
  }

  @override
  Future<String> fetchImageWithDecode(String url, String sourceJson) async {
    decodeCalls.add(url);
    return jsonEncode({'base64': _kPngBase64, 'len': 68});
  }

  @override
  Future<String?> getConfig(String key) async => _configs[key];

  @override
  Future<void> setConfig(String key, String value) async {
    _configs[key] = value;
  }

  @override
  Future<void> updateReadingProgress({
    required String bookUrl,
    required int chapterIndex,
    required int chapterPos,
  }) async {
    progressCalls.add([chapterIndex, chapterPos]);
  }
}

void main() {
  Widget buildApp(ProviderContainer container) {
    return UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: ReaderComicScreen(bookUrl: 'mock://comic/1')),
    );
  }

  _ScrollModeMockApi buildApi({
    Map<String, String>? configs,
    int durChapterPos = 0,
    int imageCount = 3,
    required List<List<int>> progressCalls,
  }) {
    return _ScrollModeMockApi(
      source: _buildComicSource(),
      progressCalls: progressCalls,
      configs: configs,
      durChapterPos: durChapterPos,
      imageCount: imageCount,
    );
  }

  Future<void> pumpScreen(
    WidgetTester tester,
    _ScrollModeMockApi api,
    ProviderContainer container,
  ) async {
    await tester.pumpWidget(buildApp(container));
    // 等待异步加载（getBook → getChapters → fetchChapterContent → 解码渲染）
    await tester.pumpAndSettle();
  }

  group('[P4-3 E1] 五翻页模式', () {
    testWidgets('默认未配置 = 条漫(4)：ListView 连续滚动路径，无 PageView',
        (tester) async {
      final progressCalls = <List<int>>[];
      final api = buildApi(progressCalls: progressCalls);
      final container = ProviderContainer(
        overrides: [bookApiProvider.overrideWithValue(api)],
      );
      addTearDown(container.dispose);
      await pumpScreen(tester, api, container);

      // 条漫模式走既有 ListView 路径（磁盘缓存/预载/缩放不动）
      expect(find.byType(ListView), findsWidgets);
      expect(find.byType(PageView), findsNothing);
      // 图片已解码渲染（FFI 链路生效）
      expect(api.decodeCalls, isNotEmpty);
    });

    testWidgets('模式 5 条漫（间隔）：ListView 页间 8px 间距', (tester) async {
      final progressCalls = <List<int>>[];
      final api = buildApi(
        configs: const {'mangaScrollMode': '5'},
        progressCalls: progressCalls,
      );
      final container = ProviderContainer(
        overrides: [bookApiProvider.overrideWithValue(api)],
      );
      addTearDown(container.dispose);
      await pumpScreen(tester, api, container);

      // 仍为 ListView 路径（带间距）
      expect(find.byType(ListView), findsWidgets);
      expect(find.byType(PageView), findsNothing);
      // 参考版 Arrangement.spacedBy(8.dp)：页间 8px（4px 上 + 4px 下包裹）
      final gapPaddings = tester
          .widgetList<Padding>(
            find.byWidgetPredicate(
              (w) =>
                  w is Padding &&
                  w.padding ==
                      const EdgeInsets.symmetric(vertical: 4),
            ),
          )
          .toList();
      expect(gapPaddings, isNotEmpty,
          reason: '条漫（间隔）应在页项之间加 8px（4+4）间距');
    });

    testWidgets('模式 1 从左到右：横向 PageView，左滑 → 下一页',
        (tester) async {
      final progressCalls = <List<int>>[];
      final api = buildApi(
        configs: const {'mangaScrollMode': '1'},
        progressCalls: progressCalls,
      );
      final container = ProviderContainer(
        overrides: [bookApiProvider.overrideWithValue(api)],
      );
      addTearDown(container.dispose);
      await pumpScreen(tester, api, container);

      // 横向分页（PageView），无条漫 ListView
      expect(find.byType(PageView), findsOneWidget);
      expect(find.byType(ListView), findsNothing);

      // 初始页 = 页 0：页脚「页数1/3」（buildLabel 输出无空格，同既有进度测试）
      expect(find.textContaining('页数1/3'), findsOneWidget);

      // 左滑 → 页 1
      await tester.fling(
        find.byType(PageView),
        const Offset(-200, 0),
        600,
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('页数2/3'), findsOneWidget);

      // 页级进度：chapterPos = 页索引（精确值，非比例估算）
      expect(progressCalls, contains(equals([0, 1])));
    });

    testWidgets('模式 2 从右到左：首页在右，右滑 → 下一页', (tester) async {
      final progressCalls = <List<int>>[];
      final api = buildApi(
        configs: const {'mangaScrollMode': '2'},
        progressCalls: progressCalls,
      );
      final container = ProviderContainer(
        overrides: [bookApiProvider.overrideWithValue(api)],
      );
      addTearDown(container.dispose);
      await pumpScreen(tester, api, container);

      expect(find.byType(PageView), findsOneWidget);
      // 初始页 = 页 0（R2L 首页显示在最右，页脚同样显示 1/3）
      expect(find.textContaining('页数1/3'), findsOneWidget);

      // 右滑（内容向右移，露出左侧页面）→ 页 1
      await tester.fling(
        find.byType(PageView),
        const Offset(200, 0),
        600,
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('页数2/3'), findsOneWidget);
      expect(progressCalls, contains(equals([0, 1])));
    });

    testWidgets('模式 3 从上到下：纵向 PageView，上滑 → 下一页',
        (tester) async {
      final progressCalls = <List<int>>[];
      final api = buildApi(
        configs: const {'mangaScrollMode': '3'},
        progressCalls: progressCalls,
      );
      final container = ProviderContainer(
        overrides: [bookApiProvider.overrideWithValue(api)],
      );
      addTearDown(container.dispose);
      await pumpScreen(tester, api, container);

      expect(find.byType(PageView), findsOneWidget);
      expect(find.byType(ListView), findsNothing);
      expect(find.textContaining('页数1/3'), findsOneWidget);

      // 上滑 → 页 1
      await tester.fling(
        find.byType(PageView),
        const Offset(0, -300),
        600,
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('页数2/3'), findsOneWidget);
      expect(progressCalls, contains(equals([0, 1])));
    });

    testWidgets('页级进度恢复：单页模式下定位到 durChapterPos 记录页',
        (tester) async {
      final progressCalls = <List<int>>[];
      final api = buildApi(
        configs: const {'mangaScrollMode': '1'},
        durChapterPos: 2,
        progressCalls: progressCalls,
      );
      final container = ProviderContainer(
        overrides: [bookApiProvider.overrideWithValue(api)],
      );
      addTearDown(container.dispose);
      await pumpScreen(tester, api, container);

      // 重开定位到记录页（页索引 2）：页脚「页数3/3」
      expect(find.textContaining('页数3/3'), findsOneWidget);
    });

    testWidgets('条漫模式进度恢复：durChapterPos 按可见页估算定位（不回退旧行为）',
        (tester) async {
      final progressCalls = <List<int>>[];
      // 条漫默认模式 4 + 记录页 2
      final api = buildApi(durChapterPos: 2, progressCalls: progressCalls);
      final container = ProviderContainer(
        overrides: [bookApiProvider.overrideWithValue(api)],
      );
      addTearDown(container.dispose);
      await pumpScreen(tester, api, container);

      // 条漫路径：ListView + 恢复后页脚显示估算页（页 2 → 「页数3/3」）
      expect(find.byType(ListView), findsWidgets);
      expect(find.textContaining('页数3/3'), findsOneWidget);
    });
  });
}
