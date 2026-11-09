/// 书架私密脱敏与批量私密 Widget 测试（批9c）
///
/// 覆盖：私密组书从「全部」剔除、单本私密卡片不渲染文本且显示锁标；
/// 批量模式锁图标仅在已设密码时出现并可切换私密（toast 计数）；
/// 私密分组 Tab 整页锁定（组名可见），解锁后显示书籍；
/// 文件夹根隐藏私密组预览与计数；360dp + 大字号无溢出。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/constants/pref_keys.dart';
import 'package:flutter_legado/src/models/bookshelf_settings.dart';
import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/providers/bookshelf/bookshelf_notifier.dart';
import 'package:flutter_legado/src/providers/privacy/privacy_notifier.dart';
import 'package:flutter_legado/src/providers/privacy/privacy_state.dart';
import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/screens/bookshelf_screen.dart';

import '../mocks/privacy_mock_book_api.dart';

/// 记录 revokeGroup 调用（P0-1 UI 级断言）
class _SpyPrivacyNotifier extends PrivacyNotifier {
  final List<int> revokedGroups = [];

  @override
  void revokeGroup(int? groupId) {
    if (groupId != null) revokedGroups.add(groupId);
    super.revokeGroup(groupId);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final privateGroupBook = Book(
    bookUrl: 'https://a.com/group-private',
    name: '私密组书',
    author: '作者甲',
    origin: 'https://a.com',
    bookType: BookType.text,
    group: 4,
  );
  final singlePrivateBook = Book(
    bookUrl: 'https://a.com/single-private',
    name: '单本私密书',
    author: '作者乙',
    origin: 'https://a.com',
    bookType: BookType.text,
    isPrivate: true,
  );
  final publicBook = Book(
    bookUrl: 'https://a.com/public',
    name: '公开书',
    author: '作者丙',
    origin: 'https://a.com',
    bookType: BookType.text,
    group: 8,
  );

  late PrivacyMockBookApi api;
  late ProviderContainer container;
  late _SpyPrivacyNotifier spyPrivacy;

  Future<void> boot(
    WidgetTester tester, {
    bool hasPassword = true,
    int groupStyle = 0,
    double textScale = 1.0,
    Size size = const Size(1080, 1920),
    double dpr = 3.0,
    ValueNotifier<bool>? tickerMode,
  }) async {
    SharedPreferences.setMockInitialValues({
      PrefKeys.privateEnabled: true,
      PrefKeys.privateVerifyOnOpenBook: true,
      PrefKeys.privateVerifyOnEnterGroup: true,
      PrefKeys.privateUnlockScope: PrivacyUnlockScope.everyTime.storageValue,
      BookshelfSettings.keyBookGroupStyle: groupStyle,
    });
    api = PrivacyMockBookApi(
      books: [privateGroupBook, singlePrivateBook, publicBook],
      groups: const [
        BookGroup(groupId: 4, groupName: '私密组', isPrivate: true, order: 0),
        BookGroup(groupId: 8, groupName: '公开组', order: 1),
      ],
    );
    if (hasPassword) await api.privacySetPassword('pw');
    container = ProviderContainer(
      overrides: [
        bookApiProvider.overrideWithValue(api),
        privacyNotifierProvider.overrideWith(() {
          spyPrivacy = _SpyPrivacyNotifier();
          return spyPrivacy;
        }),
      ],
    );
    addTearDown(container.dispose);
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = dpr;
    addTearDown(tester.view.reset);
    final app = UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: BookshelfScreen()),
    );
    await tester.pumpWidget(
      MediaQuery(
        data: MediaQueryData(
          size: Size(size.width / dpr, size.height / dpr),
          textScaler: TextScaler.linear(textScale),
        ),
        child: tickerMode == null
            ? app
            : ValueListenableBuilder<bool>(
                valueListenable: tickerMode,
                builder: (context, enabled, child) =>
                    TickerMode(enabled: enabled, child: child!),
                child: app,
              ),
      ),
    );
    await tester.pump();
    await tester.pump();
    await tester.pumpAndSettle();
  }

  testWidgets('「全部」剔除私密组书；单本私密卡片不渲染书名且显示锁标', (tester) async {
    await boot(tester);

    expect(find.text('公开书'), findsOneWidget);
    expect(find.text('私密组书'), findsNothing, reason: '私密组书不进入公开书架');
    expect(find.text('单本私密书'), findsNothing, reason: '锁定卡片不得渲染书名');
    expect(find.byKey(const ValueKey('private-lock-icon')), findsWidgets);
  });

  testWidgets('批量模式锁图标：有密码可见，切换私密并 toast 计数', (tester) async {
    await boot(tester);

    final notifier = container.read(bookshelfNotifierProvider.notifier);
    notifier.toggleBatchMode();
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('bookshelf-batch-private')),
      findsOneWidget,
    );

    notifier.toggleSelect(singlePrivateBook.bookUrl);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('bookshelf-batch-private')));
    await tester.pumpAndSettle();

    expect(api.setBooksPrivateCalls, hasLength(1));
    expect(api.setBooksPrivateCalls.single.bookUrls, [
      singlePrivateBook.bookUrl,
    ]);
    expect(
      api.setBooksPrivateCalls.single.isPrivate,
      isFalse,
      reason: '选中集合已含私密书 → 本次为取消私密',
    );
    expect(find.text('已更新 1 本书的私密状态'), findsOneWidget);
  });

  testWidgets('批量 toast 使用 Rust 实际更新行数而非请求数', (tester) async {
    await boot(tester);
    api.forcedSetBooksPrivateCount = 1;
    final notifier = container.read(bookshelfNotifierProvider.notifier);
    notifier.toggleBatchMode();
    await tester.pumpAndSettle();
    notifier.toggleSelect(singlePrivateBook.bookUrl);
    notifier.toggleSelect(publicBook.bookUrl);
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('bookshelf-batch-private')));
    await tester.pumpAndSettle();
    expect(api.setBooksPrivateCalls.single.bookUrls, hasLength(2));
    expect(
      find.text('已更新 1 本书的私密状态'),
      findsOneWidget,
      reason: 'toast 必须用 setBooksPrivate 返回值（1），不能用请求 2 本',
    );
  });

  testWidgets('未设置密码时批量模式不显示锁图标', (tester) async {
    await boot(tester, hasPassword: false);
    if (!container.read(bookshelfNotifierProvider).isBatchMode) {
      container.read(bookshelfNotifierProvider.notifier).toggleBatchMode();
    }
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('bookshelf-batch-private')), findsNothing);
  });

  testWidgets('私密分组 Tab：组名可见、内容整页锁定；解锁后显示组内书', (tester) async {
    await boot(tester);

    await tester.tap(find.text('私密组'));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('private-locked-page')), findsOneWidget);
    expect(find.text('私密组'), findsWidgets, reason: '组名保持可见');
    expect(find.text('私密组书'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('private-locked-action')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('privacyUnlockField')),
      'pw',
    );
    await tester.tap(find.byKey(const ValueKey('privacyUnlockConfirm')));
    await tester.pumpAndSettle();

    expect(find.text('私密组书'), findsOneWidget);
    expect(
      container.read(privacyNotifierProvider).grantedGroupIds,
      contains(4),
    );

    // P0-1：切到其它分组即撤销该分组授权
    await tester.tap(find.text('全部'));
    await tester.pumpAndSettle();
    expect(
      spyPrivacy.revokedGroups,
      contains(4),
      reason: '切分组必须调用 revokeGroup(4)',
    );
    expect(
      container.read(privacyNotifierProvider).grantedGroupIds,
      isEmpty,
      reason: 'EveryTime 离开分组后不得继续放行',
    );
  });

  testWidgets('书架 dispose：撤销当前分组 EveryTime 授权', (tester) async {
    await boot(tester);
    await tester.tap(find.text('私密组'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('private-locked-action')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('privacyUnlockField')),
      'pw',
    );
    await tester.tap(find.byKey(const ValueKey('privacyUnlockConfirm')));
    await tester.pumpAndSettle();
    expect(
      container.read(privacyNotifierProvider).grantedGroupIds,
      contains(4),
    );

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    await tester.pump();
    expect(
      spyPrivacy.revokedGroups,
      contains(4),
      reason: '书架 dispose 必须调用 revokeGroup(4)',
    );
    expect(container.read(privacyNotifierProvider).grantedGroupIds, isEmpty);
  });

  testWidgets('切走书架页签（TickerMode=false）撤销分组授权', (tester) async {
    final ticker = ValueNotifier<bool>(true);
    addTearDown(ticker.dispose);
    await boot(tester, tickerMode: ticker);
    await tester.tap(find.text('私密组'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('private-locked-action')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('privacyUnlockField')),
      'pw',
    );
    await tester.tap(find.byKey(const ValueKey('privacyUnlockConfirm')));
    await tester.pumpAndSettle();
    expect(
      container.read(privacyNotifierProvider).grantedGroupIds,
      contains(4),
    );

    ticker.value = false;
    await tester.pump();
    await tester.pump();
    expect(
      spyPrivacy.revokedGroups,
      contains(4),
      reason: '切走书架 PageView 页签必须撤销分组授权',
    );
    expect(container.read(privacyNotifierProvider).grantedGroupIds, isEmpty);
  });

  testWidgets('文件夹根：私密组不显示预览与书籍数', (tester) async {
    await boot(tester, groupStyle: 2);

    final privateCard = find.byKey(const ValueKey('bookshelf_folder_group_4'));
    final publicCard = find.byKey(const ValueKey('bookshelf_folder_group_8'));
    expect(privateCard, findsOneWidget);
    expect(publicCard, findsOneWidget);

    expect(
      find.descendant(of: privateCard, matching: find.text('1 本')),
      findsNothing,
      reason: '私密组在文件夹根不得展示书籍数',
    );
    expect(
      find.descendant(of: publicCard, matching: find.text('1 本')),
      findsOneWidget,
      reason: '公开组计数保持正常',
    );

    // 进入私密组：组名可见、内容锁定
    await tester.tap(privateCard);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('private-locked-page')), findsOneWidget);
    expect(find.text('私密组'), findsWidgets);
  });

  testWidgets('360dp + 1.8 倍字号：书架与锁定页无溢出', (tester) async {
    await boot(tester, size: const Size(1080, 1920), textScale: 1.8);
    expect(tester.takeException(), isNull);
    // 切到私密组锁定页同样不溢出
    await tester.tap(find.text('私密组'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.byKey(const ValueKey('private-locked-page')), findsOneWidget);
  });
}
