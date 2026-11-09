/// 分组编辑私密开关测试（批9c）
///
/// 覆盖：已有分组保存时先 updateBookGroup 再单列 setBookGroupPrivate；
/// 新建分组拿到 id 后落私密位；关闭已私密分组需二次确认（取消不关闭）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/screens/book_group_screen.dart';

import '../mocks/privacy_mock_book_api.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late PrivacyMockBookApi api;
  late ProviderContainer container;

  Future<void> boot(WidgetTester tester, List<BookGroup> groups) async {
    SharedPreferences.setMockInitialValues({});
    api = PrivacyMockBookApi(groups: groups);
    container = ProviderContainer(
      overrides: [bookApiProvider.overrideWithValue(api)],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: BookGroupScreen()),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> openEdit(WidgetTester tester, String groupName) async {
    final tile = find.ancestor(
      of: find.text(groupName),
      matching: find.byType(ListTile),
    );
    await tester.tap(
      find.descendant(of: tile, matching: find.byType(PopupMenuButton<String>)),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('编辑'));
    await tester.pumpAndSettle();
  }

  testWidgets('已有分组：保存时单列调用 setBookGroupPrivate(4, true)', (tester) async {
    await boot(tester, [const BookGroup(groupId: 4, groupName: '旧组')]);
    expect(find.text('旧组'), findsOneWidget);

    await openEdit(tester, '旧组');
    expect(find.byKey(const ValueKey('group-private-switch')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('group-private-switch')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('group-private-save')));
    await tester.pumpAndSettle();

    expect(api.setBookGroupPrivateCalls, hasLength(1));
    expect(api.setBookGroupPrivateCalls.single.groupId, 4);
    expect(api.setBookGroupPrivateCalls.single.isPrivate, isTrue);
  });

  testWidgets('新建分组：add 拿到 id 后再设置私密位', (tester) async {
    await boot(tester, const []);

    await tester.tap(find.byTooltip('新建分组'));
    await tester.pumpAndSettle();
    expect(find.text('新建分组'), findsWidgets);
    await tester.enterText(find.byType(TextField).first, '新私密组');
    await tester.tap(find.byKey(const ValueKey('group-private-switch')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('group-private-save')));
    await tester.pumpAndSettle();

    expect(api.groups, hasLength(1));
    expect(api.groups.single.groupName, '新私密组');
    expect(api.groups.single.isPrivate, isTrue);
    expect(api.setBookGroupPrivateCalls, hasLength(1));
    expect(
      api.setBookGroupPrivateCalls.single.groupId,
      api.groups.single.groupId,
    );
  });

  testWidgets('关闭私密分组需确认：取消保留开，确认后落 false', (tester) async {
    await boot(tester, [
      const BookGroup(groupId: 4, groupName: '私密旧组', isPrivate: true),
    ]);

    await openEdit(tester, '私密旧组');
    // 先取消：开关保持开
    await tester.tap(find.byKey(const ValueKey('group-private-switch')));
    await tester.pumpAndSettle();
    expect(find.text('关闭后，本组书籍可能在公开书架中显示'), findsOneWidget);
    await tester.tap(find.text('取消').last);
    await tester.pumpAndSettle();
    var switchWidget = tester.widget<SwitchListTile>(
      find.byKey(const ValueKey('group-private-switch')),
    );
    expect(switchWidget.value, isTrue);

    // 再关闭并确认
    await tester.tap(find.byKey(const ValueKey('group-private-switch')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();
    switchWidget = tester.widget<SwitchListTile>(
      find.byKey(const ValueKey('group-private-switch')),
    );
    expect(switchWidget.value, isFalse);
    await tester.tap(find.byKey(const ValueKey('group-private-save')));
    await tester.pumpAndSettle();

    expect(api.setBookGroupPrivateCalls.last.isPrivate, isFalse);
    expect(api.groups.single.isPrivate, isFalse);
  });
}
