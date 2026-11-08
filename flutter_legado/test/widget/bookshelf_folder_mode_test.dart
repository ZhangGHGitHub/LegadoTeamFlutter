// 书架文件夹模式（设置批6a-2）
//
// 覆盖：文件夹根网格/列表布局与列数、组卡片封面预览/书籍数/空组、
// 点入组内容与返回组根（含系统返回/主页两段式返回）、隐藏空组、
// 组菜单（切换/管理）、特殊组（视频）、组内排序/批量/拖拽。
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
import 'package:flutter_legado/src/routes.dart';
import 'package:flutter_legado/src/screens/book_group_screen.dart';
import 'package:flutter_legado/src/screens/bookshelf_screen.dart';
import 'package:flutter_legado/src/screens/home_screen.dart';
import 'package:flutter_legado/src/widgets/book_cover.dart';
import 'package:flutter_legado/src/widgets/book_grid_item.dart';
import 'package:flutter_legado/src/widgets/book_list_item.dart';
import 'package:flutter_legado/src/widgets/bookshelf/bookshelf_folder_card.dart';

import '../mocks/mocks.dart';

void main() {
  setUpAll(registerFallbacks);

  const groups = [
    BookGroup(groupId: 1, groupName: '组一', show: true, order: 1),
    BookGroup(groupId: 2, groupName: '空组', show: true, order: 2),
  ];

  final books = [
    const Book(bookUrl: 'u1', name: '书一', group: 1, totalChapterNum: 1),
    const Book(bookUrl: 'u2', name: '书二', group: 1, totalChapterNum: 1),
    const Book(bookUrl: 'u3', name: '书三', group: 1, totalChapterNum: 1),
    const Book(bookUrl: 'u4', name: '书四', group: 1, totalChapterNum: 1),
    // 未分组书：让「全部」与「组一」计数不同
    const Book(bookUrl: 'u0', name: '未分组', totalChapterNum: 1),
  ];

  Future<ProviderContainer> pumpShelf(
    WidgetTester tester, {
    Map<String, Object> prefs = const {},
    List<Book>? shelfBooks,
    List<BookGroup> shelfGroups = groups,
    Size size = const Size(400, 900),
    MockRustApi? api,
    BookshelfFolderBackController? controller,
  }) async {
    SharedPreferences.setMockInitialValues(prefs);
    tester.view.physicalSize = size * 3;
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);
    final mockApi = api ?? MockRustApi();
    when(() => mockApi.getBooks()).thenAnswer((_) async => shelfBooks ?? books);
    when(() => mockApi.getBookGroups()).thenAnswer((_) async => shelfGroups);
    when(() => mockApi.refreshToc(any(), any())).thenAnswer((_) async => []);
    await tester.pumpWidget(
      ProviderScope(
        // 同用例多次 pump 时强制重建容器
        key: UniqueKey(),
        overrides: [bookApiProvider.overrideWithValue(mockApi)],
        child: MaterialApp(
          home: BookshelfScreen(folderBackController: controller),
          routes: {AppRoutes.bookGroups: (_) => const BookGroupScreen()},
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    await tester.pumpAndSettle();
    final context = tester.element(find.byType(BookshelfScreen));
    return ProviderScope.containerOf(context);
  }

  Map<String, Object> folderPrefs({
    int groupStyle = 2,
    int folderModePortrait = 1,
    int folderModeLandscape = 1,
    int folderGridPortrait = 3,
    int folderGridLandscape = 7,
    int folderListPortrait = 1,
    int groupListStyle = 0,
    int coverCount = 4,
    bool? showBookCount,
  }) => {
    BookshelfSettings.keyBookGroupStyle: groupStyle,
    BookshelfSettings.keyBookshelfFolderLayoutModePortrait: folderModePortrait,
    BookshelfSettings.keyBookshelfFolderLayoutModeLandscape:
        folderModeLandscape,
    BookshelfSettings.keyBookshelfFolderLayoutGridPortrait: folderGridPortrait,
    BookshelfSettings.keyBookshelfFolderLayoutGridLandscape:
        folderGridLandscape,
    BookshelfSettings.keyBookshelfFolderLayoutListPortrait: folderListPortrait,
    BookshelfSettings.keyBookshelfGroupListStyle: groupListStyle,
    BookshelfSettings.keyBookshelfGroupCoverCount: coverCount,
    BookshelfSettings.keyShowBookCount: ?showBookCount,
  };

  SliverGridDelegateWithFixedCrossAxisCount? gridDelegate(WidgetTester tester) {
    final grids = find.byType(SliverGrid);
    if (grids.evaluate().isEmpty) return null;
    return tester.widget<SliverGrid>(grids.first).gridDelegate
        as SliverGridDelegateWithFixedCrossAxisCount;
  }

  testWidgets('文件夹根：默认网格 3 列、组卡片预览 4 张、书籍数/空组隐藏', (tester) async {
    await pumpShelf(tester, prefs: folderPrefs());

    expect(find.byType(TabBar), findsNothing);
    expect(gridDelegate(tester)?.crossAxisCount, 3);
    expect(find.byType(FolderGroupGridCard), findsNWidgets(2));
    // 「全部」5 本 + 「组一」4 本；隐藏空组不出现
    expect(
      find.byKey(const ValueKey('bookshelf_folder_group_-1')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('bookshelf_folder_group_1')),
      findsOneWidget,
    );
    expect(find.text('5 本'), findsOneWidget);
    expect(find.text('4 本'), findsOneWidget);
    expect(find.text('空组'), findsNothing);
    expect(find.text('0 本'), findsNothing);
    // 两张卡片各 4 张预览封面（组内书 >= 4）
    expect(find.byType(BookCover), findsNWidgets(8));
  });

  testWidgets('点组卡片进入组内容；返回钮回到文件夹根', (tester) async {
    await pumpShelf(tester, prefs: folderPrefs());

    await tester.tap(find.byKey(const ValueKey('bookshelf_folder_group_1')));
    await tester.pumpAndSettle();

    expect(find.byType(FolderGroupGridCard), findsNothing);
    expect(find.byType(BookGridItem), findsNWidgets(4));
    expect(
      tester
          .widget<Text>(
            find.byKey(const ValueKey('bookshelf_folder_group_title')).first,
          )
          .data,
      '组一',
    );
    expect(
      tester
          .widget<Text>(
            find.byKey(const ValueKey('bookshelf_folder_group_count')).first,
          )
          .data,
      '4 本',
    );
    expect(find.byKey(const ValueKey('bookshelf_folder_back')), findsOneWidget);
    // 组内仍为 6a-1 网格
    expect(gridDelegate(tester)?.crossAxisCount, 3);

    await tester.tap(find.byKey(const ValueKey('bookshelf_folder_back')));
    await tester.pumpAndSettle();
    expect(find.byType(FolderGroupGridCard), findsNWidgets(2));
    expect(find.byType(BookGridItem), findsNothing);
  });

  testWidgets('系统返回：组内先回组根，再返回不误退出（独立宿主 PopScope）', (tester) async {
    await pumpShelf(tester, prefs: folderPrefs());

    await tester.tap(find.byKey(const ValueKey('bookshelf_folder_group_1')));
    await tester.pumpAndSettle();
    expect(find.byType(BookGridItem), findsNWidgets(4));

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(FolderGroupGridCard), findsNWidgets(2));
    expect(find.byType(BookGridItem), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('文件夹网格列数 5 / 横屏 7', (tester) async {
    await pumpShelf(tester, prefs: folderPrefs(folderGridPortrait: 5));
    expect(gridDelegate(tester)?.crossAxisCount, 5);

    await pumpShelf(
      tester,
      size: const Size(900, 400),
      prefs: folderPrefs(folderGridLandscape: 7),
    );
    expect(gridDelegate(tester)?.crossAxisCount, 7);
  });

  testWidgets('文件夹列表：分组样式显示最近阅读，紧凑样式隐藏', (tester) async {
    await pumpShelf(
      tester,
      prefs: folderPrefs(
        folderModePortrait: 0,
        folderListPortrait: 1,
        groupListStyle: 0,
      ),
    );
    expect(find.byType(FolderGroupListCard), findsNWidgets(2));
    expect(find.text('最近阅读：书一'), findsWidgets);
    expect(find.text('5 本'), findsOneWidget);
    expect(find.text('4 本'), findsOneWidget);

    await pumpShelf(
      tester,
      prefs: folderPrefs(
        folderModePortrait: 0,
        folderListPortrait: 1,
        groupListStyle: 1,
      ),
    );
    expect(find.byType(FolderGroupListCard), findsNWidgets(2));
    expect(find.textContaining('最近阅读：'), findsNothing);
    expect(find.text('4 本'), findsOneWidget);

    // 多列列表使用多列网格承载
    await pumpShelf(
      tester,
      prefs: folderPrefs(
        folderModePortrait: 0,
        folderListPortrait: 2,
        groupListStyle: 0,
      ),
    );
    expect(gridDelegate(tester)?.crossAxisCount, 2);
    expect(find.byType(FolderGroupListCard), findsWidgets);
  });

  testWidgets('文件夹列表：5 列 + 1.6 字号不溢出', (tester) async {
    tester.platformDispatcher.textScaleFactorTestValue = 1.6;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await pumpShelf(
      tester,
      prefs: folderPrefs(
        folderModePortrait: 0,
        folderListPortrait: 5,
        groupListStyle: 0,
      ),
    );
    expect(gridDelegate(tester)?.crossAxisCount, 5);
    expect(tester.takeException(), isNull);
  });

  testWidgets('横排封面样式：数量 3/1 控制预览封面数', (tester) async {
    await pumpShelf(
      tester,
      prefs: folderPrefs(
        folderModePortrait: 0,
        groupListStyle: 2,
        coverCount: 3,
      ),
    );
    expect(find.byType(FolderGroupHorizontalCard), findsNWidgets(2));
    // 全部组 3 张 + 组一组 3 张
    expect(find.byType(BookCover), findsNWidgets(6));
    expect(find.text('5 本'), findsOneWidget);
    expect(find.text('4 本'), findsOneWidget);

    await pumpShelf(
      tester,
      prefs: folderPrefs(
        folderModePortrait: 0,
        groupListStyle: 2,
        coverCount: 1,
      ),
    );
    expect(find.byType(BookCover), findsNWidgets(2));
  });

  testWidgets('显示分组书籍数关闭：卡片不显示 N 本', (tester) async {
    await pumpShelf(tester, prefs: folderPrefs(showBookCount: false));
    expect(find.byType(FolderGroupGridCard), findsNWidgets(2));
    expect(find.textContaining(' 本'), findsNothing);
  });

  testWidgets('空组开关：隐藏空分组关闭后显示 0 本卡片', (tester) async {
    await pumpShelf(
      tester,
      prefs: {...folderPrefs(), BookshelfSettings.keyHideEmptyGroups: false},
    );
    expect(find.byType(FolderGroupGridCard), findsNWidgets(3));
    expect(find.text('空组'), findsOneWidget);
    expect(find.text('0 本'), findsOneWidget);
  });

  testWidgets('特殊组（视频）作为组卡片显示', (tester) async {
    final videoBooks = [
      const Book(
        bookUrl: 'v1',
        name: '视频书',
        bookType: BookType.video,
        totalChapterNum: 1,
      ),
      const Book(bookUrl: 'n1', name: '普通书', totalChapterNum: 1),
    ];
    await pumpShelf(
      tester,
      shelfBooks: videoBooks,
      shelfGroups: const [],
      prefs: folderPrefs(),
    );
    expect(find.text('视频'), findsOneWidget);
    expect(find.byType(FolderGroupGridCard), findsNWidgets(2));
  });

  testWidgets('组菜单：切换分组 / 管理分组入口 / 书籍数', (tester) async {
    await pumpShelf(tester, prefs: folderPrefs());

    await tester.tap(find.byKey(const ValueKey('bookshelf_folder_group_1')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('bookshelf_folder_group_menu')));
    await tester.pumpAndSettle();

    expect(find.text('选择分组'), findsOneWidget);
    expect(find.text('管理分组'), findsOneWidget);
    // 组菜单显示书籍数（全部 5 / 组一 4）
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('bookshelf_group_menu_-1')),
        matching: find.text('5 本'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('bookshelf_group_menu_1')),
        matching: find.text('4 本'),
      ),
      findsOneWidget,
    );

    await tester.tap(find.text('管理分组'));
    await tester.pumpAndSettle();
    expect(find.byType(BookGroupScreen), findsOneWidget);
  });

  testWidgets('组内排序：书名升序在组内容生效', (tester) async {
    final sortedBooks = [
      const Book(bookUrl: 'b', name: 'B书', group: 1, totalChapterNum: 1),
      const Book(bookUrl: 'a', name: 'A书', group: 1, totalChapterNum: 1),
      const Book(bookUrl: 'c', name: 'C书', group: 1, totalChapterNum: 1),
    ];
    await pumpShelf(
      tester,
      shelfBooks: sortedBooks,
      prefs: {
        ...folderPrefs(),
        BookshelfSettings.keyBookshelfSort: 2,
        BookshelfSettings.keyBookshelfSortOrder: 0,
      },
    );
    await tester.tap(find.byKey(const ValueKey('bookshelf_folder_group_1')));
    await tester.pumpAndSettle();

    final titles = tester
        .widgetList<BookGridItem>(find.byType(BookGridItem))
        .map((w) => w.title)
        .toList();
    expect(titles, ['A书', 'B书', 'C书']);
  });

  testWidgets('组内批量：点击切换选中并显示批量摘要', (tester) async {
    final container = await pumpShelf(tester, prefs: folderPrefs());
    await tester.tap(find.byKey(const ValueKey('bookshelf_folder_group_1')));
    await tester.pumpAndSettle();

    container.read(bookshelfNotifierProvider.notifier).toggleBatchMode();
    await tester.pumpAndSettle();
    expect(find.textContaining('已选 0 本'), findsOneWidget);

    await tester.tap(find.byType(BookGridItem).first);
    await tester.pumpAndSettle();
    final selected = container.read(bookshelfNotifierProvider).selectedUrls;
    expect(selected, hasLength(1));
    expect(find.textContaining('已选 1 本'), findsOneWidget);
  });

  testWidgets('组内手动排序：长按拖拽调用 reorderBooks', (tester) async {
    final api = MockRustApi();
    when(() => api.reorderBooks(any())).thenAnswer((_) async {});
    final manualBooks = [
      const Book(
        bookUrl: 'u1',
        name: '书一',
        group: 1,
        order: 0,
        totalChapterNum: 1,
      ),
      const Book(
        bookUrl: 'u2',
        name: '书二',
        group: 1,
        order: 1,
        totalChapterNum: 1,
      ),
      const Book(
        bookUrl: 'u3',
        name: '书三',
        group: 1,
        order: 2,
        totalChapterNum: 1,
      ),
    ];
    final container = await pumpShelf(
      tester,
      api: api,
      shelfBooks: manualBooks,
      prefs: {
        ...folderPrefs(),
        BookshelfSettings.keyBookshelfLayoutModePortrait: 0,
        BookshelfSettings.keyBookshelfSort: 3,
        BookshelfSettings.keyBookshelfSortOrder: 0,
      },
    );
    await tester.tap(find.byKey(const ValueKey('bookshelf_folder_group_1')));
    await tester.pumpAndSettle();
    expect(find.byType(SliverReorderableList), findsOneWidget);

    final firstItem = find.byType(BookListItem).first;
    final gesture = await tester.startGesture(tester.getCenter(firstItem));
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump(const Duration(milliseconds: 300));
    await gesture.moveBy(const Offset(0, 30));
    await tester.pump(const Duration(milliseconds: 100));
    await gesture.moveTo(tester.getCenter(find.byType(BookListItem).at(1)));
    await tester.pump(const Duration(milliseconds: 200));
    await gesture.up();
    await tester.pumpAndSettle();

    verify(() => api.reorderBooks(any())).called(1);
    final stored = container.read(bookshelfNotifierProvider).books;
    final first = stored.firstWhere((b) => b.bookUrl == 'u1');
    final second = stored.firstWhere((b) => b.bookUrl == 'u2');
    expect(first.order, greaterThan(second.order));
  });

  testWidgets('主页返回键：组内 → 组根（无退出提示），根级 → 双击退出提示', (tester) async {
    SharedPreferences.setMockInitialValues(folderPrefs());
    tester.view.physicalSize = const Size(400 * 3, 900 * 3);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);
    final api = MockRustApi();
    when(() => api.getBooks()).thenAnswer((_) async => books);
    when(() => api.getBookGroups()).thenAnswer((_) async => groups);
    when(() => api.getBookSources()).thenAnswer((_) async => []);
    when(() => api.getRssSources()).thenAnswer((_) async => []);
    when(() => api.getReadRecords()).thenAnswer((_) async => []);
    when(() => api.readRecordDailyList(any())).thenAnswer((_) async => []);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [bookApiProvider.overrideWithValue(api)],
        child: const MaterialApp(home: HomeScreen()),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('bookshelf_folder_group_1')));
    await tester.pumpAndSettle();
    expect(find.byType(BookGridItem), findsNWidgets(4));

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(FolderGroupGridCard), findsNWidgets(2));
    expect(find.text('再按一次退出程序'), findsNothing);

    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(find.text('再按一次退出程序'), findsOneWidget);
  });
}
