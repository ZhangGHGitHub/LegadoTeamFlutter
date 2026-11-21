// [R42 阶段 1 | 2026-11-21] 书籍详情页「相关书」区块接通回归守卫。
//
// 契约 §2.55：`getRelatedBooks({bookUrl})` 返回 JSON
// `{"modules":[{key,title,url,resolvedUrl,books:[WebSearchResult…]}]}`，
// Rust 侧无配置/全失败/过滤后全空 → `{"modules":[]}`（不抛错）。
// UI 语义（对齐参考版 BookInfoScreen.kt `state.relatedBooks.forEach`）：
// - 每个 module = 标题行 + 横向书列表（封面 + 书名 + 作者）；
// - 空模块列表 → 区块整体不渲染（缺省隐藏，保持既有 `const []` 语义）；
// - 请求/解析异常 → 同样降级为空，不崩、不显示半成品。
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/routes.dart';
import 'package:flutter_legado/src/screens/book_info_screen.dart';
import 'package:flutter_legado/src/theme/app_theme.dart';
import 'package:flutter_legado/src/theme/md3_colors.dart';

import '../mocks/mocks.dart';

/// 记录 push 的路由名与参数（相关书点击跳转断言用）
class _PushedRouteObserver extends NavigatorObserver {
  final List<Route<dynamic>> pushed = [];

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    pushed.add(route);
  }
}

