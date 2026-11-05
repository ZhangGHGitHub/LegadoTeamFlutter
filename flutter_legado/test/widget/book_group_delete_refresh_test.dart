// 删除分组后刷新书架（审查 P2-2）
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/screens/book_group_screen.dart';

import '../mocks/mocks.dart';

void main() {
  setUpAll(registerFallbacks);

  testWidgets('删除分组后刷新书架通知器（getBooks 重新调用）', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final api = MockRustApi();
    final groups = <BookGroup>[
      const BookGroup(groupId: 1, groupName: '旧组A', order: 0),
    ];
    when(() => api.getBooks()).thenAnswer(
      (_) async => const [
        Book(bookUrl: 'b1', name: '组内书', group: 1),
      ],
    );
    when(() => api.getBookGroups()).thenAnswer((_) async => List.of(groups));
    when(() => api.deleteBookGroup(any())).thenAnswer((invocation) async {
      final id = invocation.positionalArguments.first as int;
      groups.removeWhere((g) => g.groupId == id);
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: [bookApiProvider.overrideWithValue(api)],
        child: const MaterialApp(home: BookGroupScreen()),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('旧组A'), findsOneWidget);

    // 打开分组菜单 → 删除 → 确认
    await tester.tap(find.byType(PopupMenuButton<String>).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除').last);
    await tester.pumpAndSettle();

    verify(() => api.deleteBookGroup(1)).called(1);
    // 首次构建 1 次 + 删除后 refresh 1 次
    verify(() => api.getBooks()).called(2);
  });
}
