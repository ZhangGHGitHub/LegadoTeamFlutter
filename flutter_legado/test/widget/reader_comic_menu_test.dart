// [P4-3 M2] 漫画菜单按用户截图重构（实心顶栏 + 两段底栏 + 目录 sheet）
//
// 视觉基准 = 用户截图（参考版 APK kazusa 3.26.15；本地参考源码快照滞后，
// 仅取语义与颜色角色依据，形态以截图为准）：
// - 顶栏 MangaMenuTopBar：实心 surfaceContainer 背景（浅色浅灰/暗色自动暗）、
//   Row1 返回 + 刷新 + 更多（more_vert，= 打开页操作底栏；换源无功能
//   不放 E8）、Row2 书名大字 24sp + 次行章节名 + 源名（右端，
//   取证 Book.originName / BookSource.bookSourceName，URL 形态不显）；
// - 底栏 MangaMenuBottomBar 两段分离（非 M1 一体化悬浮面板）：
//   进度行 = 左右圆形白钮（surface 底 + 阴影、skip_previous/skip_next
//   图标，替换 M1 箭头）+ 中间白色胶囊内 Slider（自绘竖条 thumb
//   primary、轨道透明、divisions 点串 primary）；贴底白条 = 全宽
//   surface 三键均布（目录/自动/设置齿轮，自动开启时图标 primary 蓝）；
// - 目录 = 模态 bottom sheet（章节列表 tab：虚拟化列表 + 当前章高亮 +
//   点击跳章）。
//
// 本测试覆盖 6 个对齐点（M2 调整 + 新增 3 断言）：
// 1. 顶栏：实心背景（surfaceContainer，【新增断言】）+ 书名/章节名/
//    源名 + 返回/刷新/更多键（刷新 = 先收菜单再重取当前章）；
// 2. 底栏两段结构：进度行（上一章 skip_previous/滑条/下一章 skip_next，
//    【新增断言】skip 图标）+ 贴底白条（目录/自动/翻页设置 三键均布）；
// 3. 自动键点击切换自动翻页开关，键描述 自动/停止 随开关态切换，
//    【新增断言】图标状态着色（关 onSurface / 开 primary）；
// 4. 目录 sheet：标题「目录(N)」+ 当前章高亮 + 点击跳章（进度写入）；
// 5. 滑条拖动 → 跳页（单页式 PageView 动画落定，页脚页数更新）；
// 6. 主题化：暗色主题下顶栏背景 = surfaceContainer（暗）、
//    圆钮/胶囊/白条 = surface 族（非恒黑）。
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_symbols_icons/symbols.dart';

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
  group('[P4-3 M2] 漫画菜单按用户截图重构', () {
    testWidgets(
        '① 顶栏：实心背景 + 书名/章节名/源名 + 返回/刷新/更多（刷新 = 收菜单 + 重取）',
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

      // 顶栏 = 实心 AppBar 式：背景行（返回 + 刷新 + 更多）+
      // 标题区（书名大字 + 章节名 + 源名次行）
      final topBar = find.byType(MangaMenuTopBar);
      expect(topBar, findsOneWidget);
      expect(
        find.descendant(of: topBar, matching: find.text('测试漫画')),
        findsOneWidget,
        reason: '标题区第一行 = 书名大字',
      );
      expect(
        find.descendant(of: topBar, matching: find.text('第1章')),
        findsOneWidget,
        reason: '标题区次行左端 = 章节名',
      );
      expect(
        find.descendant(of: topBar, matching: find.text('测试漫画源')),
        findsOneWidget,
        reason: '标题区次行右端 = 源名（bookSourceName 取证值）',
      );
      expect(find.byTooltip('返回'), findsOneWidget);
      expect(find.byTooltip('刷新'), findsOneWidget);
      expect(
        find.byTooltip('更多'),
        findsOneWidget,
        reason: '右上图标组 = 刷新 + 更多（换源无功能不放，E8 登记）',
      );

      // 【M2 新增断言③】顶栏实心背景 = surfaceContainer（主题化，非恒黑）
      final scheme = Theme.of(tester.element(topBar)).colorScheme;
      final topBarBg = tester.widget<Container>(
        find.descendant(of: topBar, matching: find.byType(Container)).first,
      );
      expect(
        topBarBg.color,
        scheme.surfaceContainer,
        reason: '实心顶栏背景应取 surfaceContainer（浅色 = 浅灰）',
      );
      // 【M3 修1】背景 Container 为最外层、SafeArea 在内作内容 padding
      //（背景覆盖状态栏区，不再从状态栏下方才开始漏黑条）
      expect(
        topBarBg.child,
        isA<SafeArea>(),
        reason: 'M3 修1：顶栏背景 Container 的直接子应是 SafeArea（背景不裁状态栏区）',
      );
      // 【M3 修1】贴底白条背景 Container 同构（覆盖底部安全区直至屏幕底缘）
      final whiteBar = tester.widget<Container>(
        find.descendant(
          of: find.byType(MangaMenuBottomBar),
          matching: find.byWidgetPredicate(
            (w) => w is Container && w.color == scheme.surface,
          ),
        ).first,
      );
      expect(
        whiteBar.child,
        isA<SafeArea>(),
        reason: 'M3 修1：白条背景 Container 的直接子应是 SafeArea（背景不裁底部安全区）',
      );

      // 刷新键：先收起菜单，再重取当前章（fetchChapterContent 次数 +1）
      final before = fetchCalls.length;
      await tester.tap(find.byTooltip('刷新'));
      await tester.pumpAndSettle();
      expect(find.text('测试漫画'), findsNothing,
          reason: '刷新后菜单应收起（对齐参考版 setMenuVisible(false)）');
      expect(fetchCalls.length, greaterThan(before),
          reason: '刷新键应触发当前章正文重取（invalidateCurrentChapter）');
    });

    testWidgets(
        '② 底栏两段结构：进度行（上一章/滑条/下一章）+ 贴底白条（目录/自动/翻页设置）',
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
      // 段1 进度行：上一章 / 页进度滑条（白色胶囊内）/ 下一章
      expect(
        find.descendant(of: bottomBar, matching: find.byTooltip('上一章')),
        findsOneWidget);
      expect(
        find.descendant(of: bottomBar, matching: find.byTooltip('下一章')),
        findsOneWidget);
      expect(find.byType(Slider), findsOneWidget);
      // 【M2 新增断言①】进度行圆形白钮图标 = Symbols.skip 系列
      // （替换 M1 箭头；find.byTooltip 命中 Tooltip 本体，
      // 图标须经 descendant 定位其 Icon 子件）
      final prevIcon = tester.widget<Icon>(
        find.descendant(
          of: find.byTooltip('上一章'),
          matching: find.byType(Icon),
        ),
      );
      expect(prevIcon.icon, Symbols.skip_previous_rounded,
          reason: '上一章圆钮 = skip_previous（|◀）');
      final nextIcon = tester.widget<Icon>(
        find.descendant(
          of: find.byTooltip('下一章'),
          matching: find.byType(Icon),
        ),
      );
      expect(nextIcon.icon, Symbols.skip_next_rounded,
          reason: '下一章圆钮 = skip_next（▶|）');
      // 段2 贴底白条：目录 / 自动 / 翻页设置（三键均布）
      expect(
        find.descendant(of: bottomBar, matching: find.byTooltip('目录')),
        findsOneWidget);
      expect(
        find.descendant(of: bottomBar, matching: find.byTooltip('自动')),
        findsOneWidget);
      expect(
        find.descendant(of: bottomBar, matching: find.byTooltip('翻页设置')),
        findsOneWidget);

      // 两段分离：白条（目录键）整体在进度行（上一章键）之下
      expect(
        tester.getTopLeft(find.byTooltip('目录')).dy,
        greaterThan(tester.getTopLeft(find.byTooltip('上一章')).dy),
        reason: '贴底白条应在悬浮进度行之下（两段分离，非一体化面板）',
      );
      // 白条三键均布（spaceEvenly）：目录最左、翻页设置最右、自动居中
      final tocX = tester.getTopLeft(find.byTooltip('目录')).dx;
      final autoX = tester.getTopLeft(find.byTooltip('自动')).dx;
      final settingsX = tester.getTopLeft(find.byTooltip('翻页设置')).dx;
      expect(tocX, lessThan(autoX));
      expect(settingsX, greaterThan(autoX));

      // [P4-3 M2b] 自绘点串层：胶囊内 Slider 下层 CustomPaint（标准
      // tickMark 密度门禁下 50 页级章节整串不绘制，点串改自绘均布）
      expect(
        find.descendant(of: bottomBar, matching: find.byType(CustomPaint)),
        findsOneWidget,
        reason: '进度胶囊内应有自绘点串层（CustomPaint，位于 Slider 下层）',
      );

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

      // 关态：键描述 = 「自动」，图标着色 = onSurface
      expect(find.byTooltip('自动'), findsOneWidget);
      expect(find.byTooltip('停止'), findsNothing);
      final scheme =
          Theme.of(tester.element(find.byType(MangaMenuBottomBar)))
              .colorScheme;
      final autoIconOff = tester.widget<Icon>(
        find.descendant(
          of: find.byTooltip('自动'),
          matching: find.byType(Icon),
        ),
      );
      expect(
        autoIconOff.color,
        scheme.onSurface,
        reason: '【M2 新增断言②】自动键关态图标 = onSurface（默认色）',
      );
      // 【M3 修3】自动键图标 = auto_stories（打开的书本样式，用户确认
      // 参考版底栏中间键形态；替换 M2 auto_mode）
      expect(
        autoIconOff.icon,
        Symbols.auto_stories_rounded,
        reason: 'M3 修3：自动键图标应为 auto_stories 书本样式',
      );

      // 点击 → 开：描述切换为「停止」；控制栏显示期间自动翻页暂停
      //（对齐参考版 LaunchedEffect 依赖 menuVisible：守卫内不翻页）
      await tester.tap(find.byTooltip('自动'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('停止'), findsOneWidget,
          reason: '开启后键描述 = 停止（再点停止）');
      // 【M2 新增断言②】开态图标状态着色 = primary 蓝（截图基准）
      final autoIconOn = tester.widget<Icon>(
        find.descendant(
          of: find.byTooltip('停止'),
          matching: find.byType(Icon),
        ),
      );
      expect(
        autoIconOn.color,
        scheme.primary,
        reason: '自动键开启时图标应变 primary 蓝（截图状态着色）',
      );
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
        reason: '顶栏标题区章节名应更新为第 2 章',
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

    testWidgets('⑥ 暗色主题：顶栏 = surfaceContainer（暗）、圆钮/胶囊/白条 = surface 族',
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

      // 【M2】顶栏实心背景 = surfaceContainer（暗色自动暗，非恒黑）
      final topBarBg = tester.widget<Container>(
        find.descendant(
          of: find.byType(MangaMenuTopBar),
          matching: find.byType(Container),
        ).first,
      );
      expect(
        topBarBg.color,
        darkTheme.colorScheme.surfaceContainer,
        reason: '暗色主题实心顶栏应取 surfaceContainer（暗色表面）',
      );

      // 进度行圆钮（surface 底，decoration 承载）×2 + 白色胶囊 ×1
      final circleFinder = find.descendant(
        of: find.byType(MangaMenuBottomBar),
        matching: find.byWidgetPredicate(
          (w) =>
              w is Container &&
              w.decoration is BoxDecoration &&
              (w.decoration as BoxDecoration).color ==
                  darkTheme.colorScheme.surface,
        ),
      );
      expect(
        circleFinder,
        findsNWidgets(3),
        reason: '暗色主题下圆钮×2 + 白色胶囊应取 surface 族（非恒白）',
      );

      // 贴底白条（color 属性承载）= surface（暗色）
      final whiteBarFinder = find.descendant(
        of: find.byType(MangaMenuBottomBar),
        matching: find.byWidgetPredicate(
          (w) => w is Container && w.color == darkTheme.colorScheme.surface,
        ),
      );
      expect(
        whiteBarFinder,
        findsOneWidget,
        reason: '贴底白条应取 surface（暗色表面，非恒白）',
      );
    });
  });
}
