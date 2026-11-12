// 书架内搜索过滤 + 「搜索直达」开关行为回归
//
// 对齐参考版 BookshelfScreen.onSearchClick / onSearchLongClick：
// - 搜索直达开（默认）：点击 → 全局搜索页；长按 → 书架内过滤
// - 搜索直达关：点击 → 书架内过滤；长按 → 全局搜索页
// 过滤条输入即筛（书名/作者等），无匹配显示空态，清除后恢复。
//
// [审查回修] 补充：过滤态误删防护（屏外私密书不参与全选/删除）、
// 默认样式返回键退出过滤、手动排序禁用拖拽、文件夹根目录回落。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/l10n/app_strings.dart';
import 'package:flutter_legado/src/models/bookshelf_settings.dart';
import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/providers/bookshelf/bookshelf_notifier.dart';
import 'package:flutter_legado/src/providers/privacy/privacy_content_notifier.dart';
import 'package:flutter_legado/src/providers/privacy/privacy_notifier.dart';
import 'package:flutter_legado/src/providers/privacy/privacy_state.dart';
import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/routes.dart';
import 'package:flutter_legado/src/screens/bookshelf_screen.dart';
import 'package:flutter_legado/src/services/book_api.dart'
    show DeleteBooksResult;
import 'package:flutter_legado/src/services/privacy_content_service.dart';
import 'package:flutter_legado/src/widgets/book_grid_item.dart';

import '../mocks/mocks.dart';

/// 记录 push 的路由名
class _RouteRecorder extends NavigatorObserver {
  final List<String?> pushed = [];

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    pushed.add(route.settings.name);
    super.didPush(route, previousRoute);
  }
}

/// 隐私开关已启用（enabled + verifyOnOpenBook）的假状态
class _FakePrivacyNotifier extends PrivacyNotifier {
  @override
  PrivacyState build() =>
      const PrivacyState(enabled: true, hasPassword: true, loaded: true);
}

/// 固定私密 URL 快照的假内容 notifier（避免测试依赖 FFI 标记读取）
class _FakePrivacyContentNotifier extends PrivacyContentNotifier {
  _FakePrivacyContentNotifier(this.privateUrls);

  final Set<String> privateUrls;

  @override
  PrivacyContentSnapshot build() =>
      PrivacyContentSnapshot(loaded: true, privateBookUrls: privateUrls);

  @override
  Future<PrivacyContentSnapshot> ensureLoaded() async => state;
}

