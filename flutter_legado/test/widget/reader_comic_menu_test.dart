// [P4-3 M1] 漫画菜单对齐参考版（顶栏胶囊 + 两行悬浮底栏 + 目录 sheet）
//
// 取证（参考版，legado-with-MD3）：
// - MangaReaderOverlays.kt L208-257 MangaMenuTopBar：透明悬浮顶栏 =
//   返回圆钮 + 标题胶囊（书名/章名双行）+ 合并操作胶囊；
//   L259-317 MangaTitleCapsule：高 40 stadium、surfaceContainerLow；
// - L424-649 MangaMenuBottomBar 悬浮形态：圆角面板（surfaceContainerHigh
//   + 1dp outlineVariant 描边）两行——Row1 上一章/页进度滑条/下一章，
//   Row2 目录/自动（停止）/翻页设置（SpaceBetween 均布）；
// - L678-742 MangaMenuIconButton：40dp 圆钮 surfaceContainerLow 背景；
// - 目录 = 模态 bottom sheet（ReaderBookSheet L279-374，72% 屏高，
//   章节列表 tab：虚拟化列表 + 当前章高亮 + 点击跳章）。
//
// 本测试覆盖 6 个对齐点：
// 1. 顶栏：书名/章名胶囊 + 返回/刷新键（刷新 = 先收菜单再重取当前章）；
// 2. 底栏两行结构（上一章/滑条/下一章 + 目录/自动/翻页设置 三键均布）；
// 3. 自动键点击切换自动翻页开关，键描述 自动/停止 随开关态切换；
// 4. 目录 sheet：标题「目录(N)」+ 当前章高亮 + 点击跳章（进度写入）；
// 5. 滑条拖动 → 跳页（单页式 PageView 动画落定，页脚页数更新）；
// 6. 主题化：暗色主题下底栏面板 = surfaceContainerHigh 族、
//    胶囊 = surfaceContainerLow（非恒黑）。
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/screens/reader_comic/manga_menu.dart';
import 'package:flutter_legado/src/screens/reader_comic_screen.dart';
import 'package:flutter_legado/src/services/mock_book_api.dart';

/// 1x1 透明 PNG（合法 68 字节编码；同 auto_read/page_scale 先例）
const _kPngBase64 =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAC0lEQVR4nGNgAAIAAAUAAXpeqz8'
    'AAAAASUVORK5CYII=';

/// 菜单对齐测试 Mock：可注入配置/章节数，记录进度写入、配置写入与
/// 章节正文抓取（刷新键断言 fetchChapterContent 次数）
class _MenuMockApi extends MockBookApi {
  _MenuMockApi({
    required this.progressCalls,
    required this.configWrites,
    required this.fetchCalls,
    Map<String, String>? configs,
    this.chapterCount = 3,
  }) : _configs = configs ?? {};

  /// 每章图片数（与既有漫画 mock 一致取 3，保证滑条/单页式有页可跳）
  static const int imageCount = 3;

  /// 进度写入记录 [chapterIndex, chapterPos]
  final List<List<int>> progressCalls;

  /// 配置写入记录 [key, value]
  final List<List<String>> configWrites;

  /// 章节正文抓取记录（章节 URL；刷新键应使当前章 +1 次）
  final List<String> fetchCalls;

  final Map<String, String> _configs;
  final int chapterCount;

  @override
  Future<List<BookSource>> getBookSources() async => [
        BookSource(
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
        ),
      ];

