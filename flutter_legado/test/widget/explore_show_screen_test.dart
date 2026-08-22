// ExploreShowScreen 页码控件 widget 测试
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/screens/explore_show_screen.dart';

import '../mocks/mocks.dart';

void main() {
  late MockRustApi mockApi;

  const testSource = BookSource(
    bookSourceUrl: 'http://source.com',
    bookSourceName: '测试书源',
  );

  const args = ExploreShowArgs(
    source: testSource,
    categoryName: '推荐榜',
    categoryUrl: 'http://source.com/rank',
  );

  setUpAll(() {
    registerFallbacks();
  });

  setUp(() {
    mockApi = MockRustApi();
    when(() => mockApi.exploreFetchBooks(any(), any(), any())).thenAnswer(
      (_) async => [
        const SearchBook(
          bookUrl: 'http://book.com/1',
          name: '书1',
          author: '作者1',
        ),
        const SearchBook(
          bookUrl: 'http://book.com/2',
          name: '书2',
          author: '作者2',
        ),
      ],
    );
  });

  testWidgets('顶栏展示第 1 页并可打开页码选择器', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [bookApiProvider.overrideWithValue(mockApi)],
        child: const MaterialApp(
          home: ExploreShowScreen(args: args),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('第 1 页'), findsOneWidget);
    expect(find.text('书1'), findsOneWidget);
    expect(find.text('书2'), findsOneWidget);

    await tester.tap(find.text('第 1 页'));
    await tester.pumpAndSettle();

    expect(find.text('选择页码'), findsOneWidget);
  });

  testWidgets('顶栏「加入书架」按钮批量导入已加载书籍（R5）', (tester) async {
    when(() => mockApi.importBooks(any())).thenAnswer((_) async => 2);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [bookApiProvider.overrideWithValue(mockApi)],
        child: const MaterialApp(
          home: ExploreShowScreen(args: args),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 批量入架按钮存在
    expect(find.byIcon(Icons.playlist_add), findsOneWidget);

    await tester.tap(find.byIcon(Icons.playlist_add));
    await tester.pumpAndSettle();

    // 调用 importBooks 且传入 2 本书
    final captured = verify(() => mockApi.importBooks(captureAny())).captured;
    expect(captured, hasLength(1));
    final jsonArray = captured.single as String;
    final decoded = jsonDecode(jsonArray) as List;
    expect(decoded.length, equals(2));
    expect(find.text('已加入书架 2 本'), findsOneWidget);
  });

  testWidgets('无已加载书籍时点「加入书架」提示', (tester) async {
    when(() => mockApi.exploreFetchBooks(any(), any(), any()))
        .thenAnswer((_) async => <SearchBook>[]);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [bookApiProvider.overrideWithValue(mockApi)],
        child: const MaterialApp(
          home: ExploreShowScreen(args: args),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.playlist_add));
    await tester.pumpAndSettle();

    expect(find.text('没有已加载的书籍'), findsOneWidget);
    verifyNever(() => mockApi.importBooks(any()));
  });
}
