import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/screens/change_source_screen.dart';

import '../mocks/mocks.dart';

void main() {
  late MockRustApi mockApi;
  late ProviderContainer container;

  setUpAll(registerFallbacks);

  setUp(() {
    mockApi = MockRustApi();
    container = ProviderContainer(
      overrides: [bookApiProvider.overrideWithValue(mockApi)],
    );
    addTearDown(container.dispose);

    when(() => mockApi.getConfig(any())).thenAnswer((_) async => '');
    when(() => mockApi.getBookSources()).thenAnswer((_) async => []);
    when(
      () => mockApi.updateSearchBookScore(any(), any()),
    ).thenAnswer((_) async {});
    when(() => mockApi.deleteSearchBook(any())).thenAnswer((_) async {});
    when(() => mockApi.disableBookSource(any())).thenAnswer((_) async {});
    when(
      () => mockApi.switchSource(any(), any(), any()),
    ).thenAnswer((_) async => '{"bookUrl":"https://b.com/book"}');
  });

  Map<String, dynamic> rawMatch({
    required String sourceUrl,
    required String sourceName,
    required String bookUrl,
    int bookScore = 0,
  }) => {
    'source_url': sourceUrl,
    'source_name': sourceName,
    'book_url': bookUrl,
    'book_name': '斗破苍穹',
    'author': '天蚕土豆',
    'book_score': bookScore,
  };

  Widget wrap(Widget child) {
    return UncontrolledProviderScope(
      container: container,
      child: MaterialApp(home: child),
    );
  }

  Future<void> pumpChangeSource(
    WidgetTester tester, {
    String currentSourceUrl = 'https://a.com',
  }) async {
    when(
      () => mockApi.searchSource(
        any(),
        any(),
        sourceUrls: any(named: 'sourceUrls'),
        loadInfo: any(named: 'loadInfo'),
        loadToc: any(named: 'loadToc'),
        loadWordCount: any(named: 'loadWordCount'),
        forceRefresh: any(named: 'forceRefresh'),
      ),
    ).thenAnswer(
      (_) async => [
        rawMatch(
          sourceUrl: 'https://a.com',
          sourceName: 'A源',
          bookUrl: 'https://a.com/book',
        ),
        rawMatch(
          sourceUrl: 'https://b.com',
          sourceName: 'B源',
          bookUrl: 'https://b.com/book',
        ),
      ],
    );

    await tester.pumpWidget(
      wrap(
        ChangeSourceScreen(
          bookName: '斗破苍穹',
          author: '天蚕土豆',
          currentSourceUrl: currentSourceUrl,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  group('ChangeSourceScreen', () {
    testWidgets('顶栏显示书名 title 与作者 subtitle', (tester) async {
      await pumpChangeSource(tester);

      expect(find.text('斗破苍穹'), findsOneWidget);
      expect(find.text('天蚕土豆'), findsOneWidget);
      expect(find.textContaining('换源 -'), findsNothing);
    });

    testWidgets('点按赞调用 updateSearchBookScore(+1)', (tester) async {
      await pumpChangeSource(tester);

      await tester.tap(find.byTooltip('赞').first);
      await tester.pumpAndSettle();

      verify(
        () => mockApi.updateSearchBookScore('https://a.com/book', 1),
      ).called(1);
    });

    testWidgets('长按显示五项操作菜单', (tester) async {
      await pumpChangeSource(tester);

      await tester.longPress(find.text('B源'));
      await tester.pumpAndSettle();

      expect(find.text('置顶'), findsOneWidget);
      expect(find.text('置底'), findsOneWidget);
      expect(find.text('编辑书源'), findsOneWidget);
      expect(find.text('禁用书源'), findsOneWidget);
      expect(find.text('删除'), findsOneWidget);
    });

    testWidgets('长按禁用书源调用 disableBookSource', (tester) async {
      await pumpChangeSource(tester);

      await tester.longPress(find.text('B源'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('禁用书源'));
      await tester.pumpAndSettle();

      verify(() => mockApi.disableBookSource('https://b.com')).called(1);
      expect(find.text('B源'), findsNothing);
    });

    testWidgets('底栏显示当前源名且滚顶/滚底按钮存在', (tester) async {
      await pumpChangeSource(tester);

      expect(find.text('A源'), findsWidgets);
      expect(find.byTooltip('滚到顶部'), findsOneWidget);
      expect(find.byTooltip('滚到底部'), findsOneWidget);
    });

    testWidgets('底栏滚顶按钮可点击', (tester) async {
      tester.view.physicalSize = const Size(400, 320);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      when(
        () => mockApi.searchSource(
          any(),
          any(),
          sourceUrls: any(named: 'sourceUrls'),
          loadInfo: any(named: 'loadInfo'),
          loadToc: any(named: 'loadToc'),
          loadWordCount: any(named: 'loadWordCount'),
          forceRefresh: any(named: 'forceRefresh'),
        ),
      ).thenAnswer(
        (_) async => List.generate(
          30,
          (i) => rawMatch(
            sourceUrl: 'https://src$i.com',
            sourceName: '源$i',
            bookUrl: 'https://src$i.com/book',
          ),
        ),
      );

      await tester.pumpWidget(
        wrap(
          const ChangeSourceScreen(
            bookName: '斗破苍穹',
            author: '天蚕土豆',
            currentSourceUrl: 'https://src0.com',
          ),
        ),
      );
      await tester.pumpAndSettle();

      final listView = tester.widget<ListView>(find.byType(ListView));
      final controller = listView.controller;
      expect(controller, isNotNull);
      expect(controller!.position.maxScrollExtent, greaterThan(0));

      await tester.tap(find.byTooltip('滚到底部'));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 350));
      expect(controller.offset, greaterThan(0));

      await tester.tap(find.byTooltip('滚到顶部'));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 350));
      expect(controller.offset, 0);
    });
  });
}
