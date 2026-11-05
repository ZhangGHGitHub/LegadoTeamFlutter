// 书架核心渲染接线（设置批6a-1）
//
// 覆盖：网格/列表切换、网格样式、标题设置、标签/角标/新章圆点、
// 分隔线/卡片色、快速滚动条、分组样式 0/1、隐藏空分组、手动排序拖拽、
// 更多信息子项、更新数量限制。
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/models/bookshelf_settings.dart';
import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/providers/bookshelf/bookshelf_notifier.dart';
import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/screens/bookshelf_screen.dart';
import 'package:flutter_legado/src/widgets/book_cover.dart';
import 'package:flutter_legado/src/widgets/bookshelf/bookshelf_config_sheet.dart';
import 'package:flutter_legado/src/widgets/book_display_tags_row.dart';
import 'package:flutter_legado/src/widgets/book_grid_item.dart';
import 'package:flutter_legado/src/widgets/book_list_item.dart';
import 'package:flutter_legado/src/widgets/md3_fast_scroller.dart';
import 'package:flutter_legado/src/widgets/skeleton.dart';

import '../mocks/mocks.dart';

void main() {
  setUpAll(registerFallbacks);

  final defaultBooks = [
    const Book(
      bookUrl: 'u1',
      name: '书一',
      author: '作者甲',
      totalChapterNum: 10,
      durChapterIndex: 0,
      durChapterTitle: '第一章',
      latestChapterTitle: '第十章 终章',
      latestChapterTime: 1000,
      lastCheckCount: 0,
    ),
    const Book(
      bookUrl: 'u2',
      name: '书二',
      author: '作者乙',
      totalChapterNum: 20,
      durChapterIndex: 5,
      durChapterTitle: '第六章',
      latestChapterTitle: '第二十章 结局',
      latestChapterTime: 2000,
      lastCheckCount: 2,
    ),
  ];

  Future<ProviderContainer> pumpShelf(
    WidgetTester tester, {
    Map<String, Object> prefs = const {},
    List<Book>? books,
    List<BookGroup> groups = const [],
    Size size = const Size(400, 900),
    MockRustApi? api,
    double? paneWidth,
  }) async {
    SharedPreferences.setMockInitialValues(prefs);
    tester.view.physicalSize = size * 3;
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);
    final mockApi = api ?? MockRustApi();
    when(() => mockApi.getBooks())
        .thenAnswer((_) async => books ?? defaultBooks);
    when(() => mockApi.getBookGroups()).thenAnswer((_) async => groups);
    when(() => mockApi.refreshToc(any(), any())).thenAnswer((_) async => []);
    final screen = paneWidth == null
        ? const BookshelfScreen()
        : Align(
            alignment: Alignment.topLeft,
            child: SizedBox(width: paneWidth, child: const BookshelfScreen()),
          );
    await tester.pumpWidget(
      ProviderScope(
        // 同一用例内多次 pumpShelf 时强制重建容器（否则沿用旧设置状态）
        key: UniqueKey(),
        overrides: [bookApiProvider.overrideWithValue(mockApi)],
        child: MaterialApp(home: screen),
      ),
    );
    await tester.pump();
    await tester.pump();
    await tester.pumpAndSettle();
    final context = tester.element(find.byType(BookshelfScreen));
    return ProviderScope.containerOf(context);
  }

  SliverGridDelegateWithFixedCrossAxisCount? gridDelegate(
      WidgetTester tester) {
    final grids = find.byType(SliverGrid);
    if (grids.evaluate().isEmpty) return null;
    return tester.widget<SliverGrid>(grids.first).gridDelegate
        as SliverGridDelegateWithFixedCrossAxisCount;
  }

  testWidgets('默认网格 3 列；列表模式 2 列使用 SliverGrid 承载列表行',
      (tester) async {
    await pumpShelf(tester);
    expect(gridDelegate(tester)?.crossAxisCount, 3);
    expect(find.byType(BookGridItem), findsWidgets);

    await pumpShelf(tester, prefs: {
      BookshelfSettings.keyBookshelfLayoutModePortrait: 0,
      BookshelfSettings.keyBookshelfLayoutListPortrait: 2,
    });
    expect(gridDelegate(tester)?.crossAxisCount, 2);
    expect(find.byType(BookListItem), findsWidgets);
  });

  testWidgets('网格样式 0/1/2：标准书名在下方、紧凑叠封面、仅封面无书名',
      (tester) async {
    await pumpShelf(tester, prefs: {
      BookshelfSettings.keyBookshelfGridLayout: 0,
    });
    expect(find.text('书一'), findsOneWidget);

    await pumpShelf(tester, prefs: {
      BookshelfSettings.keyBookshelfGridLayout: 1,
    });
    expect(find.text('书一'), findsOneWidget);

    await pumpShelf(tester, prefs: {
      BookshelfSettings.keyBookshelfGridLayout: 2,
    });
    expect(find.text('书一'), findsNothing);
    expect(find.byType(BookGridItem), findsWidgets);
  });

  testWidgets('书名小字体/居中/最大行数接线', (tester) async {
    await pumpShelf(tester, prefs: {
      BookshelfSettings.keyBookshelfTitleSmallFont: true,
      BookshelfSettings.keyBookshelfTitleCenter: false,
      BookshelfSettings.keyBookshelfTitleMaxLines: 3,
    });
    final text = tester.widget<Text>(find.text('书一'));
    expect(text.style?.fontSize, 11);
    expect(text.textAlign, TextAlign.start);
    expect(text.maxLines, 3);
  });

  testWidgets('显示标签开关控制标签行', (tester) async {
    final tagged = [
      const Book(
        bookUrl: 't1',
        name: '标签书',
        customTag: '仙侠',
        totalChapterNum: 1,
      ),
    ];
    await pumpShelf(tester,
        books: tagged, prefs: {
      BookshelfSettings.keyBookshelfShowTag: false,
    });
    expect(find.byType(BookDisplayTagsRow), findsNothing);

    await pumpShelf(tester,
        books: tagged, prefs: {
      BookshelfSettings.keyBookshelfShowTag: true,
    });
    expect(find.byType(BookDisplayTagsRow), findsWidgets);
    expect(find.text('仙侠'), findsOneWidget);
  });

  testWidgets('未读角标与显示未读开关', (tester) async {
    await pumpShelf(tester, prefs: {
      BookshelfSettings.keyShowUnread: false,
    });
    expect(find.text('9'), findsNothing);

    await pumpShelf(tester, prefs: {
      BookshelfSettings.keyShowUnread: true,
    });
    // u1: 10 - 0 - 1 = 9
    expect(find.text('9'), findsOneWidget);
  });

  testWidgets('新章节圆点受 showUnreadNew 控制', (tester) async {
    await pumpShelf(tester, prefs: {
      BookshelfSettings.keyShowUnreadNew: true,
    });
    expect(find.byKey(const ValueKey('bookshelf-new-dot-书二')),
        findsOneWidget);
    expect(find.byKey(const ValueKey('bookshelf-new-dot-书一')),
        findsNothing);

    await pumpShelf(tester, prefs: {
      BookshelfSettings.keyShowUnreadNew: false,
    });
    expect(find.byKey(const ValueKey('bookshelf-new-dot-书二')),
        findsNothing);
  });

  testWidgets('列表分隔线与日夜卡片色', (tester) async {
    await pumpShelf(tester, prefs: {
      BookshelfSettings.keyBookshelfLayoutModePortrait: 0,
      BookshelfSettings.keyBookshelfShowDivider: false,
    });
    expect(
      find.descendant(
          of: find.byType(BookListItem), matching: find.byType(Divider)),
      findsNothing,
    );

    await pumpShelf(tester, prefs: {
      BookshelfSettings.keyBookshelfLayoutModePortrait: 0,
      BookshelfSettings.keyBookshelfShowDivider: true,
      BookshelfSettings.keyBookshelfCardColor: 0xFF112233,
    });
    expect(
      find.descendant(
          of: find.byType(BookListItem), matching: find.byType(Divider)),
      findsWidgets,
    );
    expect(
      find.byWidgetPredicate(
          (w) => w is Material && w.color == const Color(0xFF112233)),
      findsWidgets,
    );
  });

  testWidgets('快速滚动条开关', (tester) async {
    await pumpShelf(tester);
    expect(find.byType(Md3FastScroller), findsNothing);

    await pumpShelf(tester, prefs: {
      BookshelfSettings.keyShowBookshelfFastScroller: true,
    });
    expect(find.byType(Md3FastScroller), findsOneWidget);
  });

  testWidgets('分组样式 1：隐藏 TabBar，顶部组标题 + 组菜单', (tester) async {
    final groups = const [
      BookGroup(groupId: 1, groupName: '未读', show: true, order: 1),
      BookGroup(groupId: 2, groupName: '小说', show: true, order: 2),
    ];
    final books = [
      const Book(
          bookUrl: 'g1', name: '组一书', group: 1, totalChapterNum: 1),
      const Book(
          bookUrl: 'g2', name: '组二书', group: 2, totalChapterNum: 1),
    ];
    await pumpShelf(tester,
        books: books,
        groups: groups,
        prefs: {
          BookshelfSettings.keyBookGroupStyle: 1,
          BookshelfSettings.keyHideEmptyGroups: false,
        });
    expect(find.byType(TabBar), findsNothing);
    expect(find.byKey(const ValueKey('bookshelf_group_style_title')),
        findsOneWidget);
    expect(find.byKey(const ValueKey('bookshelf_group_style_menu')),
        findsOneWidget);
    expect(find.text('全部'), findsOneWidget);

    // 组菜单切换到「未读」组
    await tester
        .tap(find.byKey(const ValueKey('bookshelf_group_style_menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('未读'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<Text>(
              find.byKey(const ValueKey('bookshelf_group_style_title')))
          .data,
      '未读',
    );
    expect(find.text('组一书'), findsOneWidget);
    expect(find.text('组二书'), findsNothing);
  });

  testWidgets('分组样式 0：更多分组按钮打开组菜单', (tester) async {
    final groups = const [
      BookGroup(groupId: 1, groupName: '未读', show: true, order: 1),
      BookGroup(groupId: 2, groupName: '小说', show: true, order: 2),
    ];
    final books = [
      const Book(
          bookUrl: 'g1', name: '组一书', group: 1, totalChapterNum: 1),
      const Book(
          bookUrl: 'g2', name: '组二书', group: 2, totalChapterNum: 1),
    ];
    await pumpShelf(tester, books: books, groups: groups, prefs: {
      BookshelfSettings.keyHideEmptyGroups: false,
      BookshelfSettings.keyShouldShowExpandButton: true,
    });
    final button = find.byKey(const ValueKey('bookshelf_group_menu_button'));
    expect(button, findsOneWidget);
    await tester.tap(button);
    await tester.pumpAndSettle();
    expect(find.text('选择分组'), findsOneWidget);
    await tester.tap(find.text('小说').last);
    await tester.pumpAndSettle();
    expect(find.text('组二书'), findsOneWidget);
    expect(find.text('组一书'), findsNothing);
  });

  testWidgets('隐藏空分组：无书分组不进入 Tab 行', (tester) async {
    final groups = const [
      BookGroup(groupId: 1, groupName: '有书组', show: true, order: 1),
      BookGroup(groupId: 2, groupName: '空组', show: true, order: 2),
    ];
    final books = [
      const Book(
          bookUrl: 'g1', name: '组一书', group: 1, totalChapterNum: 1),
    ];
    await pumpShelf(tester, books: books, groups: groups, prefs: {
      BookshelfSettings.keyHideEmptyGroups: true,
    });
    expect(find.text('有书组'), findsOneWidget);
    expect(find.text('空组'), findsNothing);

    await pumpShelf(tester, books: books, groups: groups, prefs: {
      BookshelfSettings.keyHideEmptyGroups: false,
    });
    expect(find.text('空组'), findsOneWidget);
  });

  testWidgets('仅手动排序启用拖拽（其余模式普通列表）', (tester) async {
    await pumpShelf(tester, prefs: {
      BookshelfSettings.keyBookshelfLayoutModePortrait: 0,
      BookshelfSettings.keyBookshelfSort: 0,
    });
    expect(find.byType(SliverReorderableList), findsNothing);

    await pumpShelf(tester, prefs: {
      BookshelfSettings.keyBookshelfLayoutModePortrait: 0,
      BookshelfSettings.keyBookshelfSort: 3,
    });
    expect(find.byType(SliverReorderableList), findsOneWidget);
  });

  /// 长按拖拽第一个列表项到第二项位置（ReorderableDelayedDragStartListener）
  Future<void> dragFirstItemDown(WidgetTester tester) async {
    final firstItem = find.byType(BookListItem).first;
    final gesture = await tester.startGesture(tester.getCenter(firstItem));
    // 延迟拖拽：先保持不动超过 kLongPressTimeout，再分步移动到第二项
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump(const Duration(milliseconds: 300));
    await gesture.moveBy(const Offset(0, 30));
    await tester.pump(const Duration(milliseconds: 100));
    final secondItem = find.byType(BookListItem).at(1);
    await gesture.moveTo(tester.getCenter(secondItem));
    await tester.pump(const Duration(milliseconds: 200));
    await gesture.up();
    await tester.pumpAndSettle();
  }

  Future<void> expectReorderWorked(
    WidgetTester tester,
    ProviderContainer container,
    MockRustApi api,
  ) async {
    await dragFirstItemDown(tester);
    verify(() => api.reorderBooks(any())).called(1);
    final books = container.read(bookshelfNotifierProvider).books;
    final first = books.firstWhere((b) => b.bookUrl == 'u1');
    final second = books.firstWhere((b) => b.bookUrl == 'u2');
    expect(first.order, greaterThan(second.order),
        reason: '拖到第二项后 order 应大于原第二项');
  }

  testWidgets('手动排序：真实长按拖拽触发 reorderBooks 并更新 order（列表）',
      (tester) async {
    final api = MockRustApi();
    when(() => api.reorderBooks(any())).thenAnswer((_) async {});
    final books = [
      const Book(bookUrl: 'u1', name: '书一', order: 0, totalChapterNum: 1),
      const Book(bookUrl: 'u2', name: '书二', order: 1, totalChapterNum: 1),
      const Book(bookUrl: 'u3', name: '书三', order: 2, totalChapterNum: 1),
    ];
    final container = await pumpShelf(
      tester,
      api: api,
      books: books,
      prefs: {
        BookshelfSettings.keyBookshelfLayoutModePortrait: 0,
        BookshelfSettings.keyBookshelfSort: 3,
        BookshelfSettings.keyBookshelfSortOrder: 0,
      },
    );
    expect(find.byType(SliverReorderableList), findsOneWidget);
    await expectReorderWorked(tester, container, api);
  });

  testWidgets('手动排序 + 网格：提示并临时切列表，拖拽仍可用（审查 P1-2）',
      (tester) async {
    final api = MockRustApi();
    when(() => api.reorderBooks(any())).thenAnswer((_) async {});
    final books = [
      const Book(bookUrl: 'u1', name: '书一', order: 0, totalChapterNum: 1),
      const Book(bookUrl: 'u2', name: '书二', order: 1, totalChapterNum: 1),
      const Book(bookUrl: 'u3', name: '书三', order: 2, totalChapterNum: 1),
    ];
    final container = await pumpShelf(
      tester,
      api: api,
      books: books,
      prefs: {
        BookshelfSettings.keyBookshelfLayoutModePortrait: 1,
        BookshelfSettings.keyBookshelfSort: 3,
        BookshelfSettings.keyBookshelfSortOrder: 0,
      },
    );
    expect(
      find.byKey(const ValueKey('bookshelf_manual_sort_notice')),
      findsOneWidget,
    );
    expect(find.byType(SliverReorderableList), findsOneWidget);
    expect(find.byType(BookGridItem), findsNothing,
        reason: '手动排序时网格临时回落列表');
    await expectReorderWorked(tester, container, api);
  });

  testWidgets('隐藏空分组导致选中组不可见时回退「全部」（审查 P2）',
      (tester) async {
    final groups = const [
      BookGroup(groupId: 1, groupName: '有书组', show: true, order: 1),
      BookGroup(groupId: 2, groupName: '空组', show: true, order: 2),
    ];
    final books = [
      const Book(
          bookUrl: 'g1', name: '组一书', group: 1, totalChapterNum: 1),
    ];
    final container = await pumpShelf(tester, books: books, groups: groups, prefs: {
      BookshelfSettings.keyHideEmptyGroups: true,
      // 数据源索引：0=全部, 1=有书组, 2=空组（空组被隐藏）
      'bookshelf_tab_position': 2,
    });
    await tester.pumpAndSettle();
    expect(container.read(bookshelfNotifierProvider).selectedGroupIndex, 0);
    expect(find.text('有书组'), findsOneWidget);
    expect(find.text('空组'), findsNothing);
    expect(find.text('组一书'), findsOneWidget);
  });

  testWidgets('15 列加载骨架 × 三种网格样式不溢出（审查 P2）', (tester) async {
    for (final style in [0, 1, 2]) {
      final pending = Completer<List<Book>>();
      final api = MockRustApi();
      when(() => api.getBooks()).thenAnswer((_) => pending.future);
      when(() => api.getBookGroups()).thenAnswer((_) async => []);
      SharedPreferences.setMockInitialValues({
        BookshelfSettings.keyBookshelfLayoutGridPortrait: 15,
        BookshelfSettings.keyBookshelfGridLayout: style,
      });
      tester.view.physicalSize = const Size(360 * 3, 900 * 3);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ProviderScope(
          key: UniqueKey(),
          overrides: [bookApiProvider.overrideWithValue(api)],
          child: const MaterialApp(home: BookshelfScreen()),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      final skeletons = tester
          .widgetList<GridSkeletonItem>(find.byType(GridSkeletonItem))
          .toList();
      expect(skeletons, isNotEmpty, reason: '样式 $style 应显示网格骨架');
      expect(
        skeletons.every((s) => s.showText == (style == 0)),
        isTrue,
        reason: '样式 $style 的骨架文字渲染与网格样式一致',
      );
      expect(tester.takeException(), isNull,
          reason: '样式 $style / 15 列骨架不应溢出');
      pending.complete(const []);
      await tester.pump();
    }
  });

  testWidgets('更多信息：最新章节/简介显隐与精简详情', (tester) async {
    await pumpShelf(tester, prefs: {
      BookshelfSettings.keyBookshelfLayoutModePortrait: 0,
      BookshelfSettings.keyShowBookIntro: false,
    });
    expect(find.text('第十章 终章'), findsNothing);

    await pumpShelf(tester, prefs: {
      BookshelfSettings.keyBookshelfLayoutModePortrait: 0,
      BookshelfSettings.keyShowBookIntro: true,
      BookshelfSettings.keyBookshelfShowLatestChapter: false,
    });
    expect(find.text('第十章 终章'), findsNothing);

    await pumpShelf(tester, prefs: {
      BookshelfSettings.keyBookshelfLayoutModePortrait: 0,
      BookshelfSettings.keyShowBookIntro: true,
      BookshelfSettings.keyBookshelfShowLatestChapter: true,
    });
    expect(find.text('第十章 终章'), findsOneWidget);

    await pumpShelf(tester, prefs: {
      BookshelfSettings.keyBookshelfLayoutModePortrait: 0,
      BookshelfSettings.keyShowBookIntro: true,
      BookshelfSettings.keyBookshelfLayoutCompact: true,
    });
    expect(find.text('第一章'), findsNothing, reason: '精简详情隐藏当前章节');
    expect(find.textContaining('作者甲'), findsOneWidget);
  });

  testWidgets('显示书籍类型（showTip）', (tester) async {
    final audio = [
      const Book(
        bookUrl: 'a1',
        name: '音频书',
        bookType: BookType.audio,
        totalChapterNum: 1,
      ),
    ];
    await pumpShelf(tester,
        books: audio, prefs: {
      BookshelfSettings.keyShowTip: false,
    });
    expect(find.text('音频'), findsNothing);

    await pumpShelf(tester,
        books: audio, prefs: {
      BookshelfSettings.keyShowTip: true,
    });
    expect(find.text('音频'), findsOneWidget);
  });

  testWidgets('showWaitUpCount：更新中顶栏显示待更新数量', (tester) async {
    final completer = Completer<void>();
    final books = [
      const Book(
        bookUrl: 'b0',
        name: '书0',
        origin: 'https://example.com',
        totalChapterNum: 1,
        canUpdate: true,
      ),
    ];
    SharedPreferences.setMockInitialValues({
      BookshelfSettings.keyBookshelfLayoutModePortrait: 0,
      BookshelfSettings.keyShowWaitUpCount: true,
    });
    tester.view.physicalSize = const Size(400 * 3, 900 * 3);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);
    final api = MockRustApi();
    when(() => api.getBooks()).thenAnswer((_) async => books);
    when(() => api.getBookGroups()).thenAnswer((_) async => []);
    when(() => api.refreshToc(any(), any())).thenAnswer(
      (_) async {
        await completer.future;
        return [];
      },
    );
    await tester.pumpWidget(
      ProviderScope(
        key: UniqueKey(),
        overrides: [bookApiProvider.overrideWithValue(api)],
        child: const MaterialApp(home: BookshelfScreen()),
      ),
    );
    await tester.pump();
    await tester.pump();
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('更多'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('更新目录'));
    await tester.pump();
    await tester.pump();

    expect(find.byKey(const ValueKey('bookshelf_wait_up_count')),
        findsOneWidget);
    expect(find.text('待更新 1'), findsOneWidget);

    completer.complete();
    await tester.pumpAndSettle();
    expect(find.text('待更新 1'), findsNothing);
  });

  testWidgets('更新全部按数量限制截断并提示', (tester) async {
    final books = [
      for (var i = 0; i < 3; i++)
        Book(
          bookUrl: 'b$i',
          name: '书$i',
          origin: 'https://example.com',
          totalChapterNum: 1,
          canUpdate: true,
        ),
    ];
    SharedPreferences.setMockInitialValues({
      BookshelfSettings.keyBookshelfLayoutModePortrait: 0,
      BookshelfSettings.keyBookshelfRefreshingLimit: 1,
    });
    tester.view.physicalSize = const Size(400 * 3, 900 * 3);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);
    final api = MockRustApi();
    when(() => api.getBooks()).thenAnswer((_) async => books);
    when(() => api.getBookGroups()).thenAnswer((_) async => []);
    when(() => api.refreshToc(any(), any())).thenAnswer((_) async => []);
    await tester.pumpWidget(
      ProviderScope(
        // 同一用例内多次 pumpShelf 时强制重建容器（否则沿用旧设置状态）
        key: UniqueKey(),
        overrides: [bookApiProvider.overrideWithValue(api)],
        child: const MaterialApp(home: BookshelfScreen()),
      ),
    );
    await tester.pump();
    await tester.pump();
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('更多'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('更新目录'));
    await tester.pumpAndSettle();

    verify(() => api.refreshToc(any(), any())).called(1);
    expect(find.textContaining('限制 1 本'), findsOneWidget);
  });

  testWidgets('字号 1.3/1.6：网格与多列列表不溢出', (tester) async {
    final books = [
      const Book(
        bookUrl: 's1',
        name: '大字号书籍一',
        author: '作者甲',
        customTag: '仙侠',
        intro: '这是一段用于验证大字号布局的简介文字。',
        totalChapterNum: 30,
        durChapterIndex: 10,
        durChapterTitle: '第十一章',
        latestChapterTitle: '第三十章 终章',
        latestChapterTime: 1000,
      ),
      const Book(
        bookUrl: 's2',
        name: '大字号书籍二',
        author: '作者乙',
        intro: '第二本书的简介。',
        totalChapterNum: 20,
        durChapterIndex: 5,
        durChapterTitle: '第六章',
        latestChapterTitle: '第二十章',
        latestChapterTime: 2000,
      ),
    ];
    for (final scale in [1.3, 1.6]) {
      tester.platformDispatcher.textScaleFactorTestValue = scale;
      addTearDown(
          tester.platformDispatcher.clearTextScaleFactorTestValue);

      await pumpShelf(tester, books: books);
      expect(tester.takeException(), isNull,
          reason: '字号 $scale 网格不应溢出');

      await pumpShelf(tester, books: books, prefs: {
        BookshelfSettings.keyBookshelfLayoutModePortrait: 0,
        BookshelfSettings.keyBookshelfLayoutListPortrait: 2,
        BookshelfSettings.keyShowBookIntro: true,
        BookshelfSettings.keyBookshelfShowIntro: true,
        BookshelfSettings.keyBookshelfShowTag: true,
      });
      expect(tester.takeException(), isNull,
          reason: '字号 $scale 多列列表不应溢出');
    }
  });

  testWidgets('批量多列勾选图标位于封面内且点击可切换（审查 P2-1）',
      (tester) async {
    final container = await pumpShelf(tester, prefs: {
      BookshelfSettings.keyBookshelfLayoutModePortrait: 0,
      BookshelfSettings.keyBookshelfLayoutListPortrait: 2,
    });
    container.read(bookshelfNotifierProvider.notifier).toggleBatchMode();
    await tester.pumpAndSettle();

    final checkFinder =
        find.byKey(const ValueKey('bookshelf-batch-check-u1'));
    expect(checkFinder, findsOneWidget);
    final coverRect = tester.getRect(find.descendant(
      of: find.byType(BookListItem).first,
      matching: find.byType(BookCover),
    ));
    expect(
      coverRect.contains(tester.getRect(checkFinder).center),
      isTrue,
      reason: '勾选图标应落在封面矩形内（当前 ${tester.getRect(checkFinder)}）',
    );

    // IgnorePointer 让点击穿透到 BookListItem，切换选中
    await tester.tapAt(tester.getCenter(checkFinder));
    await tester.pumpAndSettle();
    expect(container.read(bookshelfNotifierProvider).selectedUrls,
        contains('u1'));
    expect(
      coverRect.contains(tester.getRect(checkFinder).center),
      isTrue,
      reason: '选中态图标仍应位于封面内',
    );
  });

  testWidgets('批量单列尾部勾选可点击切换（审查 P2-1）', (tester) async {
    final container = await pumpShelf(tester, prefs: {
      BookshelfSettings.keyBookshelfLayoutModePortrait: 0,
    });
    container.read(bookshelfNotifierProvider.notifier).toggleBatchMode();
    await tester.pumpAndSettle();

    final checkFinder =
        find.byKey(const ValueKey('bookshelf-batch-check-u1'));
    expect(checkFinder, findsOneWidget);
    await tester.tap(checkFinder);
    await tester.pumpAndSettle();
    expect(container.read(bookshelfNotifierProvider).selectedUrls,
        contains('u1'));
  });

  testWidgets('列表书籍类型标签单列/多列/批量均渲染（审查 P2）',
      (tester) async {
    final books = [
      for (var i = 0; i < 2; i++)
        Book(
          bookUrl: 'type$i',
          name: '类型书$i',
          author: '作者',
          origin: 'https://example.com',
          totalChapterNum: 1,
        ),
    ];
    var container = await pumpShelf(
      tester,
      books: books,
      prefs: {
        BookshelfSettings.keyBookshelfLayoutModePortrait: 0,
        BookshelfSettings.keyShowTip: true,
      },
    );
    expect(find.text('小说'), findsNWidgets(2));

    container = await pumpShelf(
      tester,
      books: books,
      prefs: {
        BookshelfSettings.keyBookshelfLayoutModePortrait: 0,
        BookshelfSettings.keyBookshelfLayoutListPortrait: 2,
        BookshelfSettings.keyShowTip: true,
      },
    );
    expect(find.text('小说'), findsNWidgets(2));

    container.read(bookshelfNotifierProvider.notifier).toggleBatchMode();
    await tester.pumpAndSettle();
    expect(find.text('小说'), findsNWidgets(2));
  });

  testWidgets('配置面板使用书架 pane 实际宽度（审查 P2-2）', (tester) async {
    await pumpShelf(
      tester,
      paneWidth: 600,
      size: const Size(1000, 900),
      prefs: {
        BookshelfSettings.keyBookshelfLayoutModePortrait: 0,
        BookshelfSettings.keyBookshelfLayoutListPortrait: 5,
      },
    );
    await tester.tap(find.byTooltip('更多'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('布局设置'));
    await tester.pumpAndSettle();

    final sheet = tester.widget<BookshelfConfigSheet>(
      find.byType(BookshelfConfigSheet),
    );
    expect(sheet.viewportWidth, closeTo(600, 0.1),
        reason: '多栏/窄 pane 下必须传书架 pane 宽，而非窗口 1000dp');
  });

  testWidgets('P1-1 列表 1–5 列 × 360/400dp × 1.0/1.3/1.6 × 普通/批量无溢出',
      (tester) async {
    final books = [
      const Book(
        bookUrl: 'p1',
        name: '很长很长的书籍名称一',
        author: '作者甲',
        customTag: '仙侠',
        intro: '用于验证窄列多列布局的简介文字，包含足够多的字符。',
        totalChapterNum: 100,
        durChapterIndex: 30,
        durChapterPos: 10,
        durChapterTitle: '第三十一章 很长章节名',
        latestChapterTitle: '第一百章 大结局',
        latestChapterTime: 1000,
      ),
      const Book(
        bookUrl: 'p2',
        name: '很长很长的书籍名称二',
        author: '作者乙',
        totalChapterNum: 80,
        durChapterIndex: 20,
        durChapterPos: 5,
        durChapterTitle: '第二十一章',
        latestChapterTitle: '第八十章 终章',
        latestChapterTime: 2000,
      ),
      const Book(
        bookUrl: 'p3',
        name: '很长很长的书籍名称三',
        author: '作者丙',
        totalChapterNum: 60,
        durChapterIndex: 0,
        durChapterPos: 0,
        latestChapterTitle: '第六十章',
        latestChapterTime: 3000,
      ),
    ];
    addTearDown(
        tester.platformDispatcher.clearTextScaleFactorTestValue);
    for (final width in [360.0, 400.0]) {
      for (final columns in [1, 2, 3, 4, 5]) {
        for (final scale in [1.0, 1.3, 1.6]) {
          tester.platformDispatcher.textScaleFactorTestValue = scale;
          final container = await pumpShelf(
            tester,
            books: books,
            size: Size(width, 900),
            prefs: {
              BookshelfSettings.keyBookshelfLayoutModePortrait: 0,
              BookshelfSettings.keyBookshelfLayoutListPortrait: columns,
              BookshelfSettings.keyShowBookIntro: true,
              BookshelfSettings.keyBookshelfShowIntro: true,
              BookshelfSettings.keyBookshelfShowTag: true,
            },
          );
          final reason =
              'width=$width columns=$columns scale=$scale';
          expect(tester.takeException(), isNull,
              reason: '$reason 普通模式横向溢出');

          final expected = math.min(
            columns,
            BookshelfSettings.maxReadableListColumns(width),
          );
          final delegate = gridDelegate(tester);
          if (expected <= 1) {
            expect(delegate, isNull, reason: '$reason 应为单列 SliverList');
          } else {
            expect(delegate?.crossAxisCount, expected,
                reason: '$reason 实际列数应夹取到 $expected');
          }

          container
              .read(bookshelfNotifierProvider.notifier)
              .toggleBatchMode();
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull,
              reason: '$reason 批量模式横向溢出');
        }
      }
    }
  });
}
