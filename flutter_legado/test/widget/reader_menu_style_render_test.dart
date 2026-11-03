// [批3a] 阅读器菜单渲染测试：底栏图标网格 / 三态 / 分页 / 浮动形态 /
// 顶栏标题模式 / 胶囊 / 合并按钮 / 图标样式 / 配色接线。
//
// 编写：全栈工程师（批3a） ｜ 2026-11-04
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderRepaintBoundary;
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/constants/pref_keys.dart';
import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/providers/reader/reader_menu_style_notifier.dart';
import 'package:flutter_legado/src/providers/reader/reader_notifier.dart';
import 'package:flutter_legado/src/routes.dart';
import 'package:flutter_legado/src/theme/theme_engine_parameterized.dart';
import 'package:flutter_legado/src/widgets/reader/reader_menu_panel.dart';
import 'package:flutter_legado/src/widgets/reader/reader_top_bar_actions.dart';

import '../mocks/mocks.dart';

void main() {
  late MockRustApi mockApi;

  setUpAll(registerFallbacks);

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    mockApi = MockRustApi();
    stubEmptyWebdavServers(mockApi);
  });

  const book = Book(
    bookUrl: 'https://book.com/menu3a',
    name: '菜单测试书',
    author: '作者M',
    origin: 'https://source-m.com',
    originName: '测试源',
    durChapterIndex: 0,
  );
  const chapter = BookChapter(
    url: 'https://book.com/c1',
    title: '第一章',
    index: 0,
  );

  ProviderContainer makeContainer() {
    final container = ProviderContainer(
      overrides: [bookApiProvider.overrideWithValue(mockApi)],
    );
    addTearDown(container.dispose);
    return container;
  }

  Widget wrapMenu(
    ProviderContainer container, {
    EdgeInsets padding = EdgeInsets.zero,
    EdgeInsets viewPadding = EdgeInsets.zero,
    TextScaler? textScaler,
    bool parentHandlesBottomInset = false,
    EdgeInsets outerPadding = EdgeInsets.zero,
    Brightness brightness = Brightness.light,
    bool visible = true,
    GlobalKey? repaintKey,
  }) => UncontrolledProviderScope(
    container: container,
    child: MaterialApp(
      theme: ThemeData(brightness: brightness),
      routes: {
        AppRoutes.bookInfo: (_) => const Scaffold(body: Text('书籍详情页')),
        AppRoutes.offlineCache: (_) => const Scaffold(body: Text('缓存管理页')),
      },
      home: Builder(
        builder: (context) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            padding: padding,
            viewPadding: viewPadding,
            textScaler: textScaler,
          ),
          child: RepaintBoundary(
            key: repaintKey,
            child: Scaffold(
              body: Padding(
                padding: outerPadding,
              child: Stack(
                children: [
                  ReaderMenuPanel(
                    visible: visible,
                  onBack: () {},
                  onAddBookmark: () {},
                  onOpenCatalog: () {},
                  onOpenSettings: () {},
                  onOpenAdvancedConfig: () {},
                  onOpenContentSearch: () {},
                  onReadAloud: () {},
                  onToggleAutoPage: () {},
                  onOpenReplaceRules: () {},
                    parentHandlesBottomInset: parentHandlesBottomInset,
                  ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );

  void stubOpenBook() {
    when(() => mockApi.getChapters(any())).thenAnswer((_) async => [chapter]);
    when(
      () => mockApi.getChapterContentFull(any(), any()),
    ).thenAnswer((_) async => '正文内容');
    when(
      () => mockApi.updateReadingProgress(
        bookUrl: any(named: 'bookUrl'),
        chapterIndex: any(named: 'chapterIndex'),
        chapterPos: any(named: 'chapterPos'),
      ),
    ).thenAnswer((_) async {});
  }

  Future<ProviderContainer> pumpMenu(
    WidgetTester tester, {
    Book? currentBook,
    EdgeInsets padding = EdgeInsets.zero,
    EdgeInsets viewPadding = EdgeInsets.zero,
    TextScaler? textScaler,
    bool parentHandlesBottomInset = false,
    EdgeInsets outerPadding = EdgeInsets.zero,
    Brightness brightness = Brightness.light,
    bool visible = true,
    GlobalKey? repaintKey,
  }) async {
    final container = makeContainer();
    if (currentBook != null) stubOpenBook();
    await tester.pumpWidget(
      wrapMenu(
        container,
        padding: padding,
        viewPadding: viewPadding,
        textScaler: textScaler,
        parentHandlesBottomInset: parentHandlesBottomInset,
        outerPadding: outerPadding,
        brightness: brightness,
        visible: visible,
        repaintKey: repaintKey,
      ),
    );
    if (currentBook != null) {
      await container
          .read(readerNotifierProvider.notifier)
          .openBook(currentBook);
    }
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    return container;
  }

  Finder action(String label) =>
      find.byKey(ValueKey('reader-menu-action-$label'));
  Finder actionSurface(String label) =>
      find.byKey(ValueKey('reader-menu-action-surface-$label'));
  Finder topBarSurface(String label) =>
      find.byKey(ValueKey('reader-topbar-icon-surface-$label'));

  group('底栏五键图标网格', () {
    testWidgets('默认渲染 5 键，顶栏中部快捷钮已移除但入口仍可达', (tester) async {
      await pumpMenu(tester, currentBook: book);

      for (final label in ['全文搜索', '自动翻页', '目录', '朗读', '设置']) {
        expect(action(label), findsOneWidget, reason: '$label 应常驻底栏');
      }
      // 旧顶栏中部快捷钮（Tooltip 文案为「搜索/目录/朗读/设置/换源」）
      // 已移除：搜索文案不再存在；目录/朗读/设置只由底栏各贡献 1 个 Tooltip
      //（若旧快捷钮仍在会重复为 2 个），换源只剩顶栏换源动作。
      expect(find.byTooltip('搜索'), findsNothing);
      for (final label in ['目录', '朗读', '设置']) {
        expect(
          find.byTooltip(label),
          findsOneWidget,
          reason: '旧快捷钮已移除，$label 仅底栏一处',
        );
      }
      expect(find.byTooltip('换源'), findsOneWidget);
      expect(
        find.ancestor(
          of: find.byKey(const ValueKey('reader-topbar-action-change_source')),
          matching: find.byTooltip('换源'),
        ),
        findsOneWidget,
        reason: '换源入口由顶栏动作承载',
      );
      expect(
        find.byKey(const ValueKey('reader-topbar-action-change_source')),
        findsOneWidget,
      );
      expect(find.byTooltip('更多'), findsOneWidget);
    });

    testWidgets('itemsPerRow=3 / rowCount=2：两行布局，行距 12dp', (tester) async {
      SharedPreferences.setMockInitialValues({
        PrefKeys.readMenuIconItemsPerRow: 3,
        PrefKeys.readMenuIconRowCount: 2,
      });
      await pumpMenu(tester, currentBook: book);

      final search = tester.getTopLeft(action('全文搜索'));
      final autoPage = tester.getTopLeft(action('自动翻页'));
      final catalog = tester.getTopLeft(action('目录'));
      final aloud = tester.getTopLeft(action('朗读'));
      final setting = tester.getTopLeft(action('设置'));

      expect(search.dy, autoPage.dy);
      expect(search.dy, catalog.dy);
      expect(aloud.dy, setting.dy);
      expect(
        aloud.dy - search.dy,
        closeTo(52, 0.01),
        reason: '40dp 按钮 + 12dp 行距',
      );
      expect(search.dx < autoPage.dx && autoPage.dx < catalog.dx, isTrue);
    });

    testWidgets('itemsPerRow=2 / rowCount=1：溢出分页，页数变化可翻页', (tester) async {
      SharedPreferences.setMockInitialValues({
        PrefKeys.readMenuIconItemsPerRow: 2,
        PrefKeys.readMenuIconRowCount: 1,
      });
      await pumpMenu(tester, currentBook: book);

      expect(find.byType(PageView), findsOneWidget);
      expect(action('全文搜索'), findsOneWidget);
      expect(action('自动翻页'), findsOneWidget);
      expect(action('目录'), findsNothing, reason: '第 2 页尚未构建');

      await tester.drag(find.byType(PageView), const Offset(-600, 0));
      await tester.pumpAndSettle();
      expect(action('目录'), findsOneWidget);
      expect(action('朗读'), findsOneWidget);
      expect(action('设置'), findsNothing);

      await tester.drag(find.byType(PageView), const Offset(-600, 0));
      await tester.pumpAndSettle();
      expect(action('设置'), findsOneWidget);
      expect(action('全文搜索'), findsNothing);
    });

    testWidgets('页数变化时当前页收敛：2/行翻到第 3 页后改 8/行回到单页', (tester) async {
      SharedPreferences.setMockInitialValues({
        PrefKeys.readMenuIconItemsPerRow: 2,
        PrefKeys.readMenuIconRowCount: 1,
      });
      final container = await pumpMenu(tester, currentBook: book);
      expect(find.byType(PageView), findsOneWidget);

      await tester.drag(find.byType(PageView), const Offset(-600, 0));
      await tester.pumpAndSettle();
      await tester.drag(find.byType(PageView), const Offset(-600, 0));
      await tester.pumpAndSettle();
      expect(action('设置'), findsOneWidget);

      container.read(readerMenuStyleProvider.notifier).setItemsPerRow(8);
      await tester.pumpAndSettle();
      expect(find.byType(PageView), findsNothing);
      for (final label in ['全文搜索', '自动翻页', '目录', '朗读', '设置']) {
        expect(action(label), findsOneWidget, reason: label);
      }
    });

    testWidgets('showIconText 开关：文字在图标下渲染', (tester) async {
      await pumpMenu(tester, currentBook: book);
      expect(find.text('全文搜索'), findsNothing, reason: '默认不显示文字');

      SharedPreferences.setMockInitialValues({
        PrefKeys.readMenuIconShowText: true,
      });
      await tester.pumpWidget(const SizedBox.shrink());
      await pumpMenu(tester, currentBook: book);
      expect(find.text('全文搜索'), findsOneWidget);
      expect(find.text('自动翻页'), findsOneWidget);
    });

    for (final scale in [1.3, 1.5, 2.0]) {
      testWidgets('showIconText + textScale $scale：无纵向 RenderFlex 溢出', (
        tester,
      ) async {
        SharedPreferences.setMockInitialValues({
          PrefKeys.readMenuIconShowText: true,
        });
        await pumpMenu(
          tester,
          currentBook: book,
          textScaler: TextScaler.linear(scale),
        );
        expect(tester.takeException(), isNull);
        expect(action('设置'), findsOneWidget);
      });
    }

    testWidgets('图标文字不锁 40dp 定宽：全文搜索不被截断', (tester) async {
      SharedPreferences.setMockInitialValues({
        PrefKeys.readMenuIconShowText: true,
      });
      await pumpMenu(tester, currentBook: book);
      final label = tester.widget<Text>(find.text('全文搜索'));
      expect(label.maxLines, 1);
      expect(
        tester.getSize(find.text('全文搜索')).width,
        greaterThan(40),
        reason: 'OverflowBox 自然绘制，不做 ellipsis 截断',
      );
    });

    testWidgets('图标容器三态：无底衬 / 色调 / 描边', (tester) async {
      // style 0：透明 + 无描边
      await pumpMenu(tester, currentBook: book);
      var deco =
          tester.widget<Container>(actionSurface('全文搜索')).decoration
              as BoxDecoration;
      expect(deco.color, Colors.transparent);
      expect(deco.border, isNull);

      // style 1：surfaceContainerLow（readBarStyle=0 走系统配色）
      SharedPreferences.setMockInitialValues({
        PrefKeys.readBarStyle: 0,
        PrefKeys.readMenuIconStyle: 1,
      });
      await tester.pumpWidget(const SizedBox.shrink());
      await pumpMenu(tester, currentBook: book);
      final scheme = Theme.of(
        tester.element(actionSurface('全文搜索')),
      ).colorScheme;
      deco =
          tester.widget<Container>(actionSurface('全文搜索')).decoration
              as BoxDecoration;
      expect(deco.color, scheme.surfaceContainerLow);

      // style 2：1dp onSurfaceVariant@45% 描边
      SharedPreferences.setMockInitialValues({
        PrefKeys.readBarStyle: 0,
        PrefKeys.readMenuIconStyle: 2,
      });
      await tester.pumpWidget(const SizedBox.shrink());
      await pumpMenu(tester, currentBook: book);
      deco =
          tester.widget<Container>(actionSurface('全文搜索')).decoration
              as BoxDecoration;
      expect(deco.color, Colors.transparent);
      expect(deco.border, isNotNull);
      expect((deco.border! as Border).top.color.a, closeTo(0.45, 0.01));
      expect((deco.border! as Border).top.width, 1);
    });

    testWidgets('360dp 窄屏 + itemsPerRow=8：整体缩放兜底，无横向溢出', (tester) async {
      await tester.binding.setSurfaceSize(const Size(360, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      SharedPreferences.setMockInitialValues({
        PrefKeys.readMenuIconItemsPerRow: 8,
        PrefKeys.readMenuIconRowCount: 1,
      });
      await pumpMenu(tester, currentBook: book);

      expect(tester.takeException(), isNull);
      for (final label in ['全文搜索', '自动翻页', '目录', '朗读', '设置']) {
        expect(action(label), findsOneWidget, reason: label);
      }
    });

    testWidgets('自动翻页运行中：pause 图标 + secondaryContainer 选中态', (tester) async {
      SharedPreferences.setMockInitialValues({
        'reader_adv_auto_page_turn': true,
        PrefKeys.readBarStyle: 0,
      });
      await pumpMenu(tester, currentBook: book);
      await tester.pump(const Duration(milliseconds: 100));

      expect(
        find.descendant(
          of: action('自动翻页'),
          matching: find.byIcon(Symbols.pause_rounded),
        ),
        findsOneWidget,
      );
      final scheme = Theme.of(
        tester.element(actionSurface('自动翻页')),
      ).colorScheme;
      final deco =
          tester.widget<Container>(actionSurface('自动翻页')).decoration
              as BoxDecoration;
      expect(deco.color, scheme.secondaryContainer);
      expect((deco.border! as Border).top.color, scheme.secondary);
      expect((deco.border! as Border).top.width, 1.5);
    });
  });

  group('底栏浮动形态与圆角', () {
    testWidgets('floating=true：左右/底部 16dp，四角圆角', (tester) async {
      SharedPreferences.setMockInitialValues({
        PrefKeys.readMenuBottomCornerRadius: 12,
      });
      await pumpMenu(tester, currentBook: book);

      expect(
        find.byKey(const ValueKey('reader-bottom-panel-floating')),
        findsOneWidget,
      );
      final rect = tester.getRect(
        find.byKey(const ValueKey('reader-bottom-panel-surface')),
      );
      final screen = tester.getSize(find.byType(Scaffold));
      expect(rect.left, 16);
      expect(rect.right, screen.width - 16);
      expect(rect.bottom, screen.height - 16);
      final material = tester.widget<Material>(
        find.byKey(const ValueKey('reader-bottom-panel-surface')),
      );
      expect(material.borderRadius, BorderRadius.circular(12));
    });

    testWidgets('floating=false：贴底全宽，仅上圆角', (tester) async {
      SharedPreferences.setMockInitialValues({
        PrefKeys.readMenuFloatingBottomBar: false,
        PrefKeys.readMenuBottomCornerRadius: 8,
      });
      await pumpMenu(tester, currentBook: book);

      expect(
        find.byKey(const ValueKey('reader-bottom-panel-floating')),
        findsNothing,
      );
      final rect = tester.getRect(
        find.byKey(const ValueKey('reader-bottom-panel-surface')),
      );
      final screen = tester.getSize(find.byType(Scaffold));
      expect(rect.left, 0);
      expect(rect.right, screen.width);
      expect(rect.bottom, screen.height);
      final material = tester.widget<Material>(
        find.byKey(const ValueKey('reader-bottom-panel-surface')),
      );
      expect(
        material.borderRadius,
        const BorderRadius.vertical(top: Radius.circular(8)),
      );
    });

    testWidgets('浮动 + 底部导航栏 34：外边距=16+34，面板内不双计', (tester) async {
      const navBottom = 34.0;
      await pumpMenu(
        tester,
        currentBook: book,
        padding: const EdgeInsets.only(bottom: navBottom),
        viewPadding: const EdgeInsets.only(bottom: navBottom),
      );

      final screen = tester.getSize(find.byType(Scaffold));
      final surface = tester.getRect(
        find.byKey(const ValueKey('reader-bottom-panel-surface')),
      );
      expect(
        surface.bottom,
        closeTo(screen.height - navBottom - 16, 0.01),
        reason: '浮动外边距 16 + 导航栏 34',
      );
      expect(
        tester.getRect(action('设置')).bottom,
        closeTo(surface.bottom - 16, 0.01),
        reason: '面板内 SafeArea(bottom:false)，只保留网格 16dp 内边距',
      );
    });

    testWidgets('父级已处理底部 inset：浮动面板只加 16dp（不叠导航栏）', (
      tester,
    ) async {
      const navBottom = 34.0;
      await pumpMenu(
        tester,
        currentBook: book,
        padding: const EdgeInsets.only(bottom: navBottom),
        viewPadding: const EdgeInsets.only(bottom: navBottom),
        parentHandlesBottomInset: true,
      );
      final screen = tester.getSize(find.byType(Scaffold));
      final surface = tester.getRect(
        find.byKey(const ValueKey('reader-bottom-panel-surface')),
      );
      expect(surface.bottom, closeTo(screen.height - 16, 0.01));
      expect(
        tester.getRect(action('设置')).bottom,
        closeTo(surface.bottom - 16, 0.01),
      );
    });

    testWidgets('真实外层 Padding(bottom:34)+flag：只保留外层 34 与内 16', (
      tester,
    ) async {
      const navBottom = 34.0;
      await pumpMenu(
        tester,
        currentBook: book,
        padding: const EdgeInsets.only(bottom: navBottom),
        viewPadding: const EdgeInsets.only(bottom: navBottom),
        parentHandlesBottomInset: true,
        outerPadding: const EdgeInsets.only(bottom: navBottom),
      );
      final screen = tester.getSize(find.byType(Scaffold));
      final surface = tester.getRect(
        find.byKey(const ValueKey('reader-bottom-panel-surface')),
      );
      expect(
        surface.bottom,
        closeTo(screen.height - navBottom - 16, 0.01),
        reason: '外层 Padding 34 + 浮动边距 16，面板自身不再加 34',
      );
      expect(
        tester.getRect(action('设置')).bottom,
        closeTo(surface.bottom - 16, 0.01),
      );
    });

    testWidgets('父级已处理底部 inset：贴底形态内部不再 SafeArea', (tester) async {
      const navBottom = 34.0;
      SharedPreferences.setMockInitialValues({
        PrefKeys.readMenuFloatingBottomBar: false,
      });
      await pumpMenu(
        tester,
        currentBook: book,
        padding: const EdgeInsets.only(bottom: navBottom),
        viewPadding: const EdgeInsets.only(bottom: navBottom),
        parentHandlesBottomInset: true,
      );
      final screen = tester.getSize(find.byType(Scaffold));
      expect(
        tester.getRect(action('设置')).bottom,
        closeTo(screen.height - 16, 0.01),
      );
    });

    testWidgets('贴底 + 底部导航栏 34：面板贴屏底，SafeArea 只计一次', (tester) async {
      const navBottom = 34.0;
      SharedPreferences.setMockInitialValues({
        PrefKeys.readMenuFloatingBottomBar: false,
      });
      await pumpMenu(
        tester,
        currentBook: book,
        padding: const EdgeInsets.only(bottom: navBottom),
        viewPadding: const EdgeInsets.only(bottom: navBottom),
      );

      final screen = tester.getSize(find.byType(Scaffold));
      final surface = tester.getRect(
        find.byKey(const ValueKey('reader-bottom-panel-surface')),
      );
      expect(surface.bottom, closeTo(screen.height, 0.01));
      expect(
        tester.getRect(action('设置')).bottom,
        closeTo(screen.height - navBottom - 16, 0.01),
        reason: 'SafeArea 导航栏 + 网格 16dp，各一次',
      );
    });
  });

  group('顶栏标题模式 / 胶囊 / 合并 / 图标样式', () {
    testWidgets('mode 0：书名在顶栏行内 + 章节行', (tester) async {
      await pumpMenu(tester, currentBook: book);
      expect(
        find.byKey(const ValueKey('reader-topbar-book-name')),
        findsOneWidget,
      );
      expect(find.text('菜单测试书'), findsOneWidget);
      expect(find.text('第一章'), findsOneWidget);
    });

    testWidgets('mode 1：书名另起一行 + 章节行', (tester) async {
      SharedPreferences.setMockInitialValues({PrefKeys.titleBarMode: '1'});
      await pumpMenu(tester, currentBook: book);
      expect(
        find.byKey(const ValueKey('reader-topbar-book-name')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('reader-topbar-book-name-own-line')),
        findsOneWidget,
      );
      expect(find.text('菜单测试书'), findsOneWidget);
      expect(find.text('第一章'), findsOneWidget);
    });

    testWidgets('mode 2：无书名，仅章节行', (tester) async {
      SharedPreferences.setMockInitialValues({PrefKeys.titleBarMode: '2'});
      await pumpMenu(tester, currentBook: book);
      expect(
        find.byKey(const ValueKey('reader-topbar-book-name')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('reader-topbar-book-name-own-line')),
        findsNothing,
      );
      expect(find.text('菜单测试书'), findsNothing);
      expect(find.text('第一章'), findsOneWidget);
    });

    testWidgets('mode 3：标题与章节块整体隐藏，动作照常', (tester) async {
      SharedPreferences.setMockInitialValues({PrefKeys.titleBarMode: '3'});
      await pumpMenu(tester, currentBook: book);
      expect(find.text('菜单测试书'), findsNothing);
      expect(find.text('第一章'), findsNothing);
      expect(
        find.byKey(const ValueKey('reader-topbar-action-change_source')),
        findsOneWidget,
      );
    });

    testWidgets('标题胶囊：书名 + 章名，点击进入书籍详情', (tester) async {
      SharedPreferences.setMockInitialValues({
        PrefKeys.readMenuTopBarTitleCapsule: true,
      });
      await pumpMenu(tester, currentBook: book);

      final capsule = find.byKey(const ValueKey('reader-topbar-title-capsule'));
      expect(capsule, findsOneWidget);
      expect(find.text('菜单测试书'), findsOneWidget);
      expect(find.text('第一章'), findsOneWidget);
      // 胶囊替代独立章节行（书名只出现一次）
      expect(find.text('菜单测试书'), findsOneWidget);

      await tester.tap(capsule);
      await tester.pumpAndSettle();
      expect(find.text('书籍详情页'), findsOneWidget);
    });

    testWidgets('标题胶囊 + mode 3：整体隐藏', (tester) async {
      SharedPreferences.setMockInitialValues({
        PrefKeys.readMenuTopBarTitleCapsule: true,
        PrefKeys.titleBarMode: '3',
      });
      await pumpMenu(tester, currentBook: book);
      expect(
        find.byKey(const ValueKey('reader-topbar-title-capsule')),
        findsNothing,
      );
      expect(find.text('菜单测试书'), findsNothing);
    });

    testWidgets('合并按钮：单个 20 圆角胶囊，按钮间无 6dp 间距', (tester) async {
      SharedPreferences.setMockInitialValues({
        PrefKeys.readMenuTopBarMergeButtons: true,
        PrefKeys.readBarStyle: 0,
        PrefKeys.titleBarIconStyle: 1,
      });
      await pumpMenu(tester, currentBook: book);

      final merged = find.byKey(const ValueKey('reader-topbar-merged-actions'));
      expect(merged, findsOneWidget);
      final scheme = Theme.of(tester.element(merged)).colorScheme;
      final deco = tester.widget<Container>(merged).decoration as BoxDecoration;
      expect(deco.color, scheme.surfaceContainerLow);
      expect(deco.borderRadius, BorderRadius.circular(20));

      final download = tester.getTopLeft(
        find.byKey(const ValueKey('reader-topbar-action-download')),
      );
      final refresh = tester.getTopLeft(
        find.byKey(const ValueKey('reader-topbar-action-refresh')),
      );
      expect(refresh.dx - download.dx, 40, reason: '合并态无 6dp 间距');
    });

    testWidgets('独立按钮：40dp 圆形按钮间距 6dp', (tester) async {
      await pumpMenu(tester, currentBook: book);
      expect(
        find.byKey(const ValueKey('reader-topbar-merged-actions')),
        findsNothing,
      );
      final download = tester.getTopLeft(
        find.byKey(const ValueKey('reader-topbar-action-download')),
      );
      final refresh = tester.getTopLeft(
        find.byKey(const ValueKey('reader-topbar-action-refresh')),
      );
      expect(refresh.dx - download.dx, 46, reason: '40dp + 6dp');
    });

    testWidgets('合并按钮 + titleIconStyle=0：胶囊透明（不再恒有底色）', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({
        PrefKeys.readMenuTopBarMergeButtons: true,
        PrefKeys.readBarStyle: 0,
        PrefKeys.titleBarIconStyle: 0,
      });
      await pumpMenu(tester, currentBook: book);
      final merged = find.byKey(const ValueKey('reader-topbar-merged-actions'));
      final deco = tester.widget<Container>(merged).decoration as BoxDecoration;
      expect(deco.color, Colors.transparent);
    });

    for (final merge in [false, true]) {
      testWidgets('320dp + 6 个动作（merge=$merge）：全部可见可点且无溢出', (
        tester,
      ) async {
        await tester.binding.setSurfaceSize(const Size(320, 800));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        SharedPreferences.setMockInitialValues({
          PrefKeys.readMenuTopBarMergeButtons: merge,
          PrefKeys.readerTopBarActions: [
            for (final def in readerTopBarActionPool) '${def.id},true',
          ].join(';'),
        });
        await pumpMenu(tester, currentBook: book);

        expect(tester.takeException(), isNull);
        for (final id in [
          'download',
          'refresh',
          'change_source',
          'catalog',
          'search',
        ]) {
          final finder = find.byKey(ValueKey('reader-topbar-action-$id'));
          expect(finder, findsOneWidget, reason: id);
          expect(finder.hitTestable(), findsOneWidget, reason: '$id 可点');
        }
        expect(find.byTooltip('更多').hitTestable(), findsOneWidget);
      });
    }

    testWidgets('标题胶囊 textScale 1.5：随字体增高且无溢出', (tester) async {
      SharedPreferences.setMockInitialValues({
        PrefKeys.readMenuTopBarTitleCapsule: true,
      });
      await pumpMenu(
        tester,
        currentBook: book,
        textScaler: const TextScaler.linear(1.5),
      );
      expect(tester.takeException(), isNull);
      final capsule = find.byKey(
        const ValueKey('reader-topbar-title-capsule'),
      );
      expect(capsule, findsOneWidget);
      expect(
        tester.getSize(capsule).height,
        greaterThan(40),
        reason: '两行文本随系统字体缩放，minHeight=40 不固定高度',
      );
    });

    testWidgets('顶栏图标三态独立于底栏（titleBarIconStyle）', (tester) async {
      SharedPreferences.setMockInitialValues({
        PrefKeys.readBarStyle: 0,
        PrefKeys.titleBarIconStyle: 1,
        PrefKeys.readMenuIconStyle: 2,
      });
      await pumpMenu(tester, currentBook: book);

      final scheme = Theme.of(
        tester.element(topBarSurface('下载（离线缓存）')),
      ).colorScheme;
      final topDeco =
          tester.widget<Container>(topBarSurface('下载（离线缓存）')).decoration
              as BoxDecoration;
      expect(topDeco.color, scheme.surfaceContainerLow);

      final bottomDeco =
          tester.widget<Container>(actionSurface('全文搜索')).decoration
              as BoxDecoration;
      expect(bottomDeco.border, isNotNull, reason: '底栏仍为描边');
    });
  });

  group('菜单配色接线', () {
    testWidgets('readBarStyle=1：页面底色作 seed 生成 roles 背景', (tester) async {
      final container = makeContainer();
      final readerNotifier = container.read(readerNotifierProvider.notifier);
      readerNotifier.updateCurrentBook(book);
      await tester.pumpWidget(wrapMenu(container));
      const pageBg = Color(0xFF1A1A1A);
      readerNotifier.updateBackgroundColor(pageBg);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      // App 主题为亮色（注册项：文字日夜按 App 明暗），故用 light roles
      final roles = buildParameterizedRoles(
        style: 'tonalSpot',
        seed: pageBg.toARGB32(),
        contrastLevel: 0,
      );
      final material = tester.widget<Material>(
        find.byKey(const ValueKey('reader-bottom-panel-surface')),
      );
      expect(
        material.color,
        Color(roles.light.surfaceContainerHigh).withValues(alpha: 0.85),
      );
      expect(material.color, isNot(pageBg));
    });

    testWidgets('readBarStyle=2 自定义：背景/文字/强调按配置解析', (tester) async {
      SharedPreferences.setMockInitialValues({
        PrefKeys.readBarStyle: 2,
        PrefKeys.readMenuColorMode: 1,
        PrefKeys.readMenuBgColor: 0xFF112233,
        PrefKeys.readMenuTextColor: 0xFFEEEEEE,
        PrefKeys.readMenuAccentColor: 0xFF00AA00,
      });
      await pumpMenu(tester, currentBook: book);

      final material = tester.widget<Material>(
        find.byKey(const ValueKey('reader-bottom-panel-surface')),
      );
      expect(
        material.color,
        const Color(0xFF112233).withValues(alpha: 0.85),
      );
      final text = tester.widget<Text>(
        find
            .descendant(
              of: find.byKey(const ValueKey('reader-bottom-panel-surface')),
              matching: find.textContaining('/'),
            )
            .first,
      );
      expect(text.style?.color, const Color(0xFFEEEEEE));

      final sliderTheme = tester.widget<SliderTheme>(
        find
            .descendant(
              of: find.byKey(const ValueKey('reader-bottom-panel-surface')),
              matching: find.byType(SliderTheme),
            )
            .first,
      );
      expect(sliderTheme.data.thumbColor, const Color(0xFF00AA00));
      expect(
        sliderTheme.data.activeTrackColor,
        const Color(0xFF00AA00).withValues(alpha: 0.25),
      );
    });
  });

  group('模糊 / 边框 / 紧凑顶栏（批3b）', () {
    testWidgets('None 档：按 blurAlpha 半透明且无 BackdropFilter', (tester) async {
      for (final alpha in [85, 100]) {
        SharedPreferences.setMockInitialValues({
          PrefKeys.readBarStyle: 0,
          PrefKeys.readMenuTopBarBlurMode: 0,
          PrefKeys.readMenuBottomBarBlurMode: 0,
          PrefKeys.readMenuBlurAlpha: alpha,
        });
        await tester.pumpWidget(const SizedBox.shrink());
        await pumpMenu(tester, currentBook: book);
        final bottom = tester.widget<Material>(
          find.byKey(const ValueKey('reader-bottom-panel-surface')),
        );
        final top = tester.widget<Material>(
          find.byKey(const ValueKey('reader-topbar-surface')),
        );
        expect(bottom.color!.a, closeTo(alpha / 100, 0.001));
        expect(top.color!.a, closeTo(alpha / 100, 0.001));
        expect(
          find.byKey(const ValueKey('reader-bottom-blur-backdrop')),
          findsNothing,
        );
        expect(
          find.byKey(const ValueKey('reader-topbar-blur-backdrop')),
          findsNothing,
        );
      }
    });

    testWidgets('打开动画中途：模糊层不在 FadeTransition 下，内容层淡入', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({
        PrefKeys.readBarStyle: 0,
        PrefKeys.readMenuBottomBarBlurMode: 2,
        PrefKeys.readMenuBlurAlpha: 85,
      });
      final container = await pumpMenu(tester, visible: false);
      await tester.pumpAndSettle();
      await tester.pumpWidget(wrapMenu(container, visible: true));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 60));

      final backdrop = find.byKey(
        const ValueKey('reader-bottom-blur-backdrop'),
      );
      expect(backdrop, findsOneWidget);
      final contentFade = find.byKey(
        const ValueKey('reader-bottom-content-fade'),
      );
      expect(contentFade, findsOneWidget);
      expect(
        find.ancestor(of: backdrop, matching: contentFade),
        findsNothing,
        reason: '模糊层必须在内容 FadeTransition 之外',
      );
      final surface = find.byKey(
        const ValueKey('reader-bottom-panel-surface'),
      );
      expect(
        find.ancestor(of: surface, matching: contentFade),
        findsOneWidget,
        reason: '内容层才做淡入',
      );
      final fade = tester.widget<FadeTransition>(contentFade);
      expect(fade.opacity.value, lessThan(1), reason: '动画中途仍在淡入');
    });

    testWidgets('边框像素层序：红色 4dp 边框在内容之上可见', (tester) async {
      SharedPreferences.setMockInitialValues({
        PrefKeys.readBarStyle: 0,
        PrefKeys.readMenuBorderWidth: 4,
        PrefKeys.readMenuBorderColor: 0xFFFF0000,
        PrefKeys.readMenuBlurAlpha: 100,
      });
      final repaintKey = GlobalKey();
      await pumpMenu(
        tester,
        currentBook: book,
        repaintKey: repaintKey,
      );
      await tester.pumpAndSettle();

      final surface = tester.getRect(
        find.byKey(const ValueKey('reader-bottom-panel-surface')),
      );
      final topLine = tester.getRect(
        find.byKey(const ValueKey('reader-topbar-border')),
      );
      final points = [
        Offset(surface.left + 2, surface.center.dy),
        Offset(surface.right - 2, surface.center.dy),
        Offset(surface.center.dx, surface.bottom - 2),
        topLine.center,
      ];
      for (final point in points) {
        final color = await _samplePixel(tester, repaintKey, point);
        expect(
          color.r,
          greaterThan(0.8),
          reason: '像素 $point 应为红色，实际 $color',
        );
        expect(color.g, lessThan(0.2), reason: '像素 $point 实际 $color');
        expect(color.b, lessThan(0.2), reason: '像素 $point 实际 $color');
      }
    });

    testWidgets('底栏 Haze：BackdropFilter 半径 + alpha 85/100 + tint', (tester) async {
      for (final alpha in [85, 100]) {
        SharedPreferences.setMockInitialValues({
          PrefKeys.readBarStyle: 0,
          PrefKeys.readMenuBottomBarBlurMode: 2,
          PrefKeys.readMenuBlurRadius: 12,
          PrefKeys.readMenuBlurAlpha: alpha,
          PrefKeys.readMenuBlurColor: 0xFFFF0000,
        });
        await tester.pumpWidget(const SizedBox.shrink());
        await pumpMenu(tester, currentBook: book);
        final backdrop = tester.widget<BackdropFilter>(
          find.byKey(const ValueKey('reader-bottom-blur-backdrop')),
        );
        expect(backdrop.filter.toString(), contains('12'));
        final tint = tester.widget<ColoredBox>(
          find.byKey(const ValueKey('reader-bottom-blur-tint')),
        );
        expect(tint.color.a, closeTo(alpha / 100, 0.001));
        expect(tint.color.r, closeTo(1, 0.001));
        expect(tint.color.g, closeTo(0, 0.001));
      }
    });

    testWidgets('底栏 Progressive：渐变直接作为模糊子层，端点 alpha 正确', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({
        PrefKeys.readBarStyle: 0,
        PrefKeys.readMenuBottomBarBlurMode: 2,
        PrefKeys.readMenuBottomBarBlurStyle: 1,
        PrefKeys.readMenuBlurAlpha: 85,
      });
      await pumpMenu(tester, currentBook: book);
      final box = tester.widget<DecoratedBox>(
        find.byKey(const ValueKey('reader-bottom-blur-progressive')),
      );
      final gradient =
          (box.decoration as BoxDecoration).gradient! as LinearGradient;
      expect(gradient.begin, Alignment.bottomCenter, reason: '底栏下实上透');
      expect(gradient.colors.first.a, closeTo(0.85, 0.001));
      expect(gradient.colors.last.a, 0, reason: '透边 alpha=0');
      expect(
        find.byKey(const ValueKey('reader-bottom-blur-tint')),
        findsNothing,
        reason: 'Progressive 不再叠均匀 tint 层',
      );
    });

    testWidgets('底栏 LiquidGlass：模糊 + 高光描边 + 镜面渐变', (tester) async {
      SharedPreferences.setMockInitialValues({
        PrefKeys.readBarStyle: 0,
        PrefKeys.readMenuBottomBarBlurMode: 1,
        PrefKeys.readMenuBlurRadius: 8,
        PrefKeys.readMenuBlurAlpha: 60,
      });
      await pumpMenu(tester, currentBook: book);
      expect(
        find.byKey(const ValueKey('reader-bottom-blur-backdrop')),
        findsOneWidget,
      );
      final glass = find.byKey(const ValueKey('reader-bottom-liquid-glass'));
      expect(glass, findsOneWidget);
      final deco =
          tester.widget<DecoratedBox>(glass).decoration as BoxDecoration;
      final border = deco.border! as Border;
      expect(border.top.width, 1);
      expect(border.top.color.a, closeTo(0.22, 0.001));
      final glassGradient = deco.gradient! as LinearGradient;
      expect(glassGradient.colors.first.a, closeTo(0.10, 0.001));
    });

    testWidgets('非浮动底栏 LiquidGlass 回落 Haze（不做透镜）', (tester) async {
      SharedPreferences.setMockInitialValues({
        PrefKeys.readBarStyle: 0,
        PrefKeys.readMenuBottomBarBlurMode: 1,
        PrefKeys.readMenuFloatingBottomBar: false,
      });
      await pumpMenu(tester, currentBook: book);
      expect(
        find.byKey(const ValueKey('reader-bottom-blur-backdrop')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('reader-bottom-liquid-glass')),
        findsNothing,
      );
    });

    testWidgets('顶栏 Haze：透明 Material + 独立模糊层', (tester) async {
      SharedPreferences.setMockInitialValues({
        PrefKeys.readBarStyle: 0,
        PrefKeys.readMenuTopBarBlurMode: 2,
        PrefKeys.readMenuBlurRadius: 9,
        PrefKeys.readMenuBlurAlpha: 100,
      });
      await pumpMenu(tester, currentBook: book);
      final backdrop = tester.widget<BackdropFilter>(
        find.byKey(const ValueKey('reader-topbar-blur-backdrop')),
      );
      expect(backdrop.filter.toString(), contains('9'));
      final tint = tester.widget<ColoredBox>(
        find.byKey(const ValueKey('reader-topbar-blur-tint')),
      );
      expect(tint.color.a, closeTo(1, 0.001));
      final topMaterial = tester.widget<Material>(
        find.byKey(const ValueKey('reader-topbar-surface')),
      );
      expect(topMaterial.color, Colors.transparent);
    });

    testWidgets('边框 0/1/4 与日夜色：底栏整框、顶栏下边线', (tester) async {
      // 默认 1
      SharedPreferences.setMockInitialValues({PrefKeys.readBarStyle: 0});
      await pumpMenu(tester, currentBook: book);
      final defaultBorder = tester.widget<DecoratedBox>(
        find.byKey(const ValueKey('reader-bottom-border')),
      );
      expect(
        ((defaultBorder.decoration as BoxDecoration).border! as Border)
            .top
            .width,
        1,
      );

      // 0 = 关闭
      SharedPreferences.setMockInitialValues({
        PrefKeys.readBarStyle: 0,
        PrefKeys.readMenuBorderWidth: 0,
      });
      await tester.pumpWidget(const SizedBox.shrink());
      await pumpMenu(tester, currentBook: book);
      expect(find.byKey(const ValueKey('reader-bottom-border')), findsNothing);
      expect(find.byKey(const ValueKey('reader-topbar-border')), findsNothing);

      // 4 + 日间自定义色
      SharedPreferences.setMockInitialValues({
        PrefKeys.readBarStyle: 0,
        PrefKeys.readMenuBorderWidth: 4,
        PrefKeys.readMenuBorderColor: 0xFFFF0000,
      });
      await tester.pumpWidget(const SizedBox.shrink());
      await pumpMenu(tester, currentBook: book);
      final bottomBorder = tester.widget<DecoratedBox>(
        find.byKey(const ValueKey('reader-bottom-border')),
      );
      final border =
          (bottomBorder.decoration as BoxDecoration).border! as Border;
      expect(border.top.width, 4);
      expect(border.top.color, const Color(0xFFFF0000));
      final topBorder = tester.widget<ColoredBox>(
        find.byKey(const ValueKey('reader-topbar-border')),
      );
      expect(topBorder.color, const Color(0xFFFF0000));

      // 夜间色（dark theme）
      SharedPreferences.setMockInitialValues({
        PrefKeys.readBarStyle: 0,
        PrefKeys.readMenuBorderWidth: 2,
        PrefKeys.readMenuBorderColor: 0xFFFF0000,
        PrefKeys.readMenuBorderColorNight: 0xFF00FF00,
      });
      await tester.pumpWidget(const SizedBox.shrink());
      await pumpMenu(
        tester,
        currentBook: book,
        brightness: Brightness.dark,
      );
      final nightTop = tester.widget<ColoredBox>(
        find.byKey(const ValueKey('reader-topbar-border')),
      );
      expect(nightTop.color, const Color(0xFF00FF00));
    });

    testWidgets('胶囊开启时顶栏不画下边线（参考行为）', (tester) async {
      SharedPreferences.setMockInitialValues({
        PrefKeys.readBarStyle: 0,
        PrefKeys.readMenuBorderWidth: 2,
        PrefKeys.readMenuTopBarTitleCapsule: true,
      });
      await pumpMenu(tester, currentBook: book);
      expect(find.byKey(const ValueKey('reader-topbar-border')), findsNothing);
      expect(
        find.byKey(const ValueKey('reader-bottom-border')),
        findsOneWidget,
      );
    });

    testWidgets('液态玻璃按钮：半透明容器 + 白色高光描边', (tester) async {
      SharedPreferences.setMockInitialValues({
        PrefKeys.readBarStyle: 0,
        PrefKeys.readMenuBottomBarLiquidGlassButtons: true,
        PrefKeys.readMenuTopBarLiquidGlassButtons: true,
      });
      await pumpMenu(tester, currentBook: book);
      final bottomDeco =
          tester.widget<Container>(actionSurface('全文搜索')).decoration
              as BoxDecoration;
      expect(
        ((bottomDeco.border! as Border).top.color.a),
        closeTo(0.18, 0.001),
      );
      final topDeco =
          tester.widget<Container>(topBarSurface('下载（离线缓存）')).decoration
              as BoxDecoration;
      expect(((topDeco.border! as Border).top.color.a), closeTo(0.18, 0.001));
    });

    testWidgets('紧凑顶栏：360dp + 6 动作只留更多，书名可见', (tester) async {
      await tester.binding.setSurfaceSize(const Size(360, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      SharedPreferences.setMockInitialValues({
        PrefKeys.titleBarCompact: true,
        PrefKeys.readerTopBarActions: [
          for (final def in readerTopBarActionPool) '${def.id},true',
        ].join(';'),
      });
      await pumpMenu(tester, currentBook: book);

      expect(tester.takeException(), isNull);
      final bookName = find.byKey(const ValueKey('reader-topbar-book-name'));
      expect(bookName, findsOneWidget);
      expect(tester.getSize(bookName).width, greaterThanOrEqualTo(100));
      for (final id in [
        'download',
        'refresh',
        'change_source',
        'catalog',
        'search',
      ]) {
        expect(
          find.byKey(ValueKey('reader-topbar-action-$id')),
          findsNothing,
          reason: '紧凑模式不渲染 $id',
        );
      }
      expect(find.byTooltip('更多'), findsOneWidget);

      await tester.tap(find.byTooltip('更多'));
      await tester.pumpAndSettle();
      expect(find.text('换源'), findsOneWidget);
      expect(find.text('刷新正文'), findsOneWidget);
      expect(find.text('下载（离线缓存）'), findsOneWidget);
    });
  });
}

/// 采样 RepaintBoundary 像素（pixelRatio=1，坐标为逻辑像素）
Future<Color> _samplePixel(
  WidgetTester tester,
  GlobalKey key,
  Offset point,
) async {
  final boundary =
      key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  final image = (await tester.runAsync(() => boundary.toImage()))!;
  final data = (await tester.runAsync(
    () => image.toByteData(format: ui.ImageByteFormat.rawRgba),
  ))!;
  final x = point.dx.round().clamp(0, image.width - 1);
  final y = point.dy.round().clamp(0, image.height - 1);
  final index = (y * image.width + x) * 4;
  final color = Color.fromARGB(
    data.getUint8(index + 3),
    data.getUint8(index),
    data.getUint8(index + 1),
    data.getUint8(index + 2),
  );
  image.dispose();
  return color;
}
