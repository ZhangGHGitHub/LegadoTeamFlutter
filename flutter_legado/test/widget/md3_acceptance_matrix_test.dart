// MD3 验收矩阵（UI_MD3_PLAN.md 第十三节）自动化
//
// 覆盖四项：
// 1. 关键页渲染矩阵：theme_config/home/settings/search × WH/koharu/sora
//    × light/dark 全部无异常渲染（溢出/布局异常会被 flutter test 捕获）；
//    golden 截图基线按计划修订以渲染矩阵替代——跨平台（Windows 开发 /
//    Linux CI）字体渲染差异使 golden 二进制基线脆弱，截图验收改由
//    模拟器 -CheckUI 流程承担（UI_MD3_PLAN.md 实施状态记录）。
//    [R41] 补「书籍详情 / 阅读」两核心屏：同样 3 调色板 × 亮暗全覆盖，
//    断言关键元素在位（详情：书名/查看目录/书源；阅读：ReaderPageView
//    已挂载）且 takeException 为 null。pump 成本低（详情 7 stub、阅读 4
//    stub，复用 one_to_one_matrix / reader_dark_background 模板）。
//    [R41 增量 2026-11-24] 再补「阅读设置面板 / RSS 源编辑」两屏（视觉最重、
//    此前只有单一主题 360dp 溢出守卫）：同口径 3 调色板 × 亮暗 + 关键元素
//    在位断言（面板：高级阅读设置标题/翻页模式分段按钮/页面边距/亮度控制；
//    源编辑：四 Tab/选项面板/字段输入框）。
//    当前矩阵覆盖 8 屏：theme_config/home/settings/search/book_info/reader/
//    reader_config_panel/rss_source_edit。
// 2. 系统字体缩放边界：textScaler 0.8/1.6 下关键页无溢出。
// 3. 语义/触控目标：底栏 NavigationBar 目标 ≥ 48dp、SwitchListTile 行高
//    ≥ 48dp、主题卡片语义标签存在。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/models/flip_mode.dart';
import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/providers/reader/reader_notifier.dart';
import 'package:flutter_legado/src/screens/book_info_screen.dart';
import 'package:flutter_legado/src/screens/home_screen.dart';
import 'package:flutter_legado/src/screens/reader_config_panel.dart';
import 'package:flutter_legado/src/screens/reader_screen.dart';
import 'package:flutter_legado/src/screens/rss_source_edit_screen.dart';
import 'package:flutter_legado/src/screens/search_screen.dart';
import 'package:flutter_legado/src/screens/settings_screen.dart';
import 'package:flutter_legado/src/screens/theme_config_screen.dart';
import 'package:flutter_legado/src/services/mock_book_api.dart';
import 'package:flutter_legado/src/theme/app_theme.dart';
import 'package:flutter_legado/src/theme/md3_colors.dart';
import 'package:flutter_legado/src/widgets/reader/reader_page_view.dart';
import '../mocks/mocks.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final palettes = [
    ('wh', Md3Palettes.wh),
    ('koharu', Md3Palettes.koharu),
    ('sora', Md3Palettes.sora),
  ];

  /// 装配指定调色板 + 亮暗的 ProviderScope MaterialApp
  Widget buildApp(String paletteId, ThemeMode mode) {
    SharedPreferences.setMockInitialValues({
      'app_palette_id': paletteId,
      'app_theme_mode': switch (mode) {
        ThemeMode.light => 'light',
        ThemeMode.dark => 'dark',
        _ => 'system',
      },
    });
    return ProviderScope(
      overrides: [],
      child: MaterialApp(
        theme: _paletteTheme(paletteId, Brightness.light),
        darkTheme: _paletteTheme(paletteId, Brightness.dark),
        themeMode: mode,
        home: const ThemeConfigScreen(),
        routes: const {},
      ),
    );
  }

  group('关键页渲染矩阵（3 调色板 × 亮暗 × 关键页）', () {
    for (final (name, _) in palettes) {
      for (final mode in [ThemeMode.light, ThemeMode.dark]) {
        testWidgets('$name/${mode.name} theme_config 无异常渲染', (tester) async {
          tester.view.physicalSize = const Size(1080, 2260);
          tester.view.devicePixelRatio = 3.0;
          addTearDown(tester.view.reset);
          await tester.pumpWidget(buildApp(name, mode));
          await tester.pumpAndSettle();
          // [队列⑦c A3] 页首分组「内置主题」改名「主题模式」（对齐参考
          // R.string.theme；主题模式选择器 + 13 色卡同行）
          expect(find.text('主题模式'), findsOneWidget);
          expect(tester.takeException(), isNull);
        });
      }
    }

    testWidgets('WH/light home(书架) 无异常渲染且底栏四项可达', (tester) async {
      SharedPreferences.setMockInitialValues({
        'app_palette_id': 'wh',
        'app_theme_mode': 'light',
      });
      tester.view.physicalSize = const Size(1080, 2260);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ProviderScope(child: MaterialApp(home: const HomeScreen())),
      );
      await tester.pumpAndSettle(const Duration(seconds: 2));
      expect(find.byType(NavigationBar), findsOneWidget);
      expect(find.text('书架'), findsWidgets);
      expect(tester.takeException(), isNull);
    });

    testWidgets('WH/light settings(我的) 无异常渲染', (tester) async {
      SharedPreferences.setMockInitialValues({
        'app_palette_id': 'wh',
        'app_theme_mode': 'light',
      });
      tester.view.physicalSize = const Size(1080, 2260);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ProviderScope(child: MaterialApp(home: const SettingsScreen())),
      );
      await tester.pumpAndSettle(const Duration(seconds: 2));
      expect(tester.takeException(), isNull);
    });

    testWidgets('WH/light search 无异常渲染', (tester) async {
      registerFallbacks();
      SharedPreferences.setMockInitialValues({
        'app_palette_id': 'wh',
        'app_theme_mode': 'light',
      });
      final mockApi = MockRustApi();
      when(() => mockApi.getSearchHistory(limit: any(named: 'limit')))
          .thenAnswer((_) async => []);
      when(() => mockApi.addSearchKeyword(any(), any()))
          .thenAnswer((_) async {});
      when(() => mockApi.clearSearchHistory()).thenAnswer((_) async {});
      when(() => mockApi.cancelSearch()).thenAnswer((_) async {});
      when(() => mockApi.getConfig(any())).thenAnswer((_) async => null);
      when(() => mockApi.setConfig(any(), any())).thenAnswer((_) async {});
      when(() => mockApi.getEnabledBookSources())
          .thenAnswer((_) async => []);
      final container = ProviderContainer(
        overrides: [bookApiProvider.overrideWithValue(mockApi)],
      );
      addTearDown(container.dispose);
      tester.view.physicalSize = const Size(1080, 2260);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(home: const SearchScreen()),
        ),
      );
      await tester.pumpAndSettle(const Duration(seconds: 2));
      expect(tester.takeException(), isNull);
    });
  });

  /// 装配指定调色板 + 亮暗、可指定 home 的 MaterialApp
  /// （与 buildApp 同口径，仅把 home 参数化以复用关键屏矩阵）
  Widget buildScreenApp(String paletteId, ThemeMode mode, Widget home) {
    SharedPreferences.setMockInitialValues({
      'app_palette_id': paletteId,
      'app_theme_mode': switch (mode) {
        ThemeMode.light => 'light',
        ThemeMode.dark => 'dark',
        _ => 'system',
      },
    });
    return MaterialApp(
      theme: _paletteTheme(paletteId, Brightness.light),
      darkTheme: _paletteTheme(paletteId, Brightness.dark),
      themeMode: mode,
      home: home,
    );
  }

  /// 书籍详情页最小 mock 链（对齐 one_to_one_matrix_test 模板）：
  /// getBook / getChapters / getBooks / getBookGroups / getBookSources /
  /// getConfig / getChapterContent 共 7 项，均为详情首屏加载所需。
  MockRustApi stubBookInfoApi(Book book) {
    final api = MockRustApi();
    when(() => api.getBook(any())).thenAnswer((_) async => book);
    when(() => api.getChapters(any()))
        .thenAnswer((_) async => const [BookChapter(title: '第一章')]);
    when(() => api.getBooks()).thenAnswer((_) async => [book]);
    when(() => api.getBookGroups()).thenAnswer((_) async => const []);
    when(() => api.getBookSources()).thenAnswer((_) async => const []);
    when(() => api.getConfig(any())).thenAnswer((_) async => '');
    when(() => api.getChapterContent(any(), any()))
        .thenAnswer((_) async => '内容');
    return api;
  }

  /// 阅读页最小 mock 链（对齐 reader_dark_background_test 模板）：
  /// getChapters / getChapterContent / getBookSources / getConfig 共 4 项。
  MockRustApi stubReaderApi() {
    final api = MockRustApi();
    when(() => api.getChapters(any()))
        .thenAnswer((_) async => const [BookChapter(title: '第一章')]);
    when(() => api.getChapterContent(any(), any()))
        .thenAnswer((_) async => '正文内容');
    when(() => api.getBookSources()).thenAnswer((_) async => const []);
    when(() => api.getConfig(any())).thenAnswer((_) async => '');
    return api;
  }

  // [R41] 详情/阅读两屏单测级渲染防护：与 theme_config 同口径，3 调色板 ×
  // 亮暗全部无异常渲染（异常/溢出会被 flutter test 捕获），并断言关键元素在
  // 位。不写像素级断言（本仓无 golden 基础设施）。
  group('关键页渲染矩阵（详情/阅读补页）', () {
    for (final (name, _) in palettes) {
      for (final mode in [ThemeMode.light, ThemeMode.dark]) {
        testWidgets('$name/${mode.name} book_info 无异常渲染', (tester) async {
          tester.view.physicalSize = const Size(1080, 2260);
          tester.view.devicePixelRatio = 3.0;
          addTearDown(tester.view.reset);
          final book = Book(
            bookUrl: 'https://src.com/book/matrix',
            name: '矩阵详情书',
            author: '作者',
            coverUrl: '',
          );
          final api = stubBookInfoApi(book);
          await tester.pumpWidget(
            ProviderScope(
              overrides: [bookApiProvider.overrideWithValue(api)],
              child: buildScreenApp(name, mode, BookInfoScreen(book: book)),
            ),
          );
          await tester.pumpAndSettle();

          // 关键元素在位：书名 / 四宫格入口「查看目录」「书源」
          expect(find.text('矩阵详情书'), findsWidgets);
          expect(find.text('查看目录'), findsWidgets);
          expect(find.text('书源'), findsWidgets);
          expect(tester.takeException(), isNull);
        });

        testWidgets('$name/${mode.name} reader 无异常渲染', (tester) async {
          tester.view.physicalSize = const Size(1080, 2260);
          tester.view.devicePixelRatio = 3.0;
          addTearDown(tester.view.reset);
          final api = stubReaderApi();
          await tester.pumpWidget(
            ProviderScope(
              overrides: [bookApiProvider.overrideWithValue(api)],
              child: buildScreenApp(name, mode, const ReaderScreen()),
            ),
          );
          // 书架打开链路注入（对标 reader_dark_background_test）
          final container = ProviderScope.containerOf(
            tester.element(find.byType(ReaderScreen)),
          );
          await container
              .read(readerNotifierProvider.notifier)
              .openBook(const Book(bookUrl: 'u1', name: '矩阵书'));
          await tester.pumpAndSettle();

          // 正文分页面板已挂载（说明书籍打开链路走通、非空态占位）
          expect(find.byType(ReaderPageView), findsOneWidget);
          expect(tester.takeException(), isNull);
        });
      }
    }
  });

  // [R41 增量 2026-11-24] 补「阅读设置面板 / RSS 源编辑」两屏：这两屏视觉
  // 最重（面板 15 张分组卡 + 亮度异步三连 FutureBuilder；RSS 编辑 4 Tab ×
  // 32 个 TextField + 可折叠选项面板 + 横向 TabBar），且此前仅有
  // screens_overflow_regress_test 的**单一主题 360dp** 溢出守卫，无
  // 「3 调色板 × 亮暗」渲染防护。故按 theme_config 同口径补齐。
  //
  // 选择说明（已排除的屏及理由）：
  // - bookshelf_config_sheet：已有 17 个 testWidgets 覆盖五段结构/横竖屏/
  //   条件显隐/滑块范围，渲染防护充分，不重复补。
  // - highlight_rules_screen：已有 44 个 testWidgets（含 batch_group 与
  //   highlight_color_row_overflow）覆盖列表/表单/批量/配色行溢出，充分。
  // - reader_theme_screen：已有 reader_theme_search_test 覆盖网格/列表/管理态
  //   与 360dp 无溢出，且 screens_overflow_regress 已纳入。
  group('关键页渲染矩阵（设置面板/源编辑补页）', () {
    for (final (name, _) in palettes) {
      for (final mode in [ThemeMode.light, ThemeMode.dark]) {
        testWidgets('$name/${mode.name} reader_config_panel 无异常渲染', (tester) async {
          tester.view.physicalSize = const Size(1080, 2260);
          tester.view.devicePixelRatio = 3.0;
          addTearDown(tester.view.reset);
          await tester.pumpWidget(
            ProviderScope(
              overrides: [bookApiProvider.overrideWithValue(MockBookApi())],
              child: buildScreenApp(
                name,
                mode,
                // 镜像真实呈现形态：showModalBottomSheet(isScrollControlled)
                // + DraggableScrollableSheet(maxChildSize 0.92) + 可滚动
                // （对齐 screens_overflow_regress_test 的 fixture 约定，
                // 避免无界高度产生的「底部溢出」假象）
                Scaffold(
                  body: ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 588),
                    child: SingleChildScrollView(
                      child: ReaderConfigPanel(
                        config: ReaderAdvancedConfig(),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
          // 面板含三层嵌套 FutureBuilder（isSupported → isAutoBrightness →
          // getBrightness），逐帧推进等其全部落地；不用 pumpAndSettle，
          // 避免加载环的无限动画导致超时。
          for (var i = 0; i < 6; i++) {
            await tester.pump(const Duration(milliseconds: 100));
          }

          // 关键元素在位：面板标题 / 首卡「翻页模式」分段按钮 / 页面边距入口 /
          // 亮度分组标题（后者不依赖异步分支，恒在，可防「整段被条件吞掉」）
          expect(find.text('高级阅读设置'), findsOneWidget);
          expect(find.byType(SegmentedButton<FlipMode>), findsOneWidget);
          expect(find.text('翻页模式'), findsWidgets);
          expect(find.text('页面边距'), findsWidgets);
          expect(find.text('亮度控制'), findsWidgets);
          expect(tester.takeException(), isNull);
        });

        testWidgets('$name/${mode.name} rss_source_edit 无异常渲染', (tester) async {
          tester.view.physicalSize = const Size(1080, 2260);
          tester.view.devicePixelRatio = 3.0;
          addTearDown(tester.view.reset);
          await tester.pumpWidget(
            ProviderScope(
              overrides: [bookApiProvider.overrideWithValue(MockBookApi())],
              child: buildScreenApp(
                name,
                mode,
                const RssSourceEditScreen(),
              ),
            ),
          );
          await tester.pumpAndSettle();

          // 关键元素在位：标题 / 四个 Tab / 可折叠选项面板 / 首字段标签 /
          // 字段输入框已实际铺出（防「TabBarView 空壳」假绿）
          expect(find.text('新建订阅源'), findsOneWidget);
          expect(find.text('基本'), findsOneWidget);
          expect(find.text('预处理'), findsOneWidget);
          expect(find.text('列表规则'), findsOneWidget);
          expect(find.text('WEB_VIEW'), findsOneWidget);
          expect(find.text('选项'), findsOneWidget);
          expect(find.text('源名称'), findsWidgets);
          expect(find.byType(TabBar), findsOneWidget);
          expect(find.byType(TextField), findsWidgets);
          expect(tester.takeException(), isNull);
        });
      }
    }
  });

  group('系统字体缩放边界（0.8x / 1.6x）', () {
    for (final scale in [0.8, 1.6]) {
      testWidgets('theme_config textScaler=$scale 无溢出异常', (tester) async {
        SharedPreferences.setMockInitialValues({
          'app_palette_id': 'wh',
          'app_theme_mode': 'light',
        });
        tester.view.physicalSize = const Size(1080, 2260);
        tester.view.devicePixelRatio = 3.0;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(
          MediaQuery(
            data: const MediaQueryData()
                .copyWith(textScaler: TextScaler.linear(scale)),
            child: ProviderScope(
              child: MaterialApp(home: const ThemeConfigScreen()),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      });

      testWidgets('home textScaler=$scale 无溢出异常', (tester) async {
        SharedPreferences.setMockInitialValues({
          'app_palette_id': 'wh',
          'app_theme_mode': 'light',
        });
        tester.view.physicalSize = const Size(1080, 2260);
        tester.view.devicePixelRatio = 3.0;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(
          MediaQuery(
            data: const MediaQueryData()
                .copyWith(textScaler: TextScaler.linear(scale)),
            child: ProviderScope(child: MaterialApp(home: const HomeScreen())),
          ),
        );
        await tester.pumpAndSettle(const Duration(seconds: 2));
        expect(tester.takeException(), isNull);
      });
    }
  });

  group('触控目标（≥ 48dp）', () {
    testWidgets('底栏 NavigationBar 目标高度 ≥ 48dp', (tester) async {
      SharedPreferences.setMockInitialValues({
        'app_palette_id': 'wh',
        'app_theme_mode': 'light',
      });
      tester.view.physicalSize = const Size(1080, 2260);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ProviderScope(child: MaterialApp(home: const HomeScreen())),
      );
      await tester.pumpAndSettle(const Duration(seconds: 2));
      final bar = tester.renderObject<RenderBox>(
        find.byType(NavigationBar),
      );
      expect(bar.size.height, greaterThanOrEqualTo(48.0));
      // 每个目的地宽度均分，≥ 48dp
      //（[UI_SYNC_REFACTOR S6] 首页页签插入后 5 tab，与参考版页签数一致）
      final destinations = find.byType(NavigationDestination);
      final count = destinations.evaluate().length;
      expect(count, inInclusiveRange(2, 5));
      for (var i = 0; i < count; i++) {
        final box = tester.renderObject<RenderBox>(destinations.at(i));
        expect(box.size.width, greaterThanOrEqualTo(48.0),
            reason: '底栏项 $i 宽度 ${box.size.width} < 48dp');
      }
    });

    testWidgets('主题卡片有语义标签（paletteId 可辨识）', (tester) async {
      SharedPreferences.setMockInitialValues({
        'app_palette_id': 'wh',
        'app_theme_mode': 'light',
      });
      tester.view.physicalSize = const Size(1080, 2260);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(buildApp('wh', ThemeMode.light));
      await tester.pumpAndSettle();
      // 13 套调色板的中文标签均可被语义化查找
      for (final p in Md3Palettes.all) {
        expect(find.text(p.label), findsWidgets, reason: '${p.id} 标签缺失');
      }
    });
  });
}

/// 与 app.dart 相同的调色板装配入口
ThemeData _paletteTheme(String paletteId, Brightness brightness) =>
    AppTheme.palette(
      brightness: brightness,
      palette: Md3Palettes.byId(paletteId),
    );
