/// 书籍详情私密锁定/菜单测试（批9c）
///
/// 覆盖：私密书详情整页锁定（3 条占位条、无书名/作者/操作区/FAB）、
/// 进入自动弹一次验证、取消后停在锁定页、验证成功揭示内容、离开页面
/// 撤销 EveryTime 授权；未设置密码时菜单项置灰并提示。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/constants/pref_keys.dart';
import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/providers/privacy/privacy_notifier.dart';
import 'package:flutter_legado/src/providers/privacy/privacy_state.dart';
import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/screens/book_info_screen.dart';

import '../mocks/privacy_mock_book_api.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final privateBook = Book(
    bookUrl: 'loc_book::private.epub',
    name: '绝不能露出的书名',
    author: '绝不能露出的作者',
    origin: BookType.localTag,
    bookType: BookType.text,
    isPrivate: true,
    totalChapterNum: 10,
    durChapterIndex: 3,
  );

  late PrivacyMockBookApi api;
  late ProviderContainer container;

  Widget wrap(Widget child) => UncontrolledProviderScope(
    container: container,
    child: MaterialApp(home: child),
  );

  Future<void> boot(
    WidgetTester tester, {
    required Book book,
    bool enabled = true,
    bool hasPassword = true,
    PrivacyUnlockScope scope = PrivacyUnlockScope.everyTime,
  }) async {
    SharedPreferences.setMockInitialValues({
      PrefKeys.privateEnabled: enabled,
      PrefKeys.privateVerifyOnOpenBook: true,
      PrefKeys.privateVerifyOnEnterGroup: true,
      PrefKeys.privateUnlockScope: scope.storageValue,
    });
    api = PrivacyMockBookApi(books: [book]);
    if (hasPassword) await api.privacySetPassword('pw');
    container = ProviderContainer(
      overrides: [bookApiProvider.overrideWithValue(api)],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(wrap(BookInfoScreen(book: book)));
    await tester.pump();
    await tester.pumpAndSettle();
  }

  testWidgets('私密书进入即锁定并自动弹一次验证；成功后揭示内容', (tester) async {
    await boot(tester, book: privateBook);

    // 整页锁定：不出现书名/作者/操作区/FAB
    expect(find.text(privateBook.name), findsNothing);
    expect(find.text(privateBook.author), findsNothing);
    expect(
      find.byKey(const ValueKey('private-locked-placeholders')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('private-locked-page')), findsOneWidget);
    expect(find.text('阅读'), findsNothing, reason: '锁定态不得提供阅读 FAB');
    // 自动弹出一次验证
    expect(find.byKey(const ValueKey('privacyUnlockDialog')), findsOneWidget);

    await tester.enterText(
      find.byKey(const ValueKey('privacyUnlockField')),
      'pw',
    );
    await tester.tap(find.byKey(const ValueKey('privacyUnlockConfirm')));
    await tester.pumpAndSettle();

    expect(find.text(privateBook.name), findsOneWidget, reason: '验证成功后应渲染真实书名');
    expect(
      find.byKey(const ValueKey('private-locked-placeholders')),
      findsNothing,
    );
    expect(find.text('阅读'), findsOneWidget);
  });

  testWidgets('取消验证停在锁定页，再次点验证可重试；离页撤销 EveryTime 授权', (tester) async {
    await boot(tester, book: privateBook);
    expect(find.byKey(const ValueKey('privacyUnlockDialog')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('privacyUnlockCancel')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('privacyUnlockDialog')), findsNothing);
    expect(find.byKey(const ValueKey('private-locked-page')), findsOneWidget);
    expect(find.text(privateBook.name), findsNothing);

    // 锁定页仍有验证入口
    await tester.tap(find.byKey(const ValueKey('private-locked-action')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('privacyUnlockDialog')), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('privacyUnlockField')),
      'pw',
    );
    await tester.tap(find.byKey(const ValueKey('privacyUnlockConfirm')));
    await tester.pumpAndSettle();
    expect(find.text(privateBook.name), findsOneWidget);
    expect(
      container.read(privacyNotifierProvider).grantedBookUrls,
      contains(privateBook.bookUrl),
    );

    // 离开详情页 → EveryTime 授权撤销
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    expect(
      container.read(privacyNotifierProvider).grantedBookUrls,
      isEmpty,
      reason: '离开详情页必须撤销单本授权',
    );
  });

  testWidgets('AppSession：验证后重进详情不再弹窗', (tester) async {
    await boot(tester, book: privateBook, scope: PrivacyUnlockScope.appSession);
    await tester.enterText(
      find.byKey(const ValueKey('privacyUnlockField')),
      'pw',
    );
    await tester.tap(find.byKey(const ValueKey('privacyUnlockConfirm')));
    await tester.pumpAndSettle();
    expect(find.text(privateBook.name), findsOneWidget);

    // 重进新页面：会话级放行，不弹窗、直接显示
    await tester.pumpWidget(wrap(BookInfoScreen(book: privateBook)));
    await tester.pump();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('privacyUnlockDialog')), findsNothing);
    expect(find.text(privateBook.name), findsOneWidget);
  });

  testWidgets('未设置密码：菜单项置灰并提示先设置密码', (tester) async {
    final publicBook = privateBook.copyWith(isPrivate: false);
    await boot(tester, book: publicBook, hasPassword: false);

    await tester.tap(find.byTooltip('更多'));
    await tester.pumpAndSettle();
    expect(find.text('标记为私密'), findsOneWidget);
    expect(find.text('请先设置密码'), findsOneWidget);
    final item = tester.widget<PopupMenuItem<String>>(
      find.ancestor(
        of: find.text('标记为私密'),
        matching: find.byType(PopupMenuItem<String>),
      ),
    );
    expect(item.enabled, isFalse, reason: '无密码时不得允许标记私密（防锁死）');
    expect(api.setBooksPrivateCalls, isEmpty);
  });

  testWidgets('菜单标记私密：当前态取最新 getBook，写入后菜单变取消私密', (tester) async {
    final publicBook = privateBook.copyWith(isPrivate: false);
    await boot(tester, book: publicBook);

    await tester.tap(find.byTooltip('更多'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('标记为私密'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('标记为私密'));
    await tester.pumpAndSettle();

    expect(api.setBooksPrivateCalls, hasLength(1));
    expect(api.setBooksPrivateCalls.single.bookUrls, [publicBook.bookUrl]);
    expect(api.setBooksPrivateCalls.single.isPrivate, isTrue);
    expect(find.text('已标记为私密'), findsOneWidget);

    await tester.tap(find.byTooltip('更多'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('取消私密'));
    await tester.pumpAndSettle();
    expect(find.text('取消私密'), findsOneWidget, reason: '菜单当前态应来自最新书籍记录');
  });

  testWidgets('360dp + 1.8 倍字号：锁定页无溢出', (tester) async {
    tester.view.physicalSize = const Size(1080, 1920);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);
    await boot(tester, book: privateBook);
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(
          size: Size(360, 640),
          textScaler: TextScaler.linear(1.8),
        ),
        child: wrap(BookInfoScreen(book: privateBook)),
      ),
    );
    await tester.pump();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.byKey(const ValueKey('private-locked-page')), findsOneWidget);
  });
}
