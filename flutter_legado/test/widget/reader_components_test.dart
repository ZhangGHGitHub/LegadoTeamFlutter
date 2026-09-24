import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/l10n/app_strings.dart';
import 'package:flutter_legado/src/services/system_brightness.dart';
import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/providers/reader/reader_notifier.dart';
import 'package:flutter_legado/src/providers/theme/theme_notifier.dart';
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

    testWidgets('edge-to-edge 下顶栏内容避让 viewPadding.top', (tester) async {
      const statusBarHeight = 48.0;
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            home: MediaQuery(
              data: const MediaQueryData(
                padding: EdgeInsets.zero,
                viewPadding: EdgeInsets.only(top: statusBarHeight),
              ),
              child: Scaffold(
                body: Stack(
                  children: [
                    ReaderTopBar(onAddBookmark: () {}),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      final safeArea = tester.widget<SafeArea>(find.byType(SafeArea));
      expect(safeArea.minimum.top, statusBarHeight);
      expect(
        tester.getTopLeft(find.byIcon(Icons.arrow_back_ios_new)).dy,
        greaterThanOrEqualTo(statusBarHeight),
      );
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
    // [UI-FIX | 2026-08-13] 夜间按钮同步全局 ThemeMode（对齐原版
    // AppConfig.isNightTheme + ThemeConfig.applyDayNight）— Qoder
    testWidgets('点击夜间模式按钮切换全局主题与阅读页背景', (tester) async {
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
      expect(
        container.read(themeNotifierProvider).themeMode,
        equals(ThemeMode.system),
      );

      await tester.tap(find.byIcon(Icons.dark_mode));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(
        container.read(readerNotifierProvider).backgroundColor,
        equals(ReaderBackground.dark),
      );
      expect(
        container.read(themeNotifierProvider).themeMode,
        equals(ThemeMode.dark),
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

    // [iOS 视角F B1] 模拟 iOS：亮度通道未注册（不装 mock handler，
    // invokeMethod 即抛 MissingPluginException）。修复前 isAutoBrightness
    // 异常穿透 → _loadBrightness 整段 catch → 亮度行隐藏；修复后
    // iOS 分支不调通道（isAutoBrightness 固定 false / setAutoBrightness
    // no-op）→ 亮度行正常渲染，自动亮度切换不抛异常。
    testWidgets('iOS 通道未注册时亮度行仍渲染且自动亮度切换不抛',
        (tester) async {
      SystemBrightness.platformIsIOS = () => true;
      addTearDown(() => SystemBrightness.platformIsIOS = () => Platform.isIOS);
      await tester.pumpWidget(wrapStack(ReaderBottomBar(
        onOpenCatalog: () {},
        onOpenSettings: () {},
        onOpenAdvancedConfig: () {},
        onOpenContentSearch: () {},
        onReadAloud: () {},
      )));
      // _loadBrightness 为微任务链（isSupported → isAutoBrightness →
      // getBrightness：iOS 通道未注册 → 通道响应经真实异步 I/O 回传
      // MissingPluginException → 回落 0.5 → setState）。通道响应在假异步区
      // 无法靠 pump 冲刷，先 runAsync 让真实事件循环完成回传，再以有界 pump
      // 循环推进剩余微任务 hop 直至亮度行出现（若链路异常未渲染，循环用尽
      // 后断言失败）
      final autoIcon = find.byIcon(Icons.brightness_auto_outlined);
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 200)));
      for (var i = 0; i < 10 && autoIcon.evaluate().isEmpty; i++) {
        await tester.pump();
      }

      // 亮度行渲染：自动亮度图标 + 亮度滑条（另有章节进度滑条共 2 个）
      expect(autoIcon, findsOneWidget);
      expect(find.byType(Slider), findsNWidgets(2));

      // 点击自动亮度切换：setAutoBrightness no-op + _loadBrightness 重跑
      // （其通道回传同样需 runAsync 冲刷），行不消失、无未捕获异常
      await tester.tap(autoIcon);
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 200)));
      for (var i = 0; i < 10 && autoIcon.evaluate().isEmpty; i++) {
        await tester.pump();
      }
      expect(autoIcon, findsOneWidget);
    });
  });

  group('ReaderStatusStrip（Phase 2.4/2.6 状态栏）', () {
    // [PARITY C2 R4] 状态行四开关默认关闭（参考无顶状态行）：默认配置不渲染内容，
    // 电量/进度等改为「开启开关才渲染」。
    testWidgets('默认配置（全关）不渲染内容', (tester) async {
      await tester.pumpWidget(wrapStack(
        ReaderStatusStrip(config: ReaderAdvancedConfig()),
      ));
      await tester.pump();

      expect(find.byIcon(Icons.battery_std), findsNothing);
    });

    testWidgets('开启电量+进度开关时渲染电量图标与进度', (tester) async {
      final config = ReaderAdvancedConfig(
        showBattery: true,
        showProgress: true,
      );
      await tester.pumpWidget(wrapStack(ReaderStatusStrip(config: config)));
      await tester.pump();

      expect(find.byIcon(Icons.battery_std), findsOneWidget);
      expect(find.text('0.0%'), findsOneWidget);
    });
  });
}