void main() {
  setUpAll(() {
    registerFallbacks();
    // deleteBooks(List<String>, ...) 的 any() 需要 List 兜底
    registerFallbackValue(<String>[]);
  });

  Future<ProviderContainer> pumpShelf(
    WidgetTester tester, {
    required MockRustApi api,
    Map<String, Object> prefs = const {},
    NavigatorObserver? observer,
    List<Book>? books,
    Set<String> privateUrls = const {},
    BookshelfFolderBackController? folderBackController,
  }) async {
    SharedPreferences.setMockInitialValues(prefs);
    when(() => api.getBooks()).thenAnswer(
      (_) async =>
          books ??
          const [
            Book(bookUrl: 'u1', name: '书一', author: '作者甲'),
            Book(bookUrl: 'u2', name: '书二', author: '作者乙'),
          ],
    );
    when(() => api.getBookGroups()).thenAnswer((_) async => const []);
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        // 同一用例多次 pumpShelf 时强制重建容器（overrides 数量不同不允许复用）
        key: UniqueKey(),
        overrides: [
          bookApiProvider.overrideWithValue(api),
          if (privateUrls.isNotEmpty) ...[
            privacyNotifierProvider.overrideWith(_FakePrivacyNotifier.new),
            privacyContentProvider.overrideWith(
              () => _FakePrivacyContentNotifier(privateUrls),
            ),
          ],
        ],
        child: MaterialApp(
          navigatorObservers: observer == null ? const [] : [observer],
          routes: {
            AppRoutes.search: (_) => const Scaffold(body: Text('search-stub')),
          },
          home: BookshelfScreen(folderBackController: folderBackController),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return ProviderScope.containerOf(
      tester.element(find.byType(BookshelfScreen)),
    );
  }

  final searchButton = find.byKey(const ValueKey('bookshelf_search_button'));
  final filterField = find.byKey(const ValueKey('bookshelf_filter_field'));
  final filterClear = find.byKey(const ValueKey('bookshelf_filter_clear'));

  /// 书名卡片（排除过滤输入框自身的 EditableText 命中）
  Finder shelfTitle(String name) =>
      find.descendant(of: find.byType(BookGridItem), matching: find.text(name));

  testWidgets('搜索直达开（默认）：点击进搜索页，长按进书架内过滤', (tester) async {
    final api = MockRustApi();
    final recorder = _RouteRecorder();
    await pumpShelf(tester, api: api, observer: recorder);

    expect(find.byTooltip('搜索'), findsOneWidget);
    await tester.tap(searchButton);
    await tester.pumpAndSettle();
    expect(recorder.pushed, contains(AppRoutes.search));
    expect(find.text('search-stub'), findsOneWidget);
    expect(filterField, findsNothing);
  });

  testWidgets('搜索直达开：长按进入书架内过滤', (tester) async {
    final api = MockRustApi();
    await pumpShelf(tester, api: api);

    await tester.longPress(searchButton);
    await tester.pumpAndSettle();
    expect(filterField, findsOneWidget);
    expect(shelfTitle('书一'), findsOneWidget);
    expect(shelfTitle('书二'), findsOneWidget);
  });

  testWidgets('搜索直达关：点击进书架内过滤，长按进搜索页', (tester) async {
    final api = MockRustApi();
    final recorder = _RouteRecorder();
    await pumpShelf(
      tester,
      api: api,
      observer: recorder,
      prefs: {BookshelfSettings.keyBookshelfSearchActionDirectToSearch: false},
    );

    expect(find.byTooltip('书架内搜索'), findsOneWidget);
    await tester.tap(searchButton);
    await tester.pumpAndSettle();
    expect(filterField, findsOneWidget);
    expect(recorder.pushed, isNot(contains(AppRoutes.search)));

    // 再点搜索按钮 → 退出过滤（参考版同一入口切换）
    await tester.tap(searchButton);
    await tester.pumpAndSettle();
    expect(filterField, findsNothing);
    // 退出过滤后长按 → 全局搜索页
    await tester.longPress(searchButton);
    await tester.pumpAndSettle();
    expect(recorder.pushed, contains(AppRoutes.search));
  });

  testWidgets('过滤：书名/作者即筛、无匹配空态、清除恢复', (tester) async {
    final api = MockRustApi();
    await pumpShelf(tester, api: api);

    await tester.longPress(searchButton);
    await tester.pumpAndSettle();
    expect(filterField, findsOneWidget);

    // 书名匹配
    await tester.enterText(filterField, '书二');
    await tester.pumpAndSettle();
    expect(shelfTitle('书二'), findsOneWidget);
    expect(shelfTitle('书一'), findsNothing);

    // 作者匹配
    await tester.enterText(filterField, '作者甲');
    await tester.pumpAndSettle();
    expect(shelfTitle('书一'), findsOneWidget);
    expect(shelfTitle('书二'), findsNothing);

    // 无匹配 → 空态（输入条保留，可继续修改）
    await tester.enterText(filterField, '不存在的书');
    await tester.pumpAndSettle();
    expect(find.text('未找到匹配的书籍'), findsOneWidget);
    expect(filterField, findsOneWidget);
    expect(shelfTitle('书一'), findsNothing);

    // 点清除（有关键词）→ 恢复全部，过滤条仍在
    await tester.tap(filterClear);
    await tester.pumpAndSettle();
    expect(shelfTitle('书一'), findsOneWidget);
    expect(shelfTitle('书二'), findsOneWidget);
    expect(filterField, findsOneWidget);

    // 再点清除（无关键词）→ 退出过滤
    await tester.tap(filterClear);
    await tester.pumpAndSettle();
    expect(filterField, findsNothing);
    expect(find.byTooltip('搜索'), findsOneWidget);
  });

  testWidgets('默认顶栏样式：返回键优先退出过滤', (tester) async {
    final api = MockRustApi();
    final back = BookshelfFolderBackController();
    await pumpShelf(tester, api: api, folderBackController: back);

    await tester.longPress(searchButton);
    await tester.pumpAndSettle();
    expect(filterField, findsOneWidget);

    expect(back.handleBack(), isTrue);
    await tester.pumpAndSettle();
    expect(filterField, findsNothing);
  });

  testWidgets('过滤态禁用手动排序拖拽', (tester) async {
    final api = MockRustApi();
    await pumpShelf(
      tester,
      api: api,
      prefs: {BookshelfSettings.keyBookshelfSort: 3},
    );

    // 手动排序（网格回落列表）正常提供 SliverReorderableList
    expect(find.byType(SliverReorderableList), findsOneWidget);

    await tester.longPress(searchButton);
    await tester.pumpAndSettle();
    expect(filterField, findsOneWidget);
    expect(find.byType(SliverReorderableList), findsNothing);
    // 过滤态回落普通列表（非网格卡片）
    expect(find.text('书一'), findsOneWidget);
  });

  testWidgets('文件夹根目录：过滤回落平铺列表，退出后恢复根目录', (tester) async {
    final api = MockRustApi();
    await pumpShelf(
      tester,
      api: api,
      prefs: {BookshelfSettings.keyBookGroupStyle: 2},
    );

    final folderCard = find.byKey(const ValueKey('bookshelf_folder_group_-1'));
    expect(folderCard, findsOneWidget);

    await tester.longPress(searchButton);
    await tester.pumpAndSettle();
    expect(filterField, findsOneWidget);
    expect(folderCard, findsNothing);
    expect(shelfTitle('书一'), findsOneWidget);

    // 关键词为空时清除按钮 = 退出过滤 → 回到根目录
    await tester.tap(filterClear);
    await tester.pumpAndSettle();
    expect(filterField, findsNothing);
    expect(folderCard, findsOneWidget);
  });

  testWidgets('空态三分：无匹配 / 私密被排除 / 真空白', (tester) async {
    final api = MockRustApi();
    await pumpShelf(tester, api: api);
    await tester.longPress(searchButton);
    await tester.pumpAndSettle();
    await tester.enterText(filterField, '不存在的书');
    await tester.pumpAndSettle();
    expect(find.text('未找到匹配的书籍'), findsOneWidget);

    // 私密未授权命中 → 明确提示验证，不显示「无匹配」
    final api2 = MockRustApi();
    await pumpShelf(
      tester,
      api: api2,
      books: const [
        Book(bookUrl: 'u1', name: '公开书', author: '作者'),
        Book(bookUrl: 'u2', name: '私密书', author: '作者'),
      ],
      privateUrls: const {'u2'},
    );
    await tester.longPress(searchButton);
    await tester.pumpAndSettle();
    await tester.enterText(filterField, '私密');
    await tester.pumpAndSettle();
    expect(find.text('匹配的书籍均为私密内容，验证后查看'), findsOneWidget);

    // 真空书架 → 原空态文案
    final api3 = MockRustApi();
    await pumpShelf(tester, api: api3, books: const []);
    await tester.longPress(searchButton);
    await tester.pumpAndSettle();
    expect(find.text(AppStrings.emptyBookshelf), findsOneWidget);
  });

  testWidgets('误删防护：过滤态全选/删除只作用于可见交集', (tester) async {
    final api = MockRustApi();
    when(
      () => api.deleteBooks(any(), deleteOriginal: false),
    ).thenAnswer((_) async => const DeleteBooksResult(deleted: 1, missing: 0));
    final container = await pumpShelf(
      tester,
      api: api,
      books: const [
        Book(bookUrl: 'u1', name: '公开书', author: '作者'),
        Book(bookUrl: 'u2', name: '私密书', author: '作者'),
      ],
      privateUrls: const {'u2'},
    );
    final notifier = container.read(bookshelfNotifierProvider.notifier);

    await tester.longPress(searchButton);
    await tester.pumpAndSettle();
    await tester.enterText(filterField, '书');
    await tester.pumpAndSettle();
    expect(shelfTitle('公开书'), findsOneWidget);
    expect(shelfTitle('私密书'), findsNothing);

    // 模拟修复前全选遗留的屏外隐藏选中项
    notifier.toggleBatchMode();
    notifier.selectAll();
    notifier.toggleSelect('u2');
    await tester.pumpAndSettle();
    expect(find.text('已选 1 本'), findsOneWidget);
    expect(find.text(' · 共 1 本'), findsOneWidget);

    await tester.tap(find.byTooltip('删除'));
    await tester.pumpAndSettle();
    expect(find.text('已选1本（另有1本未显示，不会删除）'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, '删除'));
    await tester.pumpAndSettle();

    final captured = verify(
      () => api.deleteBooks(captureAny(), deleteOriginal: false),
    ).captured;
    expect(captured.single, ['u1']);
  });
}