void main() {
  setUpAll(registerFallbacks);

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  Widget themeWrap(Widget child, {NavigatorObserver? observer}) {
    return MaterialApp(
      theme: AppTheme.palette(
        brightness: Brightness.light,
        palette: Md3Palettes.wh,
      ),
      darkTheme: AppTheme.palette(
        brightness: Brightness.dark,
        palette: Md3Palettes.wh,
      ),
      themeMode: ThemeMode.light,
      navigatorObservers: [?observer],
      // 相关书点击走 AppRoutes.bookInfo：补最小路由表避免 unknown route
      onGenerateRoute: (settings) {
        if (settings.name == AppRoutes.bookInfo) {
          final args = settings.arguments;
          return MaterialPageRoute<void>(
            settings: settings,
            builder: (_) => Scaffold(
              body: Text('详情:${args is Book ? args.name : '?'}'),
            ),
          );
        }
        return null;
      },
      home: child,
    );
  }

  /// 在线书（origin 非本地 → 详情页会请求相关书）
  Book makeBook() => const Book(
    bookUrl: 'https://src.com/book/current',
    origin: 'https://src.com',
    originName: '测试书源',
    name: '当前书',
    author: '当前作者',
    tocUrl: 'https://src.com/toc/current',
  );

  Future<MockRustApi> pumpBookInfo(
    WidgetTester tester, {
    required Future<String> Function(String bookUrl) relatedBooks,
    NavigatorObserver? observer,
  }) async {
    tester.view.physicalSize = const Size(1080, 2260);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);
    final book = makeBook();
    final mockApi = MockRustApi();
    when(() => mockApi.getBook(any())).thenAnswer((_) async => book);
    when(() => mockApi.getChapters(any())).thenAnswer(
      (_) async => [
        BookChapter(bookUrl: book.bookUrl, index: 0, title: '第一章'),
      ],
    );
    when(() => mockApi.getBooks()).thenAnswer((_) async => [book]);
    when(() => mockApi.getBookGroups()).thenAnswer((_) async => const []);
    when(() => mockApi.getBookSources()).thenAnswer((_) async => const []);
    when(() => mockApi.getConfig(any())).thenAnswer((_) async => '');
    when(
      () => mockApi.getRelatedBooks(bookUrl: any(named: 'bookUrl')),
    ).thenAnswer((inv) async => relatedBooks(inv.namedArguments[#bookUrl]!));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [bookApiProvider.overrideWithValue(mockApi)],
        child: themeWrap(
          BookInfoScreen(book: book),
          observer: observer,
        ),
      ),
    );
    await tester.pumpAndSettle();
    return mockApi;
  }

  /// 单本书的 WebSearchResult JSON（Rust 侧 snake_case 序列化）
  Map<String, dynamic> bookJson(String name, String author, String url) => {
    'name': name,
    'author': author,
    'book_url': 'https://src.com$url',
    'cover_url': null,
    'source_url': 'https://src.com',
    'type': 0,
  };

  group('相关书区块（契约 §2.55）', () {
    testWidgets('有数据：2 个模块各 2 本书，标题与书名均渲染', (tester) async {
      final payload = jsonEncode({
        'modules': [
          {
            'key': 'similar',
            'title': '相似推荐',
            'url': '/related/similar',
            'resolvedUrl': 'https://src.com/related/similar',
            'books': [
              bookJson('书甲', '作者甲', '/book/a'),
              bookJson('书乙', '作者乙', '/book/b'),
            ],
          },
          {
            'key': 'author',
            'title': '作者其他作品',
            'url': '/related/author',
            'resolvedUrl': 'https://src.com/related/author',
            'books': [
              bookJson('书丙', '作者丙', '/book/c'),
              bookJson('书丁', '作者丁', '/book/d'),
            ],
          },
        ],
      });
      await pumpBookInfo(tester, relatedBooks: (_) async => payload);

      // 模块标题（参考版每模块独立标题，非固定「相关书籍」标签）
      expect(find.text('相似推荐'), findsOneWidget);
      expect(find.text('作者其他作品'), findsOneWidget);
      // 书籍条目：书名 + 作者
      for (final name in ['书甲', '书乙', '书丙', '书丁']) {
        expect(find.text(name), findsOneWidget, reason: '应渲染 $name');
      }
      expect(find.text('作者甲'), findsOneWidget);
      expect(find.text('作者丁'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('点击书籍 → 跳转书籍详情页（携带该书 Book 参数）', (tester) async {
      final payload = jsonEncode({
        'modules': [
          {
            'key': 'similar',
            'title': '相似推荐',
            'url': '/related/similar',
            'resolvedUrl': 'https://src.com/related/similar',
            'books': [bookJson('书甲', '作者甲', '/book/a')],
          },
        ],
      });
      final observer = _PushedRouteObserver();
      await pumpBookInfo(
        tester,
        relatedBooks: (_) async => payload,
        observer: observer,
      );

      await tester.tap(find.text('书甲'));
      await tester.pumpAndSettle();

      final bookInfoRoutes = observer.pushed
          .where((r) => r.settings.name == AppRoutes.bookInfo)
          .toList();
      expect(bookInfoRoutes, hasLength(1), reason: '点击应压入书籍详情路由');
      final args = bookInfoRoutes.single.settings.arguments;
      expect(args, isA<Book>());
      expect((args as Book).name, '书甲');
      expect(args.author, '作者甲');
      expect(args.bookUrl, 'https://src.com/book/a');
      expect(args.origin, 'https://src.com');
      expect(tester.takeException(), isNull);
    });

    testWidgets('同一本书出现在两个模块：重复渲染不崩（Hero 去重防护）', (tester) async {
      final dup = bookJson('重复书', '作者甲', '/book/dup');
      final payload = jsonEncode({
        'modules': [
          {
            'key': 'm1',
            'title': '模块一',
            'url': '/m1',
            'resolvedUrl': 'https://src.com/m1',
            'books': [dup],
          },
          {
            'key': 'm2',
            'title': '模块二',
            'url': '/m2',
            'resolvedUrl': 'https://src.com/m2',
            'books': [dup],
          },
        ],
      });
      await pumpBookInfo(tester, relatedBooks: (_) async => payload);

      expect(find.text('模块一'), findsOneWidget);
      expect(find.text('模块二'), findsOneWidget);
      expect(find.text('重复书'), findsNWidgets(2));
      expect(tester.takeException(), isNull);
    });

    testWidgets('空数据：{"modules":[]} → 区块不出现', (tester) async {
      await pumpBookInfo(tester, relatedBooks: (_) async => '{"modules":[]}');

      expect(find.text('相似推荐'), findsNothing);
      expect(find.text('作者其他作品'), findsNothing);
      expect(find.byKey(const ValueKey('bookInfoRelatedBooks')), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('异常降级：请求抛错 → 区块不出现且不崩', (tester) async {
      await pumpBookInfo(
        tester,
        relatedBooks: (_) async => throw Exception('网络失败'),
      );

      expect(find.byKey(const ValueKey('bookInfoRelatedBooks')), findsNothing);
      expect(find.text('相似推荐'), findsNothing);
      expect(tester.takeException(), isNull);
      // 详情页其余内容仍在（降级不得影响主信息区）
      expect(find.text('当前书'), findsWidgets);
    });
  });
}
