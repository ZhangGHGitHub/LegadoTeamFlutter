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
///
/// [W2-fix] 新增 [chapterCount] / [durChapterIndex] 注入（R2L 边界与切章
/// 落点用例需要多章 + 指定起始章）
class _ScrollModeMockApi extends MockBookApi {
  _ScrollModeMockApi({
    required this.source,
    required this.progressCalls,
    Map<String, String>? configs,
    this.durChapterPos = 0,
    this.durChapterIndex = 0,
    this.imageCount = 3,
    this.chapterCount = 1,
  }) : _configs = configs ?? {};

  final BookSource source;
  /// 进度写入记录 [[chapterIndex, chapterPos], ...]
  final List<List<int>> progressCalls;
  final Map<String, String> _configs;
  final int durChapterPos;
  final int durChapterIndex;
  final int imageCount;
  final int chapterCount;
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
        totalChapterNum: chapterCount,
        durChapterIndex: durChapterIndex,
        durChapterPos: durChapterPos,
      );

  @override
  Future<List<BookChapter>> getChapters(String bookUrl) async =>
      List<BookChapter>.generate(
        chapterCount,
        (i) => BookChapter(
          index: i,
          url: 'https://manga.example.com/comic/1/ch${i + 1}.html',
          title: '第${i + 1}章',
        ),
      );

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
    int durChapterIndex = 0,
    int imageCount = 3,
    int chapterCount = 1,
    required List<List<int>> progressCalls,
  }) {
    return _ScrollModeMockApi(
      source: _buildComicSource(),
      progressCalls: progressCalls,
      configs: configs,
      durChapterPos: durChapterPos,
      durChapterIndex: durChapterIndex,
      imageCount: imageCount,
      chapterCount: chapterCount,
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

  // ---------------------------------------------------------------------------
  // [P4-3 W2-fix] 独立审查（STAGE-REVIEW-P43W2）P0 修复回归
  //
  // 取证（参考版）：
  // - P0-1：MangaReaderViewModel.kt L1127-1143 requestPageStep 按**逻辑页**
  //   判边界（nextPageItemIndex null → openRelativeChapter）；R2L 布局
  //   （导航页占显示索引 0、真实页占 1..n）下旧实现的 display 换算判定
  //   全错：第 2 页点上一页被误判边界直接切上一章、第 1 页点上一页
  //   animateToPage(n+1) 越界永不切章、末页点下一页落到导航页。
  // - P0-2：MangaReaderViewModel openChapter(index, pageIndex = 0) 新章
  //   恒从 0 页开始；旧实现 _goToChapter 不递增 _loadSeq，切章后
  //   PageView 重挂落回控制器构造时 initialPage（旧章恢复页）。
  // ---------------------------------------------------------------------------
  group('[P4-3 W2-fix] R2L 边界与切章落点（P0）', () {
    // 测试视口 800x600，默认九区 clickActions：
    // 右上(667,100) 区2 → action 1 下一页；左中(133,300) 区3 → action 2 上一页。

    testWidgets('R2L 首页（逻辑页 0）点上一页 = 切上一章（P0-1）',
        (tester) async {
      final progressCalls = <List<int>>[];
      // 模式 2（R2L）+ 两章，从第 2 章章首进入（durChapterIndex = 1）
      final api = buildApi(
        configs: const {'mangaScrollMode': '2'},
        durChapterIndex: 1,
        chapterCount: 2,
        progressCalls: progressCalls,
      );
      final container = ProviderContainer(
        overrides: [bookApiProvider.overrideWithValue(api)],
      );
      addTearDown(container.dispose);
      await pumpScreen(tester, api, container);

      expect(find.textContaining('章节2/2'), findsOneWidget);
      expect(find.textContaining('页数1/3'), findsOneWidget,
          reason: 'R2L 起始 = 逻辑页 0（阅读首页）');

      // 左中区（区3，action 2）= 上一页；逻辑页 0 已是章首 → 切上一章
      await tester.tapAt(const Offset(133, 300));
      await tester.pumpAndSettle();
      expect(find.textContaining('章节1/2'), findsOneWidget,
          reason: 'R2L 首页点上一页应切上一章'
              '（旧实现 display 换算误判为可翻，animateToPage 越界不切章）');
    });

    testWidgets('R2L 逻辑第 2 页点上一页 = 去第 1 页（P0-1）',
        (tester) async {
      final progressCalls = <List<int>>[];
      final api = buildApi(
        configs: const {'mangaScrollMode': '2'},
        durChapterIndex: 1,
        chapterCount: 2,
        progressCalls: progressCalls,
      );
      final container = ProviderContainer(
        overrides: [bookApiProvider.overrideWithValue(api)],
      );
      addTearDown(container.dispose);
      await pumpScreen(tester, api, container);

      // 逻辑页 0 → 点下一页 → 逻辑页 1（R2L 阅读「下一页」= 逻辑页 +1）
      await tester.tapAt(const Offset(667, 100));
      await tester.pumpAndSettle();
      expect(find.textContaining('页数2/3'), findsOneWidget);

      // 逻辑页 1 点上一页 = 回逻辑页 0（非切章）
      await tester.tapAt(const Offset(133, 300));
      await tester.pumpAndSettle();
      expect(find.textContaining('页数1/3'), findsOneWidget,
          reason: 'R2L 逻辑第 2 页点上一页应回第 1 页');
      expect(find.textContaining('章节2/2'), findsOneWidget,
          reason: '不应误切上一章'
              '（旧实现把 display n-1 当 R2L 上一页边界 → 直接切章）');
    });

    testWidgets('R2L 末页（逻辑页 n-1）点下一页 = 切下一章（P0-1）',
        (tester) async {
      final progressCalls = <List<int>>[];
      final api = buildApi(
        configs: const {'mangaScrollMode': '2'},
        chapterCount: 2,
        progressCalls: progressCalls,
      );
      final container = ProviderContainer(
        overrides: [bookApiProvider.overrideWithValue(api)],
      );
      addTearDown(container.dispose);
      await pumpScreen(tester, api, container);

      // 逻辑页 0 → 1 → 2（末页）
      await tester.tapAt(const Offset(667, 100));
      await tester.pumpAndSettle();
      await tester.tapAt(const Offset(667, 100));
      await tester.pumpAndSettle();
      expect(find.textContaining('页数3/3'), findsOneWidget);

      // 末页点下一页 → 切下一章（新章章首）
      await tester.tapAt(const Offset(667, 100));
      await tester.pumpAndSettle();
      expect(find.textContaining('章节2/2'), findsOneWidget,
          reason: 'R2L 末页点下一页应切下一章'
              '（旧实现控制器方向取反后落到导航页，永不切章）');
      expect(find.textContaining('页数1/3'), findsOneWidget,
          reason: '新章恒从章首开始');
    });

    testWidgets('带页级进度恢复进入：切章落点 = 0 页（P0-2）',
        (tester) async {
      final progressCalls = <List<int>>[];
      // L2R 单页 + 记录页 2（durChapterPos > 0 的常态恢复进入）
      final api = buildApi(
        configs: const {'mangaScrollMode': '1'},
        durChapterPos: 2,
        chapterCount: 2,
        progressCalls: progressCalls,
      );
      final container = ProviderContainer(
        overrides: [bookApiProvider.overrideWithValue(api)],
      );
      addTearDown(container.dispose);
      await pumpScreen(tester, api, container);

      expect(find.textContaining('页数3/3'), findsOneWidget,
          reason: '恢复进入应定位到记录页（页索引 2）');

      // 末页点下一页 → 切下一章
      await tester.tapAt(const Offset(667, 100));
      await tester.pumpAndSettle();
      expect(find.textContaining('章节2/2'), findsOneWidget);
      expect(find.textContaining('页数1/3'), findsOneWidget,
          reason: '切章应落新章第 0 页（对齐参考版 openChapter(index, 0)）'
              '（旧实现控制器代数未失效，切章后落回旧章恢复页）');
      // 页脚文本由 _visiblePageIndex 驱动、切章后可能被掩盖，须再验
      // PageView 控制器**实际停靠页**（旧实现旧控制器代数未失效，
      // 新章重挂后按旧偏移 1600px 停靠 → 实际仍停在第 3 页）
      final pagedPos = tester
          .state<ScrollableState>(
            find.descendant(
              of: find.byType(PageView),
              matching: find.byType(Scrollable),
            ).first,
          )
          .position;
      expect(
        pagedPos.pixels / pagedPos.viewportDimension,
        closeTo(0, 0.5),
        reason: '新章须恒从第 0 页停靠（参考版 openChapter(index, 0)）',
      );
      expect(progressCalls, contains(equals([1, 0])),
          reason: '新章章首进度应落库');
    });
  });
}