  @override
  Future<Book?> getBook(String bookUrl) async => Book(
        bookUrl: bookUrl,
        tocUrl: 'https://manga.example.com/comic/1/',
        name: '测试漫画',
        author: '作者',
        origin: 'https://manga.example.com',
        originName: '测试漫画源',
        canUpdate: true,
        totalChapterNum: chapterCount,
        durChapterPos: 0,
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
    fetchCalls.add(chapterUrl);
    return List.generate(
      imageCount,
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

  @override
  Future<List<int>?> getImageCache(String bookUrl, String url) async => null;
}

/// 当前测试表面逻辑尺寸的正中点（九区中心 = 菜单显隐，同 auto_read 先例）
Offset _centerOffset(WidgetTester tester) {
  final logical = tester.view.physicalSize / tester.view.devicePixelRatio;
  return Offset(logical.width / 2, logical.height / 2);
}

/// 打开阅读器并等待首屏加载完成
Future<void> _pumpScreen(
  WidgetTester tester,
  _MenuMockApi api,
  ProviderContainer container, {
  ThemeData? theme,
}) async {
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: theme,
        home: ReaderComicScreen(bookUrl: 'mock://menu'),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// 中心点击 → 控制栏（菜单）显示
Future<void> _showControls(WidgetTester tester) async {
  await tester.tapAt(_centerOffset(tester));
  await tester.pumpAndSettle();
}

void main() {
  group('[P4-3 M1] 漫画菜单对齐参考版', () {
    testWidgets('① 顶栏：书名/章名胶囊 + 返回/刷新键（刷新 = 收菜单 + 重取）',
        (tester) async {
      final progressCalls = <List<int>>[];
      final configWrites = <List<String>>[];
      final fetchCalls = <String>[];
      final api = _MenuMockApi(
        progressCalls: progressCalls,
        configWrites: configWrites,
        fetchCalls: fetchCalls,
      );
      final container = ProviderContainer(
        overrides: [bookApiProvider.overrideWithValue(api)],
      );
      addTearDown(container.dispose);
      await _pumpScreen(tester, api, container);

      // 隐藏态：菜单子树不在树中（动画落定后移除）
      expect(find.text('测试漫画'), findsNothing);

      await _showControls(tester);

      // 顶栏 = 透明悬浮胶囊行：书名/章名胶囊 + 返回圆钮 + 刷新键
      final topBar = find.byType(MangaMenuTopBar);
      expect(topBar, findsOneWidget);
      expect(
        find.descendant(of: topBar, matching: find.text('测试漫画')),
        findsOneWidget,
        reason: '标题胶囊第一行 = 书名',
      );
      expect(
        find.descendant(of: topBar, matching: find.text('第1章')),
        findsOneWidget,
        reason: '标题胶囊第二行 = 章名',
      );
      expect(find.byTooltip('返回'), findsOneWidget);
      expect(find.byTooltip('刷新'), findsOneWidget);

      // 亮色主题（默认）：胶囊背景 = surfaceContainerLow（主题化，非恒黑）
      final scheme = Theme.of(tester.element(topBar)).colorScheme;
      final capsule = tester.widget<Container>(
        find.descendant(
          of: topBar,
          matching: find.byWidgetPredicate(
            (w) =>
                w is Container &&
                (w.decoration as BoxDecoration?)?.color ==
                    scheme.surfaceContainerLow,
          ),
        ).first,
      );
      expect(capsule.decoration, isA<BoxDecoration>());

      // 刷新键：先收起菜单，再重取当前章（fetchChapterContent 次数 +1）
      final before = fetchCalls.length;
      await tester.tap(find.byTooltip('刷新'));
      await tester.pumpAndSettle();
      expect(find.text('测试漫画'), findsNothing,
          reason: '刷新后菜单应收起（对齐参考版 setMenuVisible(false)）');
      expect(fetchCalls.length, greaterThan(before),
          reason: '刷新键应触发当前章正文重取（invalidateCurrentChapter）');
    });

    testWidgets('② 底栏两行结构：上一章/滑条/下一章 + 目录/自动/翻页设置',
        (tester) async {
      final progressCalls = <List<int>>[];
      final api = _MenuMockApi(
        progressCalls: progressCalls,
        configWrites: <List<String>>[],
        fetchCalls: <String>[],
      );
      final container = ProviderContainer(
        overrides: [bookApiProvider.overrideWithValue(api)],
      );
      addTearDown(container.dispose);
      await _pumpScreen(tester, api, container);

      await _showControls(tester);

      final bottomBar = find.byType(MangaMenuBottomBar);
      expect(bottomBar, findsOneWidget);
      // Row1：上一章 / 页进度滑条 / 下一章
      expect(
        find.descendant(of: bottomBar, matching: find.byTooltip('上一章')),
        findsOneWidget);
      expect(
        find.descendant(of: bottomBar, matching: find.byTooltip('下一章')),
        findsOneWidget);
      expect(find.byType(Slider), findsOneWidget);
      // Row2：目录 / 自动 / 翻页设置
      expect(
        find.descendant(of: bottomBar, matching: find.byTooltip('目录')),
        findsOneWidget);
      expect(
        find.descendant(of: bottomBar, matching: find.byTooltip('自动')),
        findsOneWidget);
      expect(
        find.descendant(of: bottomBar, matching: find.byTooltip('翻页设置')),
        findsOneWidget);

      // 两行结构：Row1 整体在 Row2 之上
      expect(
        tester.getTopLeft(find.byTooltip('目录')).dy,
        greaterThan(tester.getTopLeft(find.byTooltip('上一章')).dy),
        reason: '目录行应在页进度行之下',
      );
      // Row2 三键均布（SpaceBetween）：目录最左、翻页设置最右、自动居中
      final tocX = tester.getTopLeft(find.byTooltip('目录')).dx;
      final autoX = tester.getTopLeft(find.byTooltip('自动')).dx;
      final settingsX = tester.getTopLeft(find.byTooltip('翻页设置')).dx;
      expect(tocX, lessThan(autoX));
      expect(settingsX, greaterThan(autoX));

      // 滑条参数：0 基页索引，max = pageCount-1，divisions = pageCount-1
      final slider = tester.widget<Slider>(find.byType(Slider));
      expect(slider.min, 0.0);
      expect(slider.max, 2.0, reason: '3 图 → 滑条最大值 = 页索引 2');
      expect(slider.divisions, 2, reason: '3 页 → 3-1 个分段（整页吸附）');
      expect(slider.onChanged, isNotNull, reason: 'pageCount > 1 时可拖');
    });

    testWidgets('③ 自动键点击切换自动翻页，键描述 自动/停止 随开关态',
        (tester) async {
      final progressCalls = <List<int>>[];
      final api = _MenuMockApi(
        progressCalls: progressCalls,
        configWrites: <List<String>>[],
        fetchCalls: <String>[],
      );
      final container = ProviderContainer(
        overrides: [bookApiProvider.overrideWithValue(api)],
      );
      addTearDown(container.dispose);
      await _pumpScreen(tester, api, container);

      await _showControls(tester);

      // 关态：键描述 = 「自动」
      expect(find.byTooltip('自动'), findsOneWidget);
      expect(find.byTooltip('停止'), findsNothing);

      // 点击 → 开：描述切换为「停止」；控制栏显示期间自动翻页暂停
      //（对齐参考版 LaunchedEffect 依赖 menuVisible：守卫内不翻页）
      await tester.tap(find.byTooltip('自动'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('停止'), findsOneWidget,
          reason: '开启后键描述 = 停止（再点停止）');
      expect(find.textContaining('页数1/3'), findsOneWidget,
          reason: '控制栏显示期间自动翻页应暂停（页不前进）');

      // 再点 → 关：描述切回「自动」，定时器取消
      await tester.tap(find.byTooltip('停止'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('自动'), findsOneWidget);
      expect(find.byTooltip('停止'), findsNothing);
      expect(find.textContaining('页数1/3'), findsOneWidget);
    });

    testWidgets('④ 目录 sheet：目录(N) + 当前章高亮 + 点击跳章',
        (tester) async {
      final progressCalls = <List<int>>[];
      final api = _MenuMockApi(
        progressCalls: progressCalls,
        configWrites: <List<String>>[],
        fetchCalls: <String>[],
        chapterCount: 3,
      );
      final container = ProviderContainer(
        overrides: [bookApiProvider.overrideWithValue(api)],
      );
      addTearDown(container.dispose);
      await _pumpScreen(tester, api, container);

      await _showControls(tester);
      await tester.tap(find.byTooltip('目录'));
      await tester.pumpAndSettle();

      // 标题 = 目录(N)，N = 章节数（对齐参考版 chapter_list_size）
      expect(find.text('目录(3)'), findsOneWidget);

      // 当前章（第1章）高亮：primaryContainer 底 + primary 文字 w600；
      // 非当前章无背景
      final currentTile = find.widgetWithText(InkWell, '第1章');
      expect(currentTile, findsOneWidget);
      final currentBox = tester.widget<Container>(
        find.descendant(
          of: currentTile,
          matching: find.byType(Container),
        ).first,
      );
      expect((currentBox.decoration as BoxDecoration?)?.color, isNotNull,
          reason: '当前章行应有高亮背景');
      final currentTitle = tester.widget<Text>(
        find.descendant(of: currentTile, matching: find.text('第1章')),
      );
      expect(currentTitle.style?.fontWeight, FontWeight.w600,
          reason: '当前章标题加粗');
      final otherTile = find.widgetWithText(InkWell, '第2章');
      final otherBox = tester.widget<Container>(
        find.descendant(
          of: otherTile,
          matching: find.byType(Container),
        ).first,
      );
      expect(otherBox.decoration, isNull, reason: '非当前章行无高亮背景');

      // 点击第 2 章 → 关 sheet + 跳章（页脚 章节2/3 + 进度写入 [1, 0]）
      await tester.tap(otherTile);
      await tester.pumpAndSettle();
      expect(find.text('目录(3)'), findsNothing, reason: '跳章后 sheet 应关闭');
      expect(find.textContaining('章节2/3'), findsOneWidget,
          reason: '应跳到第 2 章（页脚章节计数更新）');
      expect(
        find.descendant(
          of: find.byType(MangaMenuTopBar),
          matching: find.text('第2章'),
        ),
        findsOneWidget,
        reason: '顶栏标题胶囊章名应更新为第 2 章',
      );
      expect(progressCalls, contains(equals([1, 0])),
          reason: '新章章首进度 [chapterIndex=1, chapterPos=0] 应落库');
    });

    testWidgets('⑤ 滑条拖动 → 跳页（单页式 PageView 落定，页脚更新）',
        (tester) async {
      final progressCalls = <List<int>>[];
      final api = _MenuMockApi(
        progressCalls: progressCalls,
        configWrites: <List<String>>[],
        fetchCalls: <String>[],
        configs: {'mangaScrollMode': '1'}, // 单页式（L2R）
      );
      final container = ProviderContainer(
        overrides: [bookApiProvider.overrideWithValue(api)],
      );
      addTearDown(container.dispose);
      await _pumpScreen(tester, api, container);

      expect(find.textContaining('页数1/3'), findsOneWidget);
      await _showControls(tester);

      // 从滑条中心拖到最右（divisions=2 → 吸附到末页索引 2）
      final slider = find.byType(Slider);
      final size = tester.getSize(slider);
      await tester.drag(slider, Offset(size.width / 2, 0));
      await tester.pumpAndSettle();

      // 落到末页：页脚 页数3/3 + 页级进度 [0, 2] 写入
      expect(find.textContaining('页数3/3'), findsOneWidget,
          reason: '滑条拖到最右应跳到末页');
      expect(progressCalls, contains(equals([0, 2])),
          reason: '跳末页应写入页级进度（章 0、页索引 2）');
    });

    testWidgets('⑥ 暗色主题：底栏 = surfaceContainerHigh 族、胶囊 = Low',
        (tester) async {
      final progressCalls = <List<int>>[];
      final api = _MenuMockApi(
        progressCalls: progressCalls,
        configWrites: <List<String>>[],
        fetchCalls: <String>[],
      );
      final darkTheme = ThemeData(brightness: Brightness.dark);
      final container = ProviderContainer(
        overrides: [bookApiProvider.overrideWithValue(api)],
      );
      addTearDown(container.dispose);
      await _pumpScreen(tester, api, container, theme: darkTheme);

      await _showControls(tester);

      // 底栏悬浮面板 = surfaceContainerHigh（75% 不透明度）
      final panel = tester.widget<Container>(
        find.descendant(
          of: find.byType(MangaMenuBottomBar),
          matching: find.byWidgetPredicate(
            (w) =>
                w is Container && w.decoration is BoxDecoration),
        ).first,
      );
      final panelDecoration = panel.decoration as BoxDecoration;
      expect(
        panelDecoration.color,
        equals(darkTheme.colorScheme.surfaceContainerHigh
            .withValues(alpha: 0.75)),
        reason: '暗色主题底栏面板应取 surfaceContainerHigh 族（非恒黑）',
      );
      expect(panelDecoration.border, isA<Border>());
      expect(
        (panelDecoration.border as Border).top.color,
        equals(darkTheme.colorScheme.outlineVariant),
        reason: '底栏描边 = outlineVariant',
      );

      // 顶栏胶囊（圆钮/标题胶囊背景）= surfaceContainerLow（暗色）
      final capsuleFinder = find.descendant(
        of: find.byType(MangaMenuTopBar),
        matching: find.byWidgetPredicate(
          (w) =>
              w is Container &&
              (w.decoration as BoxDecoration?)?.color ==
                  darkTheme.colorScheme.surfaceContainerLow,
        ),
      );
      expect(capsuleFinder, findsWidgets,
          reason: '暗色主题下胶囊背景应跟随主题 surfaceContainerLow');
    });
  });
}
