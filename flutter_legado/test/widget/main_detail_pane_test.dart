// [设置批2b-2c] 书架/发现/RSS 列表-详情双栏 widget 测试
//
// 覆盖：
// - 宽屏书架点书 → 右栏 BookInfo，左书架保留；返回先 pop 右栏；
// - 窄屏 / mode=off → root 全屏，右栏不占位；
// - 切 Tab 清空右栏，返回原 Tab 不再恢复旧详情；
// - 宽度变化（双→单→双）保留右栏栈与页面输入内容；
// - 右栏 BookInfo 的「阅读」固定 root 全屏（视频书分支，无阅读器 Notifier）；
// - 宽屏 RSS：源 → 文章列表 → 文章详情均在右栏，左源列表保留；
// - 最小双栏宽度（744dp）+ 2x 字体右栏 360dp 不溢出；
// - 右栏显隐不重建 PageView / 书架 State。
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/constants/pref_keys.dart';
import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/providers/explore/explore_main_state.dart';
import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/providers/rss/rss_notifier.dart';
import 'package:flutter_legado/src/routes.dart';
import 'package:flutter_legado/src/screens/book_info_screen.dart';
import 'package:flutter_legado/src/screens/bookshelf_screen.dart';
import 'package:flutter_legado/src/screens/home_screen.dart';
import 'package:flutter_legado/src/screens/rss_article_detail_screen.dart';
import 'package:flutter_legado/src/screens/rss_articles_screen.dart';
import 'package:flutter_legado/src/screens/rss_screen.dart';
import 'package:flutter_legado/src/utils/multi_pane_layout.dart';
import 'package:flutter_legado/src/widgets/explore_source_content.dart';

import '../mocks/mocks.dart';

/// 测试桩页面：文本 = `stub:<route name>`
class _StubPage extends StatelessWidget {
  const _StubPage(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    return Scaffold(body: Center(child: Text(label)));
  }
}

/// 匿名路由编辑页：验证缩窄/变宽后 State（输入内容）不丢
class _AnonEditorPage extends StatefulWidget {
  const _AnonEditorPage();

  @override
  State<_AnonEditorPage> createState() => _AnonEditorPageState();
}

class _AnonEditorPageState extends State<_AnonEditorPage> {
  final TextEditingController _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Padding(
        padding: const EdgeInsets.all(8),
        child: TextField(
          key: const ValueKey('detail-editor'),
          controller: _controller,
          maxLines: null,
          decoration: const InputDecoration(hintText: '右栏页面'),
        ),
      ),
    );
  }
}

Route<dynamic> _stubRoute(RouteSettings settings) {
  return MaterialPageRoute<void>(
    settings: settings,
    builder: (_) => _StubPage('stub:${settings.name}'),
  );
}

/// 详情栏桩路由：`book_info` 返回带输入框的匿名页（宽度保留用例）
Route<dynamic> _stubDetailRoute(RouteSettings settings) {
  if (settings.name == AppRoutes.bookInfo) {
    return MaterialPageRoute<void>(
      settings: settings,
      builder: (_) => const _AnonEditorPage(),
    );
  }
  return _stubRoute(settings);
}

/// 根导航栈深度计数
class _DepthObserver extends NavigatorObserver {
  int depth = 0;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    depth++;
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    depth--;
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    depth--;
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    if (oldRoute == null) depth++;
  }
}

