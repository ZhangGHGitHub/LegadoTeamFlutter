/// 文本阅读器私密闸门测试（批9c）
///
/// 覆盖：未授权时不组合阅读器（全屏锁定页）、进入自动弹一次、取消后
/// 仍不进入阅读器、验证成功继续、离开路由撤销 EveryTime 单本授权。
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
import 'package:flutter_legado/src/providers/reader/reader_notifier.dart';
import 'package:flutter_legado/src/widgets/privacy/private_read_gate.dart';

import '../mocks/privacy_mock_book_api.dart';

/// 只提供当前书籍的 ReaderNotifier 替身（避免真实 openBook 链路）
class _FakeReaderNotifier extends ReaderNotifier {
  _FakeReaderNotifier(this.book);

  final Book book;

  @override
  ReaderState build() => ReaderState(currentBook: book);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final privateBook = Book(
    bookUrl: 'https://a.com/private',
    name: '私密书',
    author: '作者',
    isPrivate: true,
  );

  late PrivacyMockBookApi api;
  late ProviderContainer container;

  Future<void> boot(
    WidgetTester tester, {
    required Book book,
    bool hasPassword = true,
    bool enabled = true,
  }) async {
    SharedPreferences.setMockInitialValues({
      PrefKeys.privateEnabled: enabled,
      PrefKeys.privateVerifyOnOpenBook: true,
      PrefKeys.privateUnlockScope: PrivacyUnlockScope.everyTime.storageValue,
    });
    api = PrivacyMockBookApi(books: [book]);
    if (hasPassword) await api.privacySetPassword('pw');
    container = ProviderContainer(
      overrides: [
        bookApiProvider.overrideWithValue(api),
        readerNotifierProvider.overrideWith(() => _FakeReaderNotifier(book)),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: PrivateReadGate(child: Text('READER_CONTENT')),
        ),
      ),
    );
    await tester.pump();
    await tester.pumpAndSettle();
  }

  testWidgets('未授权：阅读器不组合，展示锁定页并自动弹验证', (tester) async {
    await boot(tester, book: privateBook);

    expect(
      find.text('READER_CONTENT'),
      findsNothing,
      reason: 'gate 未放行时阅读器组件根本不应组合',
    );
    expect(find.byKey(const ValueKey('privateReadGateLocked')), findsOneWidget);
    expect(find.byKey(const ValueKey('privacyUnlockDialog')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('privacyUnlockCancel')));
    await tester.pumpAndSettle();
    // 取消 = 放弃打开（home 无法 pop 时停在锁定页，仍不进入阅读器）
    expect(find.text('READER_CONTENT'), findsNothing);
    expect(find.byKey(const ValueKey('privateReadGateLocked')), findsOneWidget);
  });

  testWidgets('验证成功：继续进入阅读器；离开路由撤销 EveryTime 授权', (tester) async {
    await boot(tester, book: privateBook);

    await tester.enterText(
      find.byKey(const ValueKey('privacyUnlockField')),
      'pw',
    );
    await tester.tap(find.byKey(const ValueKey('privacyUnlockConfirm')));
    await tester.pumpAndSettle();

    expect(find.text('READER_CONTENT'), findsOneWidget);
    expect(
      container.read(privacyNotifierProvider).grantedBookUrls,
      contains(privateBook.bookUrl),
    );

    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    expect(
      container.read(privacyNotifierProvider).grantedBookUrls,
      isEmpty,
      reason: '离开阅读器（gate dispose）必须撤销 EveryTime 授权',
    );
  });

  testWidgets('非私密书：直接组合阅读器，不弹验证', (tester) async {
    final publicBook = privateBook.copyWith(isPrivate: false);
    await boot(tester, book: publicBook);

    expect(find.text('READER_CONTENT'), findsOneWidget);
    expect(find.byKey(const ValueKey('privacyUnlockDialog')), findsNothing);
  });

  testWidgets('AppSession：会话解锁后直接进入阅读器', (tester) async {
    SharedPreferences.setMockInitialValues({
      PrefKeys.privateEnabled: true,
      PrefKeys.privateVerifyOnOpenBook: true,
      PrefKeys.privateUnlockScope: PrivacyUnlockScope.appSession.storageValue,
    });
    api = PrivacyMockBookApi(books: [privateBook]);
    await api.privacySetPassword('pw');
    container = ProviderContainer(
      overrides: [
        bookApiProvider.overrideWithValue(api),
        readerNotifierProvider.overrideWith(
          () => _FakeReaderNotifier(privateBook),
        ),
      ],
    );
    addTearDown(container.dispose);
    await container.read(privacyNotifierProvider.notifier).ensureLoaded();
    await container
        .read(privacyNotifierProvider.notifier)
        .verifyForTarget('pw', bookUrl: privateBook.bookUrl);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: PrivateReadGate(child: Text('READER_CONTENT')),
        ),
      ),
    );
    await tester.pump();
    await tester.pumpAndSettle();
    expect(find.text('READER_CONTENT'), findsOneWidget);
    expect(find.byKey(const ValueKey('privacyUnlockDialog')), findsNothing);
  });
}
