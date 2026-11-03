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
// [2b-2c 复核] 补充：窄窗口 enabled=false root、书架长按、A→B 替换栈、
// 重复点同书、已读 standalone 前清栈、RSS 视频/搜索/登录 root、My 互斥、
// 隐藏栈返回、half-swipe 不清栈、真实 BookInfo 隐藏不溢出、来源守卫。
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';
// ignore: depend_on_referenced_packages
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

import 'package:flutter_legado/src/constants/pref_keys.dart';
import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/providers/explore/explore_main_state.dart';
import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/providers/rss/rss_notifier.dart';
import 'package:flutter_legado/src/routes.dart';
import 'package:flutter_legado/src/screens/book_info_screen.dart';
import 'package:flutter_legado/src/screens/bookshelf_screen.dart';
import 'package:flutter_legado/src/screens/explore_screen.dart';
import 'package:flutter_legado/src/screens/home_screen.dart';
import 'package:flutter_legado/src/screens/rss_article_detail_screen.dart';
import 'package:flutter_legado/src/screens/rss_articles_screen.dart';
import 'package:flutter_legado/src/screens/rss_screen.dart';
import 'package:flutter_legado/src/screens/search_screen.dart';
import 'package:flutter_legado/src/screens/settings_screen.dart';
import 'package:flutter_legado/src/screens/source_login_screen.dart';
import 'package:flutter_legado/src/screens/video_screen.dart';
import 'package:flutter_legado/src/services/video_float_window.dart';
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

