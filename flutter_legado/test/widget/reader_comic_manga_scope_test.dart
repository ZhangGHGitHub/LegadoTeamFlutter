// [漫画设置作用域 2026-10-01] 漫画屏「本书覆盖 + 全局回退」端到端接线
//
// 语义（用户裁决 + 参考版取证，legado-with-MD3）：
// - 有效值优先级：书级 readConfig.mangaScrollMode / webtoonSidePaddingDp
//   非 null 优先，否则全局 MangaConfigKeys.scrollMode / sidePadding
//   （MangaReaderViewModel.kt L1332-1334 `book?.scrollMode ?: settings.scrollMode`）；
// - 书级写入经现有 BookApi.updateBook + Book.copyWith(readConfig: ...)，
//   保留其他 readConfig 成员与进度/章节字段；
// - 切「跟随全局」= 清除对应 readConfig 键并立即回退全局值；
// - mangaLongClickSaveImage / mangaAutoReadSpeed / mangaClickActions
//   保持全局，只 setConfig，不产生书级 updateBook。
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/screens/reader_comic_screen.dart';
import 'package:flutter_legado/src/services/mock_book_api.dart';
import 'package:flutter_legado/src/widgets/manga/manga_config_sheet.dart';

/// 1x1 透明 PNG（RGBA，合法编码，同 reader_comic_scroll_mode_test）
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

Book _buildBook({
  ReadConfig? readConfig,
  int durChapterIndex = 0,
  int durChapterPos = 0,
  int chapterCount = 1,
}) {
  return Book(
    bookUrl: 'mock://comic/1',
    tocUrl: 'https://manga.example.com/comic/1/',
    name: '测试漫画',
    author: '作者',
    origin: 'https://manga.example.com',
    originName: '测试漫画源',
    canUpdate: true,
    totalChapterNum: chapterCount,
    durChapterIndex: durChapterIndex,
    durChapterPos: durChapterPos,
    readConfig: readConfig,
  );
}

/// [漫画设置作用域] Mock：可注入书籍（含 readConfig）/全局配置，
/// 记录 setConfig 与 updateBook 调用（区分全局键写入与书级回写）
class _ScopeMockApi extends MockBookApi {
  _ScopeMockApi({
    required this.source,
    Map<String, String>? configs,
    Book? book,
  })  : _configs = Map<String, String>.from(configs ?? const {}),
        _book = book;

  final BookSource source;
  final Map<String, String> _configs;
  Book? _book;

  /// 全局配置写入记录 [key, value]
  final List<List<String>> configWrites = [];

  /// 书级回写记录（updateBook）
  final List<Book> bookUpdates = [];

  final List<List<int>> progressCalls = [];

  @override
  Future<List<BookSource>> getBookSources() async => [source];

  @override
  Future<Book?> getBook(String bookUrl) async => _book;

  @override
  Future<void> updateBook(Book book) async {
    bookUpdates.add(book);
    _book = book;
  }

  @override
  Future<List<BookChapter>> getChapters(String bookUrl) async =>
      List<BookChapter>.generate(
        1,
        (i) => BookChapter(
          index: i,
          url: 'https://manga.example.com/comic/1/ch1.html',
          title: '第1章',
        ),
      );

  @override
  Future<String> fetchChapterContent(
    String bookUrl,
    String chapterUrl,
    String sourceUrl,
  ) async {
    return List.generate(
      3,
      (i) => '<p><img src="https://cdn.example.com/img/$i.jpg"></p>',
    ).join();
  }

  @override
  Future<String> fetchImageWithDecode(String url, String sourceJson) async {
    return jsonEncode({'base64': _kPngBase64, 'len': 68});
  }

  @override
  Future<String?> getConfig(String key) async => _configs[key];

