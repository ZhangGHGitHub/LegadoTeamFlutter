import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/providers/reader/reader_notifier.dart';
import 'package:flutter_legado/src/screens/reader_config_panel.dart';
import 'package:flutter_legado/src/widgets/reader/reader_bottom_bar.dart';
import 'package:flutter_legado/src/widgets/reader/reader_catalog_drawer.dart';
import 'package:flutter_legado/src/widgets/reader/reader_status_strip.dart';
import 'package:flutter_legado/src/widgets/reader/reader_top_bar.dart';

import '../mocks/mocks.dart';

/// 阅读器子组件 Widget 测试
///
/// 验证 Phase 2.2 拆分出的真实组件（ReaderTopBar / ReaderBottomBar /
/// ReaderStatusStrip / ReaderCatalogDrawer）在 Riverpod 架构下忠实渲染，
/// 对齐重构前的界面样式（Phase 2.5 工具栏 + Phase 2.6 目录/书签/进度跳转）。
void main() {
  late MockRustApi mockApi;
  late ProviderContainer container;

  const testBook = Book(
    bookUrl: 'https://book.com/1',
    name: '测试书籍',
    author: '作者',
    origin: 'https://source.com',
    durChapterIndex: 0,
  );

  final testChapters = [
    const BookChapter(title: '第一章', index: 0),
    const BookChapter(title: '第二章', index: 1),
    const BookChapter(title: '第三章', index: 2),
  ];

  setUpAll(() {
    registerFallbacks();
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    mockApi = MockRustApi();
    container = ProviderContainer(
      overrides: [bookApiProvider.overrideWithValue(mockApi)],
    );
    addTearDown(container.dispose);
  });

  /// 配置 openBook 所需的完整 mock 链
  void stubOpenBook({String content = '章节内容'}) {
    when(() => mockApi.getChapters(any()))
        .thenAnswer((_) async => testChapters);
    when(() => mockApi.getChapterContent(any(), any()))
        .thenAnswer((_) async => content);
    when(() => mockApi.updateReadingProgress(
          bookUrl: any(named: 'bookUrl'),
          chapterIndex: any(named: 'chapterIndex'),
          chapterPos: any(named: 'chapterPos'),
        )).thenAnswer((_) async {});
  }

  /// 将 Positioned 类组件包裹于 Stack（TopBar/BottomBar/StatusStrip 需要）
  Widget wrapStack(Widget child) {
    return UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: Scaffold(body: Stack(children: [child])),
      ),
    );
  }

  /// 将普通组件包裹于 Scaffold body（Drawer 等）
  Widget wrapPlain(Widget child) {
    return UncontrolledProviderScope(
      container: container,
      child: MaterialApp(home: Scaffold(body: child)),
    );
  }

  Future<void> openBookAndPump(WidgetTester tester) async {
    await container.read(readerNotifierProvider.notifier).openBook(testBook);
    await tester.pump();
  }

  group('ReaderTopBar（Phase 2.5 工具栏）', () {
    testWidgets('渲染返回/搜索/书签/高级设置按钮与初始进度', (tester) async {
      await tester.pumpWidget(wrapStack(ReaderTopBar(
        onOpenContentSearch: () {},
        onAddBookmark: () {},
        onOpenAdvancedConfig: () {},
      )));
      await tester.pump();

      expect(find.byIcon(Icons.arrow_back), findsOneWidget);
      expect(find.byIcon(Icons.search), findsOneWidget);
      expect(find.byIcon(Icons.bookmark_add_outlined), findsOneWidget);
      expect(find.byIcon(Icons.more_vert), findsOneWidget);
      // 初始无书籍时进度为 0.0%
      expect(find.text('0.0%'), findsOneWidget);
    });

    testWidgets('打开书籍后显示书名', (tester) async {
      stubOpenBook();
      await tester.pumpWidget(wrapStack(ReaderTopBar(
        onOpenContentSearch: () {},
        onAddBookmark: () {},
        onOpenAdvancedConfig: () {},
      )));
      await tester.pump();

      await openBookAndPump(tester);

      expect(find.text('测试书籍'), findsOneWidget);
    });

    testWidgets('点击夜间模式按钮切换为背景深色', (tester) async {
      await tester.pumpWidget(wrapStack(ReaderTopBar(
        onOpenContentSearch: () {},
        onAddBookmark: () {},
        onOpenAdvancedConfig: () {},
      )));
      await tester.pump();

      // 初始为浅色背景，显示 dark_mode 图标
      expect(find.byIcon(Icons.dark_mode), findsOneWidget);

      await tester.tap(find.byIcon(Icons.dark_mode));
      await tester.pump();

      expect(
        container.read(readerNotifierProvider).backgroundColor,
        equals(ReaderBackground.dark),
      );
    });

    testWidgets('点击搜索按钮触发回调', (tester) async {
      var searchTapped = false;
      await tester.pumpWidget(wrapStack(ReaderTopBar(
        onOpenContentSearch: () => searchTapped = true,
        onAddBookmark: () {},
        onOpenAdvancedConfig: () {},
      )));
      await tester.pump();

      await tester.tap(find.byIcon(Icons.search));
      await tester.pump();

      expect(searchTapped, isTrue);
    });
  });

  group('ReaderBottomBar（Phase 2.5/2.6 章节导航 + 功能按钮）', () {
    testWidgets('渲染上一章/下一章/进度滑块与目录/设置/夜间按钮', (tester) async {
      await tester.pumpWidget(wrapStack(ReaderBottomBar(
        onOpenCatalog: () {},
        onOpenSettings: () {},
      )));
      await tester.pump();

      expect(find.byIcon(Icons.skip_previous), findsOneWidget);
      expect(find.byIcon(Icons.skip_next), findsOneWidget);
      expect(find.byType(Slider), findsOneWidget);
      expect(find.byIcon(Icons.format_list_numbered), findsOneWidget);
      expect(find.byIcon(Icons.settings), findsOneWidget);
      expect(find.byIcon(Icons.brightness_6), findsOneWidget);
    });

    testWidgets('打开书籍后点击目录按钮触发回调', (tester) async {
      stubOpenBook();
      var catalogTapped = false;
      await tester.pumpWidget(wrapStack(ReaderBottomBar(
        onOpenCatalog: () => catalogTapped = true,
        onOpenSettings: () {},
      )));
      await tester.pump();
      await openBookAndPump(tester);

      await tester.tap(find.byIcon(Icons.format_list_numbered));
      await tester.pump();

      expect(catalogTapped, isTrue);
    });

    testWidgets('第一章时上一章按钮禁用，下一章按钮可用', (tester) async {
      stubOpenBook();
      await tester.pumpWidget(wrapStack(ReaderBottomBar(
        onOpenCatalog: () {},
        onOpenSettings: () {},
      )));
      await tester.pump();
      await openBookAndPump(tester);

      final prevButton = tester.widget<IconButton>(
        find.widgetWithIcon(IconButton, Icons.skip_previous),
      );
      final nextButton = tester.widget<IconButton>(
        find.widgetWithIcon(IconButton, Icons.skip_next),
      );
      expect(prevButton.onPressed, isNull);
      expect(nextButton.onPressed, isNotNull);
    });
  });

  group('ReaderStatusStrip（Phase 2.4/2.6 状态栏）', () {
    testWidgets('默认配置渲染电量图标与进度', (tester) async {
      await tester.pumpWidget(wrapStack(
        ReaderStatusStrip(config: ReaderAdvancedConfig()),
      ));
      await tester.pump();

      expect(find.byIcon(Icons.battery_std), findsOneWidget);
      expect(find.text('0.0%'), findsOneWidget);
    });

    testWidgets('全部关闭时不渲染内容', (tester) async {
      final config = ReaderAdvancedConfig(
        showBattery: false,
        showTime: false,
        showProgress: false,
        showChapterName: false,
      );
      await tester.pumpWidget(wrapStack(ReaderStatusStrip(config: config)));
      await tester.pump();

      expect(find.byIcon(Icons.battery_std), findsNothing);
    });
  });

  group('ReaderCatalogDrawer（Phase 2.6 目录 + 进度跳转）', () {
    testWidgets('打开书籍后显示章节列表', (tester) async {
      stubOpenBook();
      await tester.pumpWidget(wrapPlain(const ReaderCatalogDrawer()));
      await tester.pump();
      await openBookAndPump(tester);

      expect(find.text('测试书籍'), findsOneWidget);
      expect(find.text('第一章'), findsOneWidget);
      expect(find.text('第二章'), findsOneWidget);
      expect(find.text('第三章'), findsOneWidget);
    });

    testWidgets('无章节时显示空提示', (tester) async {
      await tester.pumpWidget(wrapPlain(const ReaderCatalogDrawer()));
      await tester.pump();

      // 初始无章节，显示目录标题（fallback）
      expect(find.byType(TextField), findsOneWidget);
    });

    testWidgets('搜索框过滤章节', (tester) async {
      stubOpenBook();
      await tester.pumpWidget(wrapPlain(const ReaderCatalogDrawer()));
      await tester.pump();
      await openBookAndPump(tester);

      await tester.enterText(find.byType(TextField), '第二');
      await tester.pump();

      expect(find.text('第二章'), findsOneWidget);
      expect(find.text('第一章'), findsNothing);
      expect(find.text('第三章'), findsNothing);
    });
  });
}
