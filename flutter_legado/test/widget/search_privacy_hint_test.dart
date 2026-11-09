/// 搜索页书架提示私密过滤测试（批9c）
///
/// 覆盖：私密且未获准的书不出现在「书架」实时搜索提示里（能否搜到本身
/// 就是泄漏）；EveryTime 授权该本后恢复出现。
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
import 'package:flutter_legado/src/screens/search_screen.dart';

import '../mocks/privacy_mock_book_api.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final privateBook = Book(
    bookUrl: 'https://a.com/secret',
    name: '私密搜索书',
    author: '秘密作者',
    origin: 'https://a.com',
    bookType: BookType.text,
    isPrivate: true,
  );
  final publicBook = Book(
    bookUrl: 'https://a.com/public',
    name: '公开搜索书',
    author: '公开作者',
    origin: 'https://a.com',
    bookType: BookType.text,
  );

  late PrivacyMockBookApi api;
  late ProviderContainer container;

  Future<void> boot(WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({
      PrefKeys.privateEnabled: true,
      PrefKeys.privateVerifyOnOpenBook: true,
      PrefKeys.privateUnlockScope: PrivacyUnlockScope.everyTime.storageValue,
    });
    api = PrivacyMockBookApi(books: [privateBook, publicBook]);
    await api.privacySetPassword('pw');
    container = ProviderContainer(
      overrides: [bookApiProvider.overrideWithValue(api)],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: SearchScreen()),
      ),
    );
    await tester.pump();
    await tester.pump();
    await tester.pump();
  }

  testWidgets('私密书不出现在书架提示；公开书正常显示', (tester) async {
    await boot(tester);
    await tester.enterText(find.byType(SearchBar), '搜索书');
    await tester.pump();
    await tester.pump();

    expect(find.text('书架'), findsOneWidget, reason: '公开书应触发书架提示节');
    expect(find.text('公开搜索书'), findsOneWidget);
    expect(find.text('私密搜索书'), findsNothing, reason: '私密且未获准的书不得被搜索到（含提示节）');
    expect(find.text('秘密作者'), findsNothing);
  });

  testWidgets('EveryTime 授权该本后，搜索提示恢复显示', (tester) async {
    await boot(tester);
    await container
        .read(privacyNotifierProvider.notifier)
        .verifyForTarget('pw', bookUrl: privateBook.bookUrl);
    await tester.enterText(find.byType(SearchBar), '私密搜');
    await tester.pump();
    await tester.pump();

    expect(find.text('私密搜索书'), findsOneWidget);
  });
}