  @override
  Future<void> setConfig(String key, String value) async {
    _configs[key] = value;
    configWrites.add([key, value]);
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

Widget _buildApp(ProviderContainer container) {
  return UncontrolledProviderScope(
    container: container,
    child: const MaterialApp(home: ReaderComicScreen(bookUrl: 'mock://comic/1')),
  );
}

Future<void> _pumpScreen(
  WidgetTester tester,
  _ScopeMockApi api,
  ProviderContainer container,
) async {
  await tester.pumpWidget(_buildApp(container));
  await tester.pumpAndSettle();
}

/// 打开漫画设置面板（中心点击 → 控制栏 → 「翻页设置」）
Future<void> _openSheet(WidgetTester tester) async {
  await tester.tapAt(const Offset(400, 300));
  await tester.pumpAndSettle();
  await tester.tap(find.byTooltip('翻页设置'));
  await tester.pumpAndSettle();
}

Axis _pageViewAxis(WidgetTester tester) =>
    tester.widget<PageView>(find.byType(PageView)).scrollDirection;

/// 条漫列表中每侧 sidePadding% 的水平 padding（测试视口 800×600）
Finder _sidePaddingWrapper(int percent) => find.byWidgetPredicate(
      (w) =>
          w is Padding &&
          w.padding ==
              EdgeInsets.symmetric(horizontal: 800.0 * percent / 100.0),
    );

void main() {
  group('[漫画设置作用域] 读取优先级', () {
    testWidgets('无书级字段 → 回退全局 mangaScrollMode', (tester) async {
      final api = _ScopeMockApi(
        source: _buildComicSource(),
        configs: const {'mangaScrollMode': '1'},
        book: _buildBook(),
      );
      final container = ProviderContainer(
        overrides: [bookApiProvider.overrideWithValue(api)],
      );
      addTearDown(container.dispose);
      await _pumpScreen(tester, api, container);

      expect(find.byType(PageView), findsOneWidget);
      expect(_pageViewAxis(tester), Axis.horizontal,
          reason: '全局 1（从左到右）→ 横向 PageView');
      expect(api.bookUpdates, isEmpty);
    });

    testWidgets('书级 mangaScrollMode 覆盖全局', (tester) async {
      final api = _ScopeMockApi(
        source: _buildComicSource(),
        // 全局 = 1（横向），书级 = 3（从上到下纵向）
        configs: const {'mangaScrollMode': '1'},
        book: _buildBook(
          readConfig: const ReadConfig(mangaScrollMode: 3),
        ),
      );
      final container = ProviderContainer(
        overrides: [bookApiProvider.overrideWithValue(api)],
      );
      addTearDown(container.dispose);
      await _pumpScreen(tester, api, container);

      expect(find.byType(PageView), findsOneWidget);
      expect(_pageViewAxis(tester), Axis.vertical,
          reason: '书级 3（从上到下）应覆盖全局 1');
    });

    testWidgets('书级 webtoonSidePaddingDp 覆盖全局 mangaSidePadding',
        (tester) async {
      final api = _ScopeMockApi(
        source: _buildComicSource(),
        configs: const {'mangaScrollMode': '4', 'mangaSidePadding': '0'},
        book: _buildBook(
          readConfig: const ReadConfig(webtoonSidePaddingDp: 20),
        ),
      );
      final container = ProviderContainer(
        overrides: [bookApiProvider.overrideWithValue(api)],
      );
      addTearDown(container.dispose);
      await _pumpScreen(tester, api, container);

      // 书级 20%（每侧 160px），全局 0% 不生效
      expect(_sidePaddingWrapper(20), findsOneWidget,
          reason: '书级留白 20% 应覆盖全局 0');
      expect(
        find.ancestor(
          of: find.byType(ListView),
          matching: _sidePaddingWrapper(20),
        ),
        findsOneWidget,
      );
    });

    testWidgets('非法书级翻页模式 → 降级为未覆盖，回退全局', (tester) async {
      final api = _ScopeMockApi(
        source: _buildComicSource(),
        configs: const {'mangaScrollMode': '1'},
        book: _buildBook(readConfig: const ReadConfig(mangaScrollMode: 99)),
      );
      final container = ProviderContainer(
        overrides: [bookApiProvider.overrideWithValue(api)],
      );
      addTearDown(container.dispose);
      await _pumpScreen(tester, api, container);

      expect(_pageViewAxis(tester), Axis.horizontal,
          reason: '非法书级模式按未覆盖处理，回退全局 1');
    });
  });

  group('[漫画设置作用域] 面板清除覆盖 → 立即回退全局', () {
    testWidgets('书级模式 3 → 点「跟随全局」：清除 readConfig 键并回退全局 1',
        (tester) async {
      final api = _ScopeMockApi(
        source: _buildComicSource(),
        configs: const {'mangaScrollMode': '1'},
        book: _buildBook(
          readConfig: const ReadConfig(
            mangaScrollMode: 3,
            reverseToc: true,
            dailyChapters: 7,
            playSpeed: 1.5,
          ),
          durChapterIndex: 0,
          durChapterPos: 1,
        ),
      );
      final container = ProviderContainer(
        overrides: [bookApiProvider.overrideWithValue(api)],
      );
      addTearDown(container.dispose);
      await _pumpScreen(tester, api, container);
      expect(_pageViewAxis(tester), Axis.vertical);

      await _openSheet(tester);
      await tester
          .tap(find.byKey(const ValueKey('mangaScrollMode-scopeGlobal')));
      await tester.pumpAndSettle();

      // 书级键被删除（清除覆盖，不写默认值冒充清除）
      expect(api.bookUpdates, hasLength(1));
      final updated = api.bookUpdates.single;
      expect(updated.readConfig?.mangaScrollMode, isNull);
      // 其他 readConfig 成员保留
      expect(updated.readConfig?.reverseToc, isTrue);
      expect(updated.readConfig?.dailyChapters, 7);
      expect(updated.readConfig?.playSpeed, 1.5);
      // 进度/章节字段保留
      expect(updated.durChapterIndex, 0);
      expect(updated.durChapterPos, 1);
      expect(updated.bookUrl, 'mock://comic/1');
      expect(updated.name, '测试漫画');

      // 立即回退全局 1（横向），且不写全局键（清除 ≠ 写入）
      expect(_pageViewAxis(tester), Axis.horizontal);
      expect(
        api.configWrites.where((w) => w.first == 'mangaScrollMode'),
        isEmpty,
        reason: '清除书级覆盖不应写全局 mangaScrollMode',
      );
    });

    testWidgets('书级留白 20 → 点「跟随全局」：清除键并回退全局 5',
        (tester) async {
      final api = _ScopeMockApi(
        source: _buildComicSource(),
        configs: const {'mangaScrollMode': '4', 'mangaSidePadding': '5'},
        book: _buildBook(
          readConfig: const ReadConfig(webtoonSidePaddingDp: 20),
        ),
      );
      final container = ProviderContainer(
        overrides: [bookApiProvider.overrideWithValue(api)],
      );
      addTearDown(container.dispose);
      await _pumpScreen(tester, api, container);
      expect(_sidePaddingWrapper(20), findsOneWidget);

      await _openSheet(tester);
      await tester
          .tap(find.byKey(const ValueKey('mangaSidePadding-scopeGlobal')));
      await tester.pumpAndSettle();

      expect(api.bookUpdates, hasLength(1));
      expect(api.bookUpdates.single.readConfig?.webtoonSidePaddingDp, isNull);
      // 立即回退全局 5%（每侧 40px）
      expect(_sidePaddingWrapper(5), findsOneWidget);
      expect(_sidePaddingWrapper(20), findsNothing);
    });
  });

  group('[漫画设置作用域] 书级写入语义', () {
    testWidgets('点「本书」物化覆盖：保留其他 readConfig/进度字段，仅加目标键',
        (tester) async {
      final api = _ScopeMockApi(
        source: _buildComicSource(),
        configs: const {'mangaScrollMode': '2'},
        book: _buildBook(
          readConfig: const ReadConfig(
            reverseToc: true,
            dailyChapters: 7,
            playSpeed: 1.5,
            webtoonSidePaddingDp: 10,
          ),
          durChapterIndex: 0,
          durChapterPos: 2,
        ),
      );
      final container = ProviderContainer(
        overrides: [bookApiProvider.overrideWithValue(api)],
      );
      addTearDown(container.dispose);
      await _pumpScreen(tester, api, container);
      // 书级模式为空：跟随全局 2（从右到左 → 横向 PageView）
      expect(_pageViewAxis(tester), Axis.horizontal);

      await _openSheet(tester);
      await tester
          .tap(find.byKey(const ValueKey('mangaScrollMode-scopeBook')));
      await tester.pumpAndSettle();

      expect(api.bookUpdates, hasLength(1));
      final updated = api.bookUpdates.single;
      // 书级字段 = 当前有效值（全局 2）
      expect(updated.readConfig?.mangaScrollMode, 2);
      // 其他 readConfig 成员逐项保留
      expect(updated.readConfig?.reverseToc, isTrue);
      expect(updated.readConfig?.dailyChapters, 7);
      expect(updated.readConfig?.playSpeed, 1.5);
      expect(updated.readConfig?.webtoonSidePaddingDp, 10);
      // 进度/章节字段保留
      expect(updated.durChapterIndex, 0);
      expect(updated.durChapterPos, 2);
      // 全局键未因书级写入而改动
      expect(
        api.configWrites.where((w) => w.first == 'mangaScrollMode'),
        isEmpty,
      );
    });

    testWidgets('「本书」作用下改模式只回写书级 readConfig（不 setConfig）',
        (tester) async {
      final api = _ScopeMockApi(
        source: _buildComicSource(),
        configs: const {'mangaScrollMode': '4'},
        book: _buildBook(readConfig: const ReadConfig(mangaScrollMode: 4)),
      );
      final container = ProviderContainer(
        overrides: [bookApiProvider.overrideWithValue(api)],
      );
      addTearDown(container.dispose);
      await _pumpScreen(tester, api, container);

      await _openSheet(tester);
      await tester.tap(find.text('单页式（从左到右）'));
      await tester.pumpAndSettle();

      expect(api.bookUpdates, hasLength(1));
      expect(api.bookUpdates.single.readConfig?.mangaScrollMode, 1);
      expect(
        api.configWrites.where((w) => w.first == 'mangaScrollMode'),
        isEmpty,
        reason: '书级作用域下不应写全局 mangaScrollMode',
      );
      // 屏内立即切换为横向 PageView
      expect(_pageViewAxis(tester), Axis.horizontal);
    });
  });

  group('[漫画设置作用域] 三项全局键仍只 setConfig（不产生书级回写）',
      () {
    testWidgets('长按存图 / 自动速度 / 九区点击动作 → 仅全局 setConfig',
        (tester) async {
      final api = _ScopeMockApi(
        source: _buildComicSource(),
        configs: const {'mangaScrollMode': '1'},
        book: _buildBook(readConfig: const ReadConfig(reverseToc: true)),
      );
      final container = ProviderContainer(
        overrides: [bookApiProvider.overrideWithValue(api)],
      );
      addTearDown(container.dispose);
      await _pumpScreen(tester, api, container);

      await _openSheet(tester);
      final panelList = find.descendant(
        of: find.byType(MangaConfigSheet),
        matching: find.byType(ListView),
      );

      // 1) 自动翻页开关 + 速度滑杆（速度档只写全局 mangaAutoReadSpeed；
      //    「自动翻页」文本同时出现在区块标题与开关行 → 用 SwitchListTile 定位）
      final autoSwitch = find.widgetWithText(SwitchListTile, '自动翻页');
      await tester.ensureVisible(autoSwitch);
      await tester.pumpAndSettle();
      await tester.tap(autoSwitch);
      await tester.pumpAndSettle();
      final autoTile =
          find.ancestor(of: find.text('自动速度'), matching: find.byType(Column)).first;
      final speedSlider =
          find.descendant(of: autoTile, matching: find.byType(Slider));
      await tester.ensureVisible(speedSlider);
      await tester.pumpAndSettle();
      await tester.drag(speedSlider, const Offset(600, 0));
      await tester.pumpAndSettle();
      // 关闭自动翻页，避免会话定时器悬挂（速度滑杆 ensureVisible 后开关行
      // 已滚出视口上沿 → 先滚回可见再点）
      await tester.ensureVisible(autoSwitch);
      await tester.pumpAndSettle();
      await tester.tap(autoSwitch);
      await tester.pumpAndSettle();
      expect(
        api.configWrites.any((w) => w.first == 'mangaAutoReadSpeed'),
        isTrue,
        reason: '自动速度应写全局 mangaAutoReadSpeed',
      );

      // 2) 长按保存图片（默认 true → false；仅全局 setConfig）
      await tester.dragUntilVisible(
        find.text('长按保存图片'),
        panelList,
        const Offset(0, -250),
      );
      // dragUntilVisible 末尾的 ensureVisible 为 jump（无动画），须 pump
      // 让滚动落定后再取坐标点击
      await tester.pumpAndSettle();
      await tester.tap(find.text('长按保存图片'));
      await tester.pumpAndSettle();
      expect(
        api.configWrites.any(
          (w) => w.first == 'mangaLongClickSaveImage' && w[1] == 'false',
        ),
        isTrue,
      );

      // 3) 九区点击动作（点击格循环切换；仅全局 setConfig）
      await tester.dragUntilVisible(
        find.byKey(const ValueKey('mangaClickActionCell-0')),
        panelList,
        const Offset(0, -250),
      );
      await tester.pumpAndSettle();
      await tester
          .tap(find.byKey(const ValueKey('mangaClickActionCell-0')));
      await tester.pumpAndSettle();
      expect(
        api.configWrites.any((w) => w.first == 'mangaClickActions'),
        isTrue,
      );

      // 三项均未产生书级 updateBook
      expect(api.bookUpdates, isEmpty,
          reason: '长按存图/自动速度/九区点击动作保持全局，不得书级回写');
    });
  });
}
