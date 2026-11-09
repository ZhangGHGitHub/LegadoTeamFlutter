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

import 'package:flutter_legado/src/constants/pref_keys.dart';
import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/providers/bookshelf/bookshelf_notifier.dart';
import 'package:flutter_legado/src/providers/privacy/privacy_state.dart';
import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/screens/book_group_screen.dart';

import '../mocks/privacy_mock_book_api.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late PrivacyMockBookApi api;
  late ProviderContainer container;

  Future<void> boot(
    WidgetTester tester,
    List<BookGroup> groups, {
    List<Book> books = const [],
    bool hasPassword = true,
    bool enabled = true,
  }) async {
    SharedPreferences.setMockInitialValues({
      PrefKeys.privateEnabled: enabled,
      PrefKeys.privateVerifyOnOpenBook: true,
      PrefKeys.privateVerifyOnEnterGroup: true,
      PrefKeys.privateUnlockScope: PrivacyUnlockScope.everyTime.storageValue,
    });
    api = PrivacyMockBookApi(groups: groups, books: books);
    if (hasPassword) await api.privacySetPassword('pw');
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

  testWidgets('私密组计数以占位符隐藏', (tester) async {
    await boot(
      tester,
      [const BookGroup(groupId: 4, groupName: '私密旧组', isPrivate: true)],
      books: [const Book(bookUrl: 'u1', name: '组内书', author: '作者', group: 4)],
    );
    final tile = find.ancestor(
      of: find.text('私密旧组'),
      matching: find.byType(ListTile),
    );
    expect(
      find.descendant(of: tile, matching: find.text('1 本书')),
      findsNothing,
      reason: '私密组不展示真实书籍数',
    );
    expect(find.descendant(of: tile, matching: find.text('—')), findsOneWidget);
  });

  testWidgets('私密组计数：隐私未启用时不隐藏（与书架 locked 同口径）', (tester) async {
    await boot(
      tester,
      [const BookGroup(groupId: 4, groupName: '私密旧组', isPrivate: true)],
      books: [const Book(bookUrl: 'u1', name: '组内书', author: '作者', group: 4)],
      enabled: false,
    );
    final tile = find.ancestor(
      of: find.text('私密旧组'),
      matching: find.byType(ListTile),
    );
    expect(
      find.descendant(of: tile, matching: find.text('1 本书')),
      findsOneWidget,
    );
    expect(find.descendant(of: tile, matching: find.text('—')), findsNothing);
  });

  testWidgets('分配书籍列表剔除私密书并提示隐藏数量', (tester) async {
    const privateBook = Book(
      bookUrl: 'u-private',
      name: '私密书',
      author: '私密作者',
      isPrivate: true,
      group: 4,
    );
    const publicBook = Book(
      bookUrl: 'u-public',
      name: '公开书',
      author: '公开作者',
      group: 4,
    );
    await boot(
      tester,
      [const BookGroup(groupId: 4, groupName: '目标组')],
      books: [privateBook, publicBook],
    );
    await container.read(bookshelfNotifierProvider.notifier).refresh();
    await tester.pumpAndSettle();

    final tile = find.ancestor(
      of: find.text('目标组'),
      matching: find.byType(ListTile),
    );
    await tester.tap(
      find.descendant(of: tile, matching: find.byType(PopupMenuButton<String>)),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('分配书籍'));
    await tester.pumpAndSettle();

    expect(find.text('私密书'), findsNothing);
    expect(find.text('私密作者'), findsNothing);
    expect(find.text('公开书'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('group-assign-hidden-hint')),
      findsOneWidget,
    );
    expect(find.textContaining('已隐藏 1 本私密书籍'), findsOneWidget);
  });

  testWidgets('未设置密码：私密开关置灰并提示', (tester) async {
    await boot(tester, [
      const BookGroup(groupId: 4, groupName: '旧组'),
    ], hasPassword: false);
    await openEdit(tester, '旧组');
    final switchTile = tester.widget<SwitchListTile>(
      find.byKey(const ValueKey('group-private-switch')),
    );
    expect(switchTile.onChanged, isNull, reason: '无密码时禁止开启私密分组');
    expect(find.text('请先在隐私设置中设置密码'), findsOneWidget);
  });

  testWidgets('删除私密分组提示组内书籍回到公开书架', (tester) async {
    await boot(tester, [
      const BookGroup(groupId: 4, groupName: '私密旧组', isPrivate: true),
    ]);
    final tile = find.ancestor(
      of: find.text('私密旧组'),
      matching: find.byType(ListTile),
    );
    await tester.tap(
      find.descendant(of: tile, matching: find.byType(PopupMenuButton<String>)),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();

    expect(find.textContaining('组内非私密书籍将回到公开书架'), findsOneWidget);
    await tester.tap(find.text('取消').last);
    await tester.pumpAndSettle();
  });
}
