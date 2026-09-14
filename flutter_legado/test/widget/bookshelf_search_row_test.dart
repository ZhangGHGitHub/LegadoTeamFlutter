// [骨架对齐 2.0.260 | 台账 1-3] 书架搜索入口守护：页内全宽搜索行已移除，
// 搜索入口收敛为顶栏 🔍 图标（路由 AppRoutes.search 不变）——
// 无分组 / 分组两种头部形态下顶栏搜索图标必须可见。
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

  testWidgets('无分组：顶栏搜索图标可见（页内搜索行已移除）', (tester) async {
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

    // 顶栏搜索图标（tooltip「搜索」）可见
    expect(find.byTooltip('搜索'), findsOneWidget);
    // 页内搜索行提示文案不应再出现
    expect(find.text('搜索书名、作者...'), findsNothing);
  });

  testWidgets('分组模式：顶栏搜索图标同样可见', (tester) async {
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

    expect(find.byTooltip('搜索'), findsOneWidget);
    expect(find.text('搜索书名、作者...'), findsNothing);
  });
}
