// [设置批2b-2b P1-3] 「我的」容器内阅读记录/离线缓存打开书籍与搜索的
// 根导航回归：
// - 双栏（nested 右栏）与单栏（root 页面）下，openBook/search 都必须落
//   根栈（PlatformBridgeService.navigatorKey），不能关进容器 nested 栈；
// - 容器栈深度保持不变。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/constants/pref_keys.dart';
import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/routes.dart';
import 'package:flutter_legado/src/screens/offline_cache_screen.dart';
import 'package:flutter_legado/src/screens/read_record_screen.dart';
import 'package:flutter_legado/src/services/platform_bridge_service.dart';
import 'package:flutter_legado/src/utils/multi_pane_layout.dart';
import 'package:flutter_legado/src/widgets/navigation/adaptive_my_pane.dart';

import '../mocks/mocks.dart';

class _StubPage extends StatelessWidget {
  const _StubPage(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    return Scaffold(body: Center(child: Text(label)));
  }
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

/// 容器内外共用：目标页 + 根栈标记页
Route<dynamic> _routeFor(RouteSettings settings) {
  final Widget child = switch (settings.name) {
    AppRoutes.readRecord => const ReadRecordScreen(),
    AppRoutes.offlineCache => const OfflineCacheScreen(),
    AppRoutes.bookInfo => const _StubPage('root:/book_info'),
    AppRoutes.search => const _StubPage('root:/search'),
    _ => _StubPage('root:${settings.name}'),
  };
  return MaterialPageRoute<void>(settings: settings, builder: (_) => child);
}

void main() {
  setUpAll(registerFallbacks);

  late MockRustApi api;
  late ProviderContainer container;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    api = MockRustApi();
    when(() => api.getConfig(any())).thenAnswer((_) async => null);
    when(() => api.getServerStatus()).thenAnswer((_) async => 'stopped');
    when(() => api.getBookGroups()).thenAnswer((_) async => []);
    when(() => api.getBookSources()).thenAnswer((_) async => []);
    when(() => api.getRssSources()).thenAnswer((_) async => []);
    when(() => api.readRecordDailyList(any())).thenAnswer((_) async => []);
    when(() => api.getBooks()).thenAnswer((_) async => []);
    when(() => api.getReadRecords()).thenAnswer((_) async => []);
    when(() => api.cacheDownloadList()).thenAnswer((_) async => '[]');
    when(
      () => api.listCachedChapterUrls(any()),
    ).thenAnswer((_) async => const <String>[]);
    container = ProviderContainer(
      overrides: [bookApiProvider.overrideWithValue(api)],
    );
    addTearDown(container.dispose);
  });

  void setWindowSize(WidgetTester tester, Size size) {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
  }

  Future<GlobalKey<NavigatorState>> pumpMyPane(
    WidgetTester tester, {
    required MultiPaneMode mode,
    required _DepthObserver rootObserver,
  }) async {
    SharedPreferences.setMockInitialValues({PrefKeys.multiPaneMode: mode.name});
    setWindowSize(tester, const Size(900, 700));
    final nestedKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          // openBook(useGlobalNavigator: true) 经该 key 落根栈
          navigatorKey: PlatformBridgeService.navigatorKey,
          navigatorObservers: [rootObserver],
          onGenerateRoute: _routeFor,
          home: Scaffold(
            body: AdaptiveMyPane(
              navigatorKey: nestedKey,
              routeGenerator: _routeFor,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return nestedKey;
  }

  Future<void> openMenuEntry(WidgetTester tester, String label) async {
    await tester.dragUntilVisible(
      find.text(label),
      find.byType(ListView),
      const Offset(0, -120),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text(label));
    await tester.pumpAndSettle();
  }

  Future<void> tapRecord(WidgetTester tester, String label) async {
    final list = find.descendant(
      of: find.byType(ReadRecordScreen),
      matching: find.byType(ListView),
    );
    await tester.dragUntilVisible(
      find.text(label),
      list,
      const Offset(0, -120),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text(label));
    await tester.pumpAndSettle();
  }

  testWidgets('双栏容器：阅读记录 openBook 落根栈，容器栈不变', (tester) async {
    when(() => api.getReadRecords()).thenAnswer(
      (_) async => [
        const ReadRecord(bookName: '物理书名A', displayBookName: '显示A'),
      ],
    );
    when(
      () => api.getBooks(),
    ).thenAnswer((_) async => [const Book(bookUrl: 'u1', name: '物理书名A')]);
    final rootObserver = _DepthObserver();
    final nestedKey = await pumpMyPane(
      tester,
      mode: MultiPaneMode.always,
      rootObserver: rootObserver,
    );
    final paneState = tester.state<AdaptiveMyPaneState>(
      find.byType(AdaptiveMyPane),
    );
    final baseline = rootObserver.depth;
    expect(baseline, 1);

    await openMenuEntry(tester, '阅读记录');
    expect(find.byType(ReadRecordScreen), findsOneWidget);
    expect(nestedKey.currentState!.canPop(), isTrue);
    expect(paneState.rightStackDepth, 2);

    await tapRecord(tester, '显示A');

    // 根栈 +1（book_info）；容器 nested 栈仍停在同一页
    expect(find.text('root:/book_info'), findsOneWidget);
    expect(rootObserver.depth, baseline + 1);
    expect(nestedKey.currentState!.canPop(), isTrue);
    expect(paneState.rightStackDepth, 2);
  });

  testWidgets('单栏容器：阅读记录无书搜索落根栈，容器栈不变', (tester) async {
    when(() => api.getReadRecords()).thenAnswer(
      (_) async => [
        const ReadRecord(bookName: '物理书名A', displayBookName: '显示A'),
      ],
    );
    // getBooks 默认空 → 书架无书，走搜索分支
    final rootObserver = _DepthObserver();
    final nestedKey = await pumpMyPane(
      tester,
      mode: MultiPaneMode.off,
      rootObserver: rootObserver,
    );
    final paneState = tester.state<AdaptiveMyPaneState>(
      find.byType(AdaptiveMyPane),
    );
    final baseline = rootObserver.depth;

    // 单栏命名入口 root push 阅读记录（+1）
    await openMenuEntry(tester, '阅读记录');
    expect(find.byType(ReadRecordScreen), findsOneWidget);
    expect(rootObserver.depth, baseline + 1);

    await tapRecord(tester, '显示A');

    // 搜索再 +1，落根栈；容器 nested 栈保持初始空态
    expect(find.text('root:/search'), findsOneWidget);
    expect(rootObserver.depth, baseline + 2);
    expect(nestedKey.currentState!.canPop(), isFalse);
    expect(paneState.rightStackDepth, 1);
  });

  testWidgets('双栏容器：缓存管理 openBook 落根栈，容器栈不变', (tester) async {
    when(() => api.getBooks()).thenAnswer(
      (_) async => [
        const Book(
          bookUrl: 'u1',
          name: '缓存书A',
          author: '作者A',
          totalChapterNum: 10,
        ),
      ],
    );
    final rootObserver = _DepthObserver();
    final nestedKey = await pumpMyPane(
      tester,
      mode: MultiPaneMode.always,
      rootObserver: rootObserver,
    );
    final paneState = tester.state<AdaptiveMyPaneState>(
      find.byType(AdaptiveMyPane),
    );
    final baseline = rootObserver.depth;

    await openMenuEntry(tester, '缓存管理');
    expect(find.byType(OfflineCacheScreen), findsOneWidget);
    expect(paneState.rightStackDepth, 2);

    await tester.tap(find.text('缓存书A'));
    await tester.pumpAndSettle();

    expect(find.text('root:/book_info'), findsOneWidget);
    expect(rootObserver.depth, baseline + 1);
    expect(nestedKey.currentState!.canPop(), isTrue);
    expect(paneState.rightStackDepth, 2);
  });

  testWidgets('单栏容器：缓存管理 openBook 落根栈，容器栈不变', (tester) async {
    when(() => api.getBooks()).thenAnswer(
      (_) async => [
        const Book(
          bookUrl: 'u1',
          name: '缓存书A',
          author: '作者A',
          totalChapterNum: 10,
        ),
      ],
    );
    final rootObserver = _DepthObserver();
    final nestedKey = await pumpMyPane(
      tester,
      mode: MultiPaneMode.off,
      rootObserver: rootObserver,
    );
    final paneState = tester.state<AdaptiveMyPaneState>(
      find.byType(AdaptiveMyPane),
    );
    final baseline = rootObserver.depth;

    await openMenuEntry(tester, '缓存管理');
    expect(find.byType(OfflineCacheScreen), findsOneWidget);
    expect(rootObserver.depth, baseline + 1);

    await tester.tap(find.text('缓存书A'));
    await tester.pumpAndSettle();

    expect(find.text('root:/book_info'), findsOneWidget);
    expect(rootObserver.depth, baseline + 2);
    expect(nestedKey.currentState!.canPop(), isFalse);
    expect(paneState.rightStackDepth, 1);
  });

  testWidgets('双栏容器：阅读记录搜索落根栈，容器栈不变', (tester) async {
    when(() => api.getReadRecords()).thenAnswer(
      (_) async => [
        const ReadRecord(bookName: '物理书名A', displayBookName: '显示A'),
      ],
    );
    final rootObserver = _DepthObserver();
    final nestedKey = await pumpMyPane(
      tester,
      mode: MultiPaneMode.always,
      rootObserver: rootObserver,
    );
    final paneState = tester.state<AdaptiveMyPaneState>(
      find.byType(AdaptiveMyPane),
    );
    final baseline = rootObserver.depth;

    await openMenuEntry(tester, '阅读记录');
    await tapRecord(tester, '显示A');

    expect(find.text('root:/search'), findsOneWidget);
    expect(rootObserver.depth, baseline + 1);
    expect(nestedKey.currentState!.canPop(), isTrue);
    expect(paneState.rightStackDepth, 2);
  });

  testWidgets('单栏容器：openBook（已入书架）落根栈，容器栈不变', (tester) async {
    when(() => api.getReadRecords()).thenAnswer(
      (_) async => [
        const ReadRecord(bookName: '物理书名A', displayBookName: '显示A'),
      ],
    );
    when(
      () => api.getBooks(),
    ).thenAnswer((_) async => [const Book(bookUrl: 'u1', name: '物理书名A')]);
    final rootObserver = _DepthObserver();
    final nestedKey = await pumpMyPane(
      tester,
      mode: MultiPaneMode.off,
      rootObserver: rootObserver,
    );
    final paneState = tester.state<AdaptiveMyPaneState>(
      find.byType(AdaptiveMyPane),
    );
    final baseline = rootObserver.depth;

    await openMenuEntry(tester, '阅读记录');
    await tapRecord(tester, '显示A');

    expect(find.text('root:/book_info'), findsOneWidget);
    expect(rootObserver.depth, baseline + 2);
    expect(nestedKey.currentState!.canPop(), isFalse);
    expect(paneState.rightStackDepth, 1);
  });
}
