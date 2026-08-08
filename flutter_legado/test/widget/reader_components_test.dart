import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/l10n/app_strings.dart';
import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/providers/reader/reader_notifier.dart';
import 'package:flutter_legado/src/screens/reader_config_panel.dart';
import 'package:flutter_legado/src/widgets/reader/reader_bottom_bar.dart';
import 'package:flutter_legado/src/widgets/reader/reader_status_strip.dart';
import 'package:flutter_legado/src/widgets/reader/reader_top_bar.dart';

import '../mocks/mocks.dart';

/// 阅读器子组件 Widget 测试
///
/// 验证 Phase 2.2 拆分出的真实组件（ReaderTopBar / ReaderBottomBar /
/// ReaderStatusStrip）在 Riverpod 架构下忠实渲染，
/// 对齐重构前的界面样式（Phase 2.5 工具栏 + Phase 2.6 书签/进度跳转）。
/// [UI-fix v2.0.4 | 2026-08-08] 对齐原版 ReadMenu：目录抽屉已删除
/// （改独立目录页 TocScreen，测试组同步移除）；搜索/夜间按钮自顶栏
/// 迁至底栏悬浮按钮行，断言同步迁移 — Qoder
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
    when(() => mockApi.getChapterContentFull(any(), any()))
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

  Future<void> openBookAndPump(WidgetTester tester) async {
    await container.read(readerNotifierProvider.notifier).openBook(testBook);
    await tester.pump();
  }

  group('ReaderTopBar（Phase 2.5 工具栏）', () {
    // [UI-fix v2.0.4 | 2026-08-08] 顶栏对齐原版 ReadMenu：搜索/书签/高级
    // 设置常驻图标已迁出（书签→溢出菜单，搜索→底栏悬浮按钮），
    // 断言改为返回/溢出菜单/初始进度 — Qoder
    testWidgets('渲染返回/溢出菜单按钮与初始进度', (tester) async {
      await tester.pumpWidget(wrapStack(ReaderTopBar(
        onAddBookmark: () {},
      )));
      await tester.pump();

      expect(find.byIcon(Icons.arrow_back_ios_new), findsOneWidget);
      expect(find.byType(PopupMenuButton<String>), findsOneWidget);
      // 初始无书籍时进度为 0.0%
      expect(find.text('0.0%'), findsOneWidget);
    });

    testWidgets('打开书籍后显示书名', (tester) async {
      stubOpenBook();
      await tester.pumpWidget(wrapStack(ReaderTopBar(
        onAddBookmark: () {},
      )));
      await tester.pump();

      await openBookAndPump(tester);

      // [UI-fix v2.0.3 | 2026-08-08] showReadTitleAddition 默认开启（对标
      // 原版）：顶栏标题为「书名 · 章名」，断言包含书名即可 — Qoder
      expect(find.textContaining('测试书籍'), findsWidgets);
    });
  });

  group('ReaderBottomBar（Phase 2.5/2.6 章节导航 + 功能按钮）', () {
    testWidgets('渲染上一章/下一章/进度滑块与目录/朗读/界面/设置按钮', (tester) async {
      await tester.pumpWidget(wrapStack(ReaderBottomBar(
        onOpenCatalog: () {},
        onOpenSettings: () {},
        onOpenAdvancedConfig: () {},
        onOpenContentSearch: () {},
        onReadAloud: () {},
      )));
      await tester.pump();

      expect(find.text(AppStrings.previousChapter), findsOneWidget);
      expect(find.text(AppStrings.nextChapter), findsOneWidget);
      expect(find.byType(Slider), findsOneWidget);
      expect(find.byIcon(Icons.toc), findsOneWidget);
      expect(find.byIcon(Icons.record_voice_over_outlined), findsOneWidget);
      expect(find.byIcon(Icons.palette_outlined), findsOneWidget);
      expect(find.byIcon(Icons.settings), findsOneWidget);
      // [UI-fix v2.0.4 | 2026-08-08] 悬浮按钮行（对标原版
      // fabSearch/fabNightTheme）自顶栏迁入底栏 — Qoder
      expect(find.byIcon(Icons.search), findsOneWidget);
      expect(find.byIcon(Icons.dark_mode), findsOneWidget);
    });

    // [UI-fix v2.0.4 | 2026-08-08] 夜间/搜索按钮测试自顶栏组迁入
    // （入口位置对齐原版 ll_floating_button，功能不变） — Qoder
    testWidgets('点击夜间模式按钮切换为背景深色', (tester) async {
      await tester.pumpWidget(wrapStack(ReaderBottomBar(
        onOpenCatalog: () {},
        onOpenSettings: () {},
        onOpenAdvancedConfig: () {},
        onOpenContentSearch: () {},
        onReadAloud: () {},
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
      await tester.pumpWidget(wrapStack(ReaderBottomBar(
        onOpenCatalog: () {},
        onOpenSettings: () {},
        onOpenAdvancedConfig: () {},
        onOpenContentSearch: () => searchTapped = true,
        onReadAloud: () {},
      )));
      await tester.pump();

      await tester.tap(find.byIcon(Icons.search));
      await tester.pump();

      expect(searchTapped, isTrue);
    });

    testWidgets('打开书籍后点击目录按钮触发回调', (tester) async {
      stubOpenBook();
      var catalogTapped = false;
      await tester.pumpWidget(wrapStack(ReaderBottomBar(
        onOpenCatalog: () => catalogTapped = true,
        onOpenSettings: () {},
        onOpenAdvancedConfig: () {},
        onOpenContentSearch: () {},
        onReadAloud: () {},
      )));
      await tester.pump();
      await openBookAndPump(tester);

      await tester.tap(find.byIcon(Icons.toc));
      await tester.pump();

      expect(catalogTapped, isTrue);
    });

    testWidgets('第一章时上一章按钮禁用，下一章按钮可用', (tester) async {
      stubOpenBook();
      await tester.pumpWidget(wrapStack(ReaderBottomBar(
        onOpenCatalog: () {},
        onOpenSettings: () {},
        onOpenAdvancedConfig: () {},
        onOpenContentSearch: () {},
        onReadAloud: () {},
      )));
      await tester.pump();
      await openBookAndPump(tester);

      final prevButton = tester.widget<TextButton>(
        find.widgetWithText(TextButton, AppStrings.previousChapter),
      );
      final nextButton = tester.widget<TextButton>(
        find.widgetWithText(TextButton, AppStrings.nextChapter),
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
}
