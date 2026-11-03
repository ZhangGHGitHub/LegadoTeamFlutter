// [批3a] 阅读器菜单渲染测试：底栏图标网格 / 三态 / 分页 / 浮动形态 /
// 顶栏标题模式 / 胶囊 / 合并按钮 / 图标样式 / 配色接线。
//
// 编写：全栈工程师（批3a） ｜ 2026-11-04
import 'package:flutter/material.dart';
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
import 'package:flutter_legado/src/widgets/reader/reader_menu_panel.dart';

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

  Widget wrapMenu(ProviderContainer container) => UncontrolledProviderScope(
    container: container,
    child: MaterialApp(
      routes: {
        AppRoutes.bookInfo: (_) => const Scaffold(body: Text('书籍详情页')),
        AppRoutes.offlineCache: (_) => const Scaffold(body: Text('缓存管理页')),
      },
      home: Scaffold(
        body: Stack(
          children: [
            ReaderMenuPanel(
              visible: true,
              onBack: () {},
              onAddBookmark: () {},
              onOpenCatalog: () {},
              onOpenSettings: () {},
              onOpenAdvancedConfig: () {},
              onOpenContentSearch: () {},
              onReadAloud: () {},
              onToggleAutoPage: () {},
              onOpenReplaceRules: () {},
            ),
          ],
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
  }) async {
    final container = makeContainer();
    if (currentBook != null) stubOpenBook();
    await tester.pumpWidget(wrapMenu(container));
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
    testWidgets('readBarStyle=1：顶/底栏背景跟随阅读页底色', (tester) async {
      final container = makeContainer();
      // 阅读页底色改为夜间深色（默认文字色为 #CCCCCC）
      final readerNotifier = container.read(readerNotifierProvider.notifier);
      readerNotifier.updateCurrentBook(book);
      await tester.pumpWidget(wrapMenu(container));
      readerNotifier.updateBackgroundColor(const Color(0xFF1A1A1A));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      final material = tester.widget<Material>(
        find.byKey(const ValueKey('reader-bottom-panel-surface')),
      );
      expect(material.color, const Color(0xFF1A1A1A));
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
      expect(material.color, const Color(0xFF112233));
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
      expect(sliderTheme.data.thumbColor, const Color(0xFFEEEEEE));
      expect(
        sliderTheme.data.activeTrackColor,
        const Color(0xFFEEEEEE).withValues(alpha: 0.25),
      );
    });
  });
}