void main() {
  setUpAll(registerFallbacks);

  const shelfBook = Book(
    bookUrl: 'u1',
    name: '测试书',
    author: '作者',
    coverUrl: '',
  );

  late MockRustApi api;
  late ProviderContainer container;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    api = MockRustApi();
    when(() => api.getConfig(any())).thenAnswer((_) async => null);
    when(() => api.getServerStatus()).thenAnswer((_) async => 'stopped');
    when(() => api.getBooks()).thenAnswer((_) async => const [shelfBook]);
    when(() => api.getBookGroups()).thenAnswer((_) async => const []);
    when(() => api.getBookSources()).thenAnswer((_) async => const []);
    when(() => api.getRssSources()).thenAnswer((_) async => const []);
    when(() => api.getReadRecords()).thenAnswer((_) async => const []);
    when(() => api.readRecordDailyList(any())).thenAnswer((_) async => const []);
    when(() => api.getBook(any())).thenAnswer((_) async => null);
    when(() => api.getChapters(any())).thenAnswer((_) async => const []);
    container = ProviderContainer(
      overrides: [bookApiProvider.overrideWithValue(api)],
    );
    addTearDown(container.dispose);
  });

  /// 设定逻辑窗口尺寸（devicePixelRatio=1）
  void setWindowSize(WidgetTester tester, Size size) {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
  }

  Future<void> pumpHome(
    WidgetTester tester, {
    required MultiPaneMode mode,
    required Size size,
    double textScale = 1,
    Route<dynamic> Function(RouteSettings)? detailRouteGenerator,
    Route<dynamic> Function(RouteSettings)? rootRouteGenerator,
    Map<String, Object> extraPrefs = const {},
    GlobalKey<NavigatorState>? rootKey,
    NavigatorObserver? rootObserver,
  }) async {
    SharedPreferences.setMockInitialValues({
      PrefKeys.multiPaneMode: mode.name,
      // 关闭 Rail，保证宽窗口仍用底栏切 Tab（与 2b-2b 用例同口径）
      PrefKeys.tabletInterface: 'off',
      // 跳过首启默认订阅源导入（避免依赖 rootBundle/未桩的写源接口）
      kRssSourceVersionKey: kRssSourceVersion,
      ...extraPrefs,
    });
    setWindowSize(tester, size);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          navigatorKey: rootKey,
          navigatorObservers: rootObserver == null ? const [] : [rootObserver],
          onGenerateRoute: rootRouteGenerator ?? AppRoutes.generateRoute,
          builder: (context, child) {
            return MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(textScale)),
              child: child!,
            );
          },
          home: HomeScreen(detailRouteGenerator: detailRouteGenerator),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// 右栏槽宽度（未显示时为 0）
  double detailSlotWidth(WidgetTester tester) {
    return tester
        .getSize(find.byKey(const ValueKey('main-detail-right')))
        .width;
  }

  /// 书架列表项点击（默认列表布局）
  Future<void> tapShelfBook(WidgetTester tester) async {
    await tester.tap(find.text('测试书').first);
    await tester.pumpAndSettle();
  }

  testWidgets('宽屏书架点书：右栏 BookInfo，左书架保留，返回先 pop 右栏', (tester) async {
    await pumpHome(
      tester,
      mode: MultiPaneMode.always,
      size: const Size(1000, 700),
    );

    expect(find.byType(BookshelfScreen), findsOneWidget);
    expect(detailSlotWidth(tester), 0);

    await tapShelfBook(tester);

    expect(
      find.descendant(
        of: find.byKey(const ValueKey('main-detail-right')),
        matching: find.byType(BookInfoScreen),
      ),
      findsOneWidget,
    );
    // 左书架仍在（书单/页签状态不被右栏打开破坏）
    expect(find.byType(BookshelfScreen), findsOneWidget);
    expect(detailSlotWidth(tester), greaterThanOrEqualTo(360));
    expect(
      tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex,
      1,
    );

    // 第一次返回：pop 右栏，仍停留在书架 Tab
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(BookInfoScreen), findsNothing);
    expect(find.byType(BookshelfScreen), findsOneWidget);
    expect(detailSlotWidth(tester), 0);
    expect(
      tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex,
      1,
    );
  });

  testWidgets('窄屏 / mode=off：点书 root 全屏，右栏不占位', (tester) async {
    await pumpHome(
      tester,
      mode: MultiPaneMode.off,
      size: const Size(1000, 700),
    );

    expect(find.byType(BookshelfScreen), findsOneWidget);
    expect(detailSlotWidth(tester), 0);
    await tapShelfBook(tester);

    // root 全屏：详情页在 root 栈，底栏被覆盖（不可见）
    expect(find.byType(BookInfoScreen), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('main-detail-right')),
        matching: find.byType(BookInfoScreen),
      ),
      findsNothing,
    );
    expect(find.byType(NavigationBar), findsNothing);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(BookInfoScreen), findsNothing);
    expect(find.byType(BookshelfScreen), findsOneWidget);
    expect(find.byType(NavigationBar), findsOneWidget);
    expect(detailSlotWidth(tester), 0);
  });

  testWidgets('切 Tab 清空右栏，切回书架不再恢复旧详情', (tester) async {
    await pumpHome(
      tester,
      mode: MultiPaneMode.always,
      size: const Size(1000, 700),
    );

    await tapShelfBook(tester);
    expect(find.byType(BookInfoScreen), findsOneWidget);

    // 切到发现（索引 2）：右栏清空，发现页在左
    await tester.tap(find.byType(NavigationDestination).at(2));
    await tester.pumpAndSettle();
    expect(find.byType(BookInfoScreen), findsNothing);
    expect(detailSlotWidth(tester), 0);

    // 切回书架：旧详情不恢复
    await tester.tap(find.byType(NavigationDestination).at(1));
    await tester.pumpAndSettle();
    expect(find.byType(BookshelfScreen), findsOneWidget);
    expect(find.byType(BookInfoScreen), findsNothing);
    expect(detailSlotWidth(tester), 0);
  });

  testWidgets('宽度变化保留右栏栈与输入内容（双→单→双）', (tester) async {
    await pumpHome(
      tester,
      mode: MultiPaneMode.always,
      size: const Size(1000, 700),
      detailRouteGenerator: _stubDetailRoute,
    );

    await tapShelfBook(tester);
    expect(find.byType(_AnonEditorPage), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('detail-editor')),
      '右栏草稿',
    );
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump();
    expect(detailSlotWidth(tester), greaterThanOrEqualTo(360));

    // 缩到 700dp：多栏判定不成立 → 右栏隐藏，左书架全宽
    tester.view.physicalSize = const Size(700, 700);
    await tester.pumpAndSettle();
    expect(find.byType(_AnonEditorPage), findsNothing);
    expect(detailSlotWidth(tester), 0);
    expect(find.byType(BookshelfScreen), findsOneWidget);

    // 再变宽：同一栈恢复，输入内容不丢
    tester.view.physicalSize = const Size(1000, 700);
    await tester.pumpAndSettle();
    expect(find.byType(_AnonEditorPage), findsOneWidget);
    expect(detailSlotWidth(tester), greaterThanOrEqualTo(360));
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('detail-editor')))
          .controller!
          .text,
      '右栏草稿',
    );

    // 退出右栏栈后不占位
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(_AnonEditorPage), findsNothing);
    expect(detailSlotWidth(tester), 0);
  });

  testWidgets('右栏 BookInfo 阅读按钮固定 root（视频书分支）', (tester) async {
    const videoBook = Book(
      bookUrl: 'v1',
      name: '视频书',
      author: '作者',
      bookType: BookType.video,
    );
    when(() => api.getBooks()).thenAnswer((_) async => const [videoBook]);

    SharedPreferences.setMockInitialValues({});
    setWindowSize(tester, const Size(900, 700));
    final rootKey = GlobalKey<NavigatorState>();
    final rootObserver = _DepthObserver();
    final nestedKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          navigatorKey: rootKey,
          navigatorObservers: [rootObserver],
          onGenerateRoute: (settings) {
            if (settings.name == AppRoutes.video) {
              return MaterialPageRoute<void>(
                settings: settings,
                builder: (_) => const _StubPage('video-root'),
              );
            }
            return _stubRoute(settings);
          },
          home: Navigator(
            key: nestedKey,
            onGenerateRoute: (settings) => MaterialPageRoute<void>(
              settings: settings,
              builder: (_) => const BookInfoScreen(book: videoBook),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(BookInfoScreen), findsOneWidget);
    expect(rootObserver.depth, 1);
    expect(nestedKey.currentState!.canPop(), isFalse);

    await tester.tap(find.widgetWithText(FloatingActionButton, '阅读'));
    await tester.pumpAndSettle();

    // 视频页压到 root：nested 栈不变（BookInfo 仍在这一层下方）
    expect(find.text('video-root'), findsOneWidget);
    expect(rootObserver.depth, 2);
    expect(nestedKey.currentState!.canPop(), isFalse);

    rootKey.currentState!.pop();
    await tester.pumpAndSettle();
    expect(find.text('video-root'), findsNothing);
    expect(find.byType(BookInfoScreen), findsOneWidget);
    expect(rootObserver.depth, 1);
  });

  testWidgets('宽屏 RSS：源 → 文章列表 → 文章详情都在右栏，左源列表保留', (tester) async {
    const source = RssSource(sourceUrl: 'https://s.test', sourceName: '测试源');
    when(() => api.getRssSources()).thenAnswer((_) async => const [source]);
    when(() => api.rssSortUrls(source.sourceUrl)).thenAnswer(
      (_) async => jsonEncode([
        const RssSort(name: '全部', url: 'https://s.test').toJson(),
      ]),
    );
    when(
      () => api.rssListCachedArticles(
        any(),
        sortName: any(named: 'sortName'),
      ),
    ).thenAnswer((_) async => '[]');
    when(
      () => api.rssRefreshArticles(
        any(),
        any(),
        any(),
        key: any(named: 'key'),
      ),
    ).thenAnswer(
      (_) async => jsonEncode({
        'articles': [
          {
            'title': '文章一',
            'link': 'https://s.test/a',
            'type': 0,
            'sort': '全部',
          },
        ],
        'nextUrl': null,
        'hasMore': false,
      }),
    );
    when(
      () => api.rssMarkRead(
        any(),
        any(),
        link: any(named: 'link'),
        type: any(named: 'type'),
        sort: any(named: 'sort'),
        image: any(named: 'image'),
        pubDate: any(named: 'pubDate'),
        durPos: any(named: 'durPos'),
      ),
    ).thenAnswer((_) async {});

    await pumpHome(
      tester,
      mode: MultiPaneMode.always,
      size: const Size(1100, 760),
    );

    // 切到 RSS（索引 3）
    await tester.tap(find.byType(NavigationDestination).at(3));
    await tester.pumpAndSettle();
    expect(find.byType(RssScreen), findsOneWidget);
    expect(find.text('测试源'), findsOneWidget);

    // 打开源 → 文章列表进右栏，左源列表保留
    await tester.tap(find.text('测试源'));
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('main-detail-right')),
        matching: find.byType(RssArticlesScreen),
      ),
      findsOneWidget,
    );
    expect(find.byType(RssScreen), findsOneWidget);
    expect(detailSlotWidth(tester), greaterThanOrEqualTo(360));

    // 点文章 → 文章详情压在右栏栈顶（列表仍在栈下方）
    await tester.tap(find.text('文章一'));
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('main-detail-right')),
        matching: find.byType(RssArticleDetailScreen),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('main-detail-right')),
        matching: find.byType(RssArticlesScreen),
      ),
      findsNothing,
    );

    // 返回一次回文章列表（右栏逐级 pop），再返回清空右栏
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(RssArticleDetailScreen), findsNothing);
    expect(find.byType(RssArticlesScreen), findsOneWidget);
    expect(detailSlotWidth(tester), greaterThanOrEqualTo(360));

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(RssArticlesScreen), findsNothing);
    expect(detailSlotWidth(tester), 0);
    expect(find.byType(RssScreen), findsOneWidget);
    expect(
      tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex,
      3,
    );
  });

  testWidgets('宽屏发现（源内容模式）点书：右栏 BookInfo，左书单保留', (tester) async {
    const exploreSource = BookSource(
      bookSourceUrl: 'https://e.test',
      bookSourceName: '发现源',
      exploreUrl: 'https://e.test/explore',
    );
    when(() => api.getBookSources()).thenAnswer(
      (_) async => const [exploreSource],
    );
    when(
      () => api.exploreParseUrl(any(), sourceJson: any(named: 'sourceJson')),
    ).thenAnswer(
      (_) async => const [
        ExploreCategory(title: '推荐', url: 'https://e.test/list'),
      ],
    );
    when(() => api.exploreFetchBooks(any(), any(), any())).thenAnswer(
      (_) async => const [
        SearchBook(
          bookUrl: 'https://e.test/book/1',
          name: '发现书',
          author: '发现作者',
        ),
      ],
    );

    await pumpHome(
      tester,
      mode: MultiPaneMode.always,
      size: const Size(1100, 760),
      extraPrefs: {
        // 源内容模式（参考版 ExploreMainRoute.showContent 分支）
        exploreMainContentKey: true,
        exploreMainSourceUrlKey: 'https://e.test',
      },
    );

    // 切到发现（索引 2）：源内容模式直接展示书单
    await tester.tap(find.byType(NavigationDestination).at(2));
    await tester.pumpAndSettle();
    expect(find.text('发现书'), findsOneWidget);
    expect(detailSlotWidth(tester), 0);

    await tester.tap(find.text('发现书'));
    await tester.pumpAndSettle();

    expect(
      find.descendant(
        of: find.byKey(const ValueKey('main-detail-right')),
        matching: find.byType(BookInfoScreen),
      ),
      findsOneWidget,
    );
    // 左书单仍可见（发现内容未被右栏替换）
    expect(
      find.descendant(
        of: find.byType(ExploreSourceContent),
        matching: find.text('发现书'),
      ),
      findsOneWidget,
    );
    expect(detailSlotWidth(tester), greaterThanOrEqualTo(360));

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(BookInfoScreen), findsNothing);
    expect(find.text('发现书'), findsOneWidget);
    expect(detailSlotWidth(tester), 0);
    expect(
      tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex,
      2,
    );
  });

  testWidgets('最小双栏宽度 + 2x 字体：右栏 360dp 不溢出', (tester) async {
    await pumpHome(
      tester,
      mode: MultiPaneMode.always,
      size: const Size(744, 700),
      textScale: 2,
    );

    await tapShelfBook(tester);

    expect(find.byType(BookInfoScreen), findsOneWidget);
    expect(detailSlotWidth(tester), 360);
    expect(tester.takeException(), isNull);
  });

  testWidgets('右栏显隐不重建 PageView / 书架 State', (tester) async {
    await pumpHome(
      tester,
      mode: MultiPaneMode.always,
      size: const Size(1000, 700),
    );

    final shelfState = tester.state(find.byType(BookshelfScreen));
    final pageViewState = tester.state(find.byType(PageView));

    await tapShelfBook(tester);
    expect(find.byType(BookInfoScreen), findsOneWidget);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();

    expect(tester.state(find.byType(BookshelfScreen)), same(shelfState));
    expect(tester.state(find.byType(PageView)), same(pageViewState));
    expect(tester.widget<PageView>(find.byType(PageView)).controller!.page, 1);
  });
}