/// 右栏长列表页：验证左右滚动独立（各自 controller/position）
class _DetailListPage extends StatelessWidget {
  const _DetailListPage();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: ListView.builder(
        key: const ValueKey('detail-long-list'),
        itemCount: 50,
        itemBuilder: (_, index) =>
            SizedBox(height: 48, child: Text('右栏行$index')),
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

/// 详情栏桩路由：book_info 返回长列表页（滚动独立用例）
Route<dynamic> _stubDetailListRoute(RouteSettings settings) {
  if (settings.name == AppRoutes.bookInfo) {
    return MaterialPageRoute<void>(
      settings: settings,
      builder: (_) => const _DetailListPage(),
    );
  }
  return _stubRoute(settings);
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

/// 最小 Fake 视频平台：创建即投递 initialized，避免真实插件依赖。
class _FakeVideoPlayerPlatform extends VideoPlayerPlatform {
  final Map<int, StreamController<VideoEvent>> _events = {};
  int _nextId = 1;

  @override
  Future<void> init() async {}

  @override
  Future<void> setMixWithOthers(bool mixWithOthers) async {}

  @override
  Future<int?> createWithOptions(VideoCreationOptions options) async {
    final id = _nextId++;
    final controller = StreamController<VideoEvent>();
    _events[id] = controller;
    controller.add(
      VideoEvent(
        eventType: VideoEventType.initialized,
        duration: const Duration(seconds: 60),
        size: const Size(16, 9),
      ),
    );
    return id;
  }

  @override
  Stream<VideoEvent> videoEventsFor(int playerId) =>
      _events[playerId]?.stream ?? const Stream<VideoEvent>.empty();

  @override
  Future<void> dispose(int playerId) async {
    await _events.remove(playerId)?.close();
  }

  @override
  Future<void> setLooping(int playerId, bool looping) async {}

  @override
  Future<void> play(int playerId) async {}

  @override
  Future<void> pause(int playerId) async {}

  @override
  Future<void> setVolume(int playerId, double volume) async {}

  @override
  Future<void> seekTo(int playerId, Duration position) async {}

  @override
  Future<void> setPlaybackSpeed(int playerId, double speed) async {}

  @override
  Future<Duration> getPosition(int playerId) async => Duration.zero;

  @override
  Widget buildView(int playerId) => const ColoredBox(color: Color(0xFF000000));
}

/// 假悬浮窗桥：测试环境无平台通道应答，显式返回「无活动悬浮窗」。
class _FakeFloatBridge extends VideoFloatWindowBridge {
  _FakeFloatBridge() {
    supportedOverride = false;
  }

  @override
  Future<VideoFloatWindowState?> getState() async => null;
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
    when(() => api.setConfig(any(), any())).thenAnswer((_) async {});
    when(() => api.deleteConfig(any())).thenAnswer((_) async {});
    when(() => api.getSearchHistory()).thenAnswer(
      (_) async => const <SearchKeyword>[],
    );
    when(() => api.addSearchKeyword(any(), any())).thenAnswer((_) async {});
    when(() => api.cancelSearch()).thenAnswer((_) async {});
    when(
      () => api.getVideoDanmaku(
        bookUrl: any(named: 'bookUrl'),
        chapterIndex: any(named: 'chapterIndex'),
      ),
    ).thenAnswer((_) async => null);
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
    // VideoScreen 直链起播使用假平台/悬浮窗桥（真实插件在测试宿主不可用）
    VideoPlayerPlatform.instance = _FakeVideoPlayerPlatform();
    final floatBridge = _FakeFloatBridge();
    VideoFloatWindowBridge.instance = floatBridge;
    VideoFloatWindowCoordinator.instance = VideoFloatWindowCoordinator(
      bridge: floatBridge,
    );
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

  /// 右栏内匹配
  Finder inRightPane(Finder matching) {
    return find.descendant(
      of: find.byKey(const ValueKey('main-detail-right')),
      matching: matching,
    );
  }

  /// 右栏当前 BookInfo 的书籍名（用于替换栈断言）
  String? rightBookName(WidgetTester tester) {
    final finder = inRightPane(find.byType(BookInfoScreen));
    if (finder.evaluate().isEmpty) return null;
    return tester.widget<BookInfoScreen>(finder).book?.name;
  }

  /// RSS 源/分类/文章列表桩（避免真实 FFI）
  void stubRssSource(
    String sourceUrl, {
    List<Map<String, dynamic>> articles = const [],
  }) {
    when(() => api.rssSortUrls(sourceUrl)).thenAnswer(
      (_) async => jsonEncode([
        {'name': '全部', 'url': sourceUrl},
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
        'articles': articles,
        'nextUrl': null,
        'hasMore': false,
      }),
    );
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

  testWidgets('宽屏发现「源列表+分类书单」双栏点书：左发现无 ErrorWidget', (tester) async {
    const source = BookSource(
      bookSourceUrl: 'https://e.test',
      bookSourceName: '发现源',
      exploreUrl: 'https://e.test/explore',
    );
    when(() => api.getBookSources()).thenAnswer((_) async => const [source]);
    when(
      () => api.exploreParseUrl(any(), sourceJson: any(named: 'sourceJson')),
    ).thenAnswer(
      (_) async => const [
        ExploreCategory(title: '推荐', url: 'https://e.test/list'),
      ],
    );
    when(() => api.exploreFetchBooks(any(), any(), any())).thenAnswer(
      (_) async => [
        for (var i = 0; i < 20; i++)
          SearchBook(
            bookUrl: 'https://e.test/book/$i',
            name: '书$i',
            author: '作者$i',
          ),
      ],
    );

    await pumpHome(
      tester,
      mode: MultiPaneMode.always,
      size: const Size(1200, 800),
    );

    // 发现 Tab，展开源并选择分类 → 内部双栏（左源列表 + 右书单）
    await tester.tap(find.byType(NavigationDestination).at(2));
    await tester.pumpAndSettle();
    await tester.tap(find.text('发现源'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('推荐'));
    await tester.pumpAndSettle();
    expect(find.text('书0'), findsOneWidget);

    // 点书：主右栏打开 BookInfo，发现页宽度跌破 840 → 内部双栏收成源列表
    await tester.tap(find.text('书0'));
    await tester.pumpAndSettle();

    expect(inRightPane(find.byType(BookInfoScreen)), findsOneWidget);
    expect(find.byType(ExploreScreen), findsOneWidget);
    expect(find.byType(ErrorWidget), findsNothing);
    expect(tester.takeException(), isNull);
    expect(detailSlotWidth(tester), greaterThanOrEqualTo(360));

    // 左发现仍可交互（源列表行仍在）
    expect(find.text('发现源'), findsOneWidget);
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

  testWidgets('左右滚动独立：右栏长列表滚动不影响左书架', (tester) async {
    when(() => api.getBooks()).thenAnswer(
      (_) async => [
        for (var i = 0; i < 20; i++)
          Book(bookUrl: 'b$i', name: '书$i', author: '作者'),
      ],
    );

    await pumpHome(
      tester,
      mode: MultiPaneMode.always,
      size: const Size(1000, 700),
      detailRouteGenerator: _stubDetailListRoute,
    );
    await tester.tap(
      find.descendant(
        of: find.byType(BookshelfScreen),
        matching: find.text('书0'),
      ),
    );
    await tester.pumpAndSettle();
    expect(inRightPane(find.byType(_DetailListPage)), findsOneWidget);

    ScrollPosition verticalPosition(Finder scope) {
      return tester
          .stateList<ScrollableState>(
            find.descendant(of: scope, matching: find.byType(Scrollable)),
          )
          .map((s) => s.position)
          .firstWhere(
            (p) =>
                p.axis == Axis.vertical &&
                p.hasContentDimensions &&
                p.maxScrollExtent > 0,
          );
    }

    final left = verticalPosition(find.byType(BookshelfScreen));
    final right = verticalPosition(
      find.byKey(const ValueKey('main-detail-right')),
    );

    left.jumpTo(left.maxScrollExtent >= 150 ? 150 : left.maxScrollExtent);
    await tester.pumpAndSettle();
    final leftAfter = left.pixels;
    expect(leftAfter, greaterThan(0));
    expect(right.pixels, 0);

    await tester.drag(
      find.byKey(const ValueKey('detail-long-list')),
      const Offset(0, -200),
    );
    await tester.pumpAndSettle();
    expect(right.pixels, greaterThan(0));
    expect(left.pixels, leftAfter);

    right.jumpTo(right.maxScrollExtent >= 300 ? 300 : right.maxScrollExtent);
    await tester.pumpAndSettle();
    expect(left.pixels, leftAfter);
    expect(tester.takeException(), isNull);
  });

  testWidgets('窄窗口（模式开但宽度不足）：点书 root 全屏', (tester) async {
    await pumpHome(
      tester,
      mode: MultiPaneMode.always,
      size: const Size(700, 700),
    );
    expect(detailSlotWidth(tester), 0);

    await tapShelfBook(tester);
    expect(find.byType(BookInfoScreen), findsOneWidget);
    expect(find.byType(NavigationBar), findsNothing);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(BookshelfScreen), findsOneWidget);
    expect(detailSlotWidth(tester), 0);
  });

  testWidgets('书架长按：右栏 BookInfo（替换栈，不自动开读）', (tester) async {
    await pumpHome(
      tester,
      mode: MultiPaneMode.always,
      size: const Size(1000, 700),
    );

    await tester.longPress(
      find.descendant(
        of: find.byType(BookshelfScreen),
        matching: find.text('测试书'),
      ),
    );
    await tester.pumpAndSettle();

    expect(inRightPane(find.byType(BookInfoScreen)), findsOneWidget);
    expect(detailSlotWidth(tester), greaterThanOrEqualTo(360));
    expect(
      tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex,
      1,
    );
  });

  testWidgets('左列表选择替换右栏栈：A→B 返回回列表，重复点同书不叠栈', (tester) async {
    const bookA = Book(bookUrl: 'a', name: '书A', author: '作者');
    const bookB = Book(bookUrl: 'b', name: '书B', author: '作者');
    when(() => api.getBooks()).thenAnswer((_) async => const [bookA, bookB]);

    await pumpHome(
      tester,
      mode: MultiPaneMode.always,
      size: const Size(1000, 700),
    );

    Finder shelfText(String name) => find.descendant(
      of: find.byType(BookshelfScreen),
      matching: find.text(name),
    );

    await tester.tap(shelfText('书A'));
    await tester.pumpAndSettle();
    expect(rightBookName(tester), '书A');

    // A→B：左列表选择替换，不叠两层
    await tester.tap(shelfText('书B'));
    await tester.pumpAndSettle();
    expect(rightBookName(tester), '书B');

    // 一次返回即回列表（若叠栈会先回到 A）
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(BookInfoScreen), findsNothing);
    expect(detailSlotWidth(tester), 0);

    // 重复点同一本：仍只有一层，一次返回清空
    await tester.tap(shelfText('书A'));
    await tester.pumpAndSettle();
    expect(rightBookName(tester), '书A');
    await tester.tap(shelfText('书A'));
    await tester.pumpAndSettle();
    expect(rightBookName(tester), '书A');
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(BookInfoScreen), findsNothing);
    expect(detailSlotWidth(tester), 0);
  });

  testWidgets('右栏 BookInfo A → 已读书 B 阅读器 root → 关闭后右栏为空', (
    tester,
  ) async {
    const bookA = Book(bookUrl: 'a', name: '书A', author: '作者');
    const bookB = Book(
      bookUrl: 'b',
      name: '书B',
      author: '作者',
      durChapterIndex: 1,
    );
    when(() => api.getBooks()).thenAnswer((_) async => const [bookA, bookB]);

    Route<dynamic> rootRoute(RouteSettings settings) {
      if (settings.name == AppRoutes.reader) {
        return MaterialPageRoute<void>(
          settings: settings,
          builder: (_) => const _StubPage('reader-root'),
        );
      }
      return AppRoutes.generateRoute(settings);
    }

    await pumpHome(
      tester,
      mode: MultiPaneMode.always,
      size: const Size(1000, 700),
      rootRouteGenerator: rootRoute,
    );

    Finder shelfText(String name) => find.descendant(
      of: find.byType(BookshelfScreen),
      matching: find.text(name),
    );

    await tester.tap(shelfText('书A'));
    await tester.pumpAndSettle();
    expect(rightBookName(tester), '书A');

    // 已读书 B 直读阅读器 standalone：root 全屏，先清旧右栏
    await tester.tap(shelfText('书B'));
    await tester.pumpAndSettle();
    expect(find.text('reader-root'), findsOneWidget);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('reader-root'), findsNothing);
    expect(find.byType(BookInfoScreen), findsNothing);
    expect(detailSlotWidth(tester), 0);
    expect(find.byType(BookshelfScreen), findsOneWidget);
  });

  testWidgets('宽→窄隐藏右栏栈后，返回不走隐藏栈而走原 Tab 逻辑', (tester) async {
    const source = RssSource(sourceUrl: 'https://s.test', sourceName: '测试源');
    when(() => api.getRssSources()).thenAnswer((_) async => const [source]);
    stubRssSource(source.sourceUrl);

    await pumpHome(
      tester,
      mode: MultiPaneMode.always,
      size: const Size(1100, 760),
    );

    await tester.tap(find.byType(NavigationDestination).at(3));
    await tester.pumpAndSettle();
    await tester.tap(find.text('测试源'));
    await tester.pumpAndSettle();
    expect(inRightPane(find.byType(RssArticlesScreen)), findsOneWidget);

    // 缩到单栏：右栏隐藏但栈保留
    tester.view.physicalSize = const Size(700, 700);
    await tester.pumpAndSettle();
    expect(detailSlotWidth(tester), 0);
    expect(inRightPane(find.byType(RssArticlesScreen)), findsNothing);

    // 返回：隐藏栈不消费 → 原逻辑切回书架
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(
      tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex,
      1,
    );

    // 回 RSS 并变宽：切 Tab 已清栈，不再恢复文章列表
    await tester.tap(find.byType(NavigationDestination).at(3));
    await tester.pumpAndSettle();
    tester.view.physicalSize = const Size(1100, 760);
    await tester.pumpAndSettle();
    expect(inRightPane(find.byType(RssArticlesScreen)), findsNothing);
    expect(detailSlotWidth(tester), 0);
    expect(find.byType(RssScreen), findsOneWidget);
  });

  testWidgets('RSS 视频文章：播放页固定 root，返回仍在右栏文章列表', (tester) async {
    const source = RssSource(sourceUrl: 'https://s.test', sourceName: '视频源');
    when(() => api.getRssSources()).thenAnswer((_) async => const [source]);
    stubRssSource(
      source.sourceUrl,
      articles: [
        {
          'title': '视频文章',
          'link': 'https://s.test/v.m3u8',
          'type': 2,
          'sort': '全部',
        },
      ],
    );

    await pumpHome(
      tester,
      mode: MultiPaneMode.always,
      size: const Size(1100, 760),
    );

    await tester.tap(find.byType(NavigationDestination).at(3));
    await tester.pumpAndSettle();
    await tester.tap(find.text('视频源'));
    await tester.pumpAndSettle();
    expect(inRightPane(find.byType(RssArticlesScreen)), findsOneWidget);

    await tester.tap(find.text('视频文章'));
    await tester.pumpAndSettle();
    expect(find.byType(VideoScreen), findsOneWidget);
    // root 全屏覆盖：底栏不可见
    expect(find.byType(NavigationBar), findsNothing);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(VideoScreen), findsNothing);
    expect(inRightPane(find.byType(RssArticlesScreen)), findsOneWidget);
    expect(detailSlotWidth(tester), greaterThanOrEqualTo(360));
  });

  testWidgets('RSS searchBook 桥：搜索固定 root 全屏', (tester) async {
    final rootKey = GlobalKey<NavigatorState>();
    final rootObserver = _DepthObserver();
    final nestedKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          navigatorKey: rootKey,
          navigatorObservers: [rootObserver],
          onGenerateRoute: _stubRoute,
          home: Navigator(
            key: nestedKey,
            onGenerateRoute: (_) => MaterialPageRoute<void>(
              builder: (_) => Scaffold(
                body: Builder(
                  builder: (context) => Center(
                    child: ElevatedButton(
                      key: const ValueKey('open-rss-search'),
                      onPressed: () => openRssArticleSearch(context, '关键词'),
                      child: const Text('open-search'),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(rootObserver.depth, 1);

    await tester.tap(find.byKey(const ValueKey('open-rss-search')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.byType(SearchScreen), findsOneWidget);
    expect(rootObserver.depth, 2);
    expect(nestedKey.currentState!.canPop(), isFalse);
  });

  testWidgets('右栏内 RSS 登录固定 root 全屏', (tester) async {
    const source = RssSource(
      sourceUrl: 'https://s.test',
      sourceName: '登录源',
      loginUrl: 'https://s.test/login',
    );
    when(() => api.getRssSources()).thenAnswer((_) async => const [source]);
    stubRssSource(source.sourceUrl);

    final rootKey = GlobalKey<NavigatorState>();
    final rootObserver = _DepthObserver();
    final nestedKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          navigatorKey: rootKey,
          navigatorObservers: [rootObserver],
          onGenerateRoute: _stubRoute,
          home: Navigator(
            key: nestedKey,
            onGenerateRoute: (_) => MaterialPageRoute<void>(
              builder: (_) => const RssArticlesScreen(source: source),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(rootObserver.depth, 1);

    await tester.tap(find.byTooltip('更多'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('登录'));
    await tester.pumpAndSettle();

    expect(find.byType(SourceLoginScreen), findsOneWidget);
    expect(rootObserver.depth, 2);
    expect(nestedKey.currentState!.canPop(), isFalse);
  });

  testWidgets('My 与列表-详情互斥：切到我的清空右栏并显示双栏菜单', (tester) async {
    await pumpHome(
      tester,
      mode: MultiPaneMode.always,
      size: const Size(1000, 700),
    );
    await tapShelfBook(tester);
    expect(inRightPane(find.byType(BookInfoScreen)), findsOneWidget);

    await tester.tap(find.byType(NavigationDestination).at(4));
    await tester.pumpAndSettle();

    expect(find.byType(BookInfoScreen), findsNothing);
    expect(detailSlotWidth(tester), 0);
    expect(find.byType(SettingsScreen), findsOneWidget);
    expect(find.text('选择左侧项目'), findsOneWidget);
  });

  testWidgets('真实 BookInfo 缩窄到隐藏（0 宽）无溢出，恢复后仍在', (tester) async {
    await pumpHome(
      tester,
      mode: MultiPaneMode.always,
      size: const Size(1000, 700),
    );
    await tapShelfBook(tester);
    expect(find.byType(BookInfoScreen), findsOneWidget);

    tester.view.physicalSize = const Size(700, 700);
    await tester.pumpAndSettle();
    expect(find.byType(BookInfoScreen), findsNothing);
    expect(tester.takeException(), isNull);

    tester.view.physicalSize = const Size(1000, 700);
    await tester.pumpAndSettle();
    expect(find.byType(BookInfoScreen), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('右栏隐藏期间 BookInfo 不自动开读（校验右栏可见）', (tester) async {
    const autoBook = Book(
      bookUrl: 'v1',
      name: '自动书',
      author: '作者',
      bookType: BookType.video,
    );
    when(() => api.getBooks()).thenAnswer((_) async => const [autoBook]);
    final chaptersCompleter = Completer<List<BookChapter>>();
    when(() => api.getChapters('v1')).thenAnswer((_) => chaptersCompleter.future);

    Route<dynamic> rootRoute(RouteSettings settings) {
      if (settings.name == AppRoutes.video) {
        return MaterialPageRoute<void>(
          settings: settings,
          builder: (_) => const _StubPage('auto-video'),
        );
      }
      return AppRoutes.generateRoute(settings);
    }

    await pumpHome(
      tester,
      mode: MultiPaneMode.always,
      size: const Size(1000, 700),
      rootRouteGenerator: rootRoute,
    );

    await tester.tap(
      find.descendant(
        of: find.byType(BookshelfScreen),
        matching: find.text('自动书'),
      ),
    );
    await tester.pump();

    // 目录仍在加载时缩窄：右栏隐藏（栈保留）
    tester.view.physicalSize = const Size(700, 700);
    await tester.pump();
    expect(detailSlotWidth(tester), 0);

    chaptersCompleter.complete(const [BookChapter(title: '第1章')]);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pumpAndSettle();

    // 隐藏期间不得自动开读
    expect(find.text('auto-video'), findsNothing);

    // 恢复宽屏：BookInfo 可见，自动开读机会已消费（不补开）
    tester.view.physicalSize = const Size(1000, 700);
    await tester.pumpAndSettle();
    expect(inRightPane(find.byType(BookInfoScreen)), findsOneWidget);
    expect(find.text('auto-video'), findsNothing);
  });

  testWidgets('PageView 半程横滑折返不清右栏栈', (tester) async {
    await pumpHome(
      tester,
      mode: MultiPaneMode.always,
      size: const Size(1000, 700),
      detailRouteGenerator: _stubDetailRoute,
    );
    await tapShelfBook(tester);
    expect(find.byType(_AnonEditorPage), findsOneWidget);

    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(PageView)),
    );
    await gesture.moveBy(const Offset(-600, 0));
    await tester.pump();
    await gesture.moveBy(const Offset(600, 0));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();

    expect(find.byType(_AnonEditorPage), findsOneWidget);
    expect(detailSlotWidth(tester), greaterThanOrEqualTo(360));
    expect(
      tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex,
      1,
    );
  });

  testWidgets('来源守卫：RSS singleUrl 异步解析期间切 Tab 则丢弃打开', (tester) async {
    const source = RssSource(
      sourceUrl: 'https://single.test',
      sourceName: '单URL源',
      singleUrl: true,
    );
    when(() => api.getRssSources()).thenAnswer((_) async => const [source]);
    final sortCompleter = Completer<String>();
    when(() => api.rssSortUrls(source.sourceUrl)).thenAnswer(
      (_) => sortCompleter.future,
    );

    await pumpHome(
      tester,
      mode: MultiPaneMode.always,
      size: const Size(1100, 760),
    );
    await tester.tap(find.byType(NavigationDestination).at(3));
    await tester.pumpAndSettle();
    expect(find.text('单URL源'), findsOneWidget);

    await tester.tap(find.text('单URL源'));
    await tester.pump();
    // 解析未完成时切到书架
    await tester.tap(find.byType(NavigationDestination).at(1));
    await tester.pumpAndSettle();

    sortCompleter.complete(
      jsonEncode([
        {'name': '', 'url': 'https://single.test/a'},
      ]),
    );
    await tester.pumpAndSettle();

    // 来源令牌失效：不推浏览器/详情，仍在书架且右栏为空
    expect(find.byType(NavigationBar), findsOneWidget);
    expect(
      tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex,
      1,
    );
    expect(detailSlotWidth(tester), 0);

    await tester.tap(find.byType(NavigationDestination).at(3));
    await tester.pumpAndSettle();
    expect(detailSlotWidth(tester), 0);
    expect(find.byType(RssArticleDetailScreen), findsNothing);
  });
}
