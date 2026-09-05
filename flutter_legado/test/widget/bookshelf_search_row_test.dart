// [UI_SYNC_REFACTOR B2 回归] 书架 Dynamic 搜索行守护：大标题下搜索胶囊
// 必须常驻（搜索入口由图标迁至 bottomContent；用户报障「搜索框/按钮消失」
// 回归守护——若迁移回退须同时保留其一）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/screens/bookshelf_screen.dart';

import '../mocks/mocks.dart';

void main() {
  setUpAll(registerFallbacks);

  testWidgets('书架顶部搜索行常驻（SliverAppBar bottom）', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final mockApi = MockRustApi();
    when(() => mockApi.getBooks()).thenAnswer((_) async => const [
          Book(bookUrl: 'u1', name: '书一'),
        ]);
    when(() => mockApi.getBookGroups()).thenAnswer((_) async => []);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [bookApiProvider.overrideWithValue(mockApi)],
        child: const MaterialApp(home: BookshelfScreen()),
      ),
    );
    await tester.pumpAndSettle();

    // 搜索行提示文案可见（SizeTransition 进场后全高）
    expect(find.text('搜索书名、作者...'), findsOneWidget);
    // [UI-fix v2.0.175] 顶栏搜索图标并存（原版对齐，双入口）
    expect(find.byTooltip('搜索'), findsOneWidget);
  });

  testWidgets('分组模式（pinned TabBar 头）搜索行同样常驻', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final mockApi = MockRustApi();
    when(() => mockApi.getBooks()).thenAnswer(
        (_) async => const [Book(bookUrl: 'u1', name: '书一')]);
    when(() => mockApi.getBookGroups()).thenAnswer((_) async => const [
          BookGroup(groupName: '默认分组', groupId: 1),
        ]);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [bookApiProvider.overrideWithValue(mockApi)],
        child: const MaterialApp(home: BookshelfScreen()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('搜索书名、作者...'), findsOneWidget);
  });
}
