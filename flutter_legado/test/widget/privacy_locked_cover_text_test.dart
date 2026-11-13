/// 锁定封面不得绘制真实书名/作者（审查 P2-1）
///
/// 根因：`PrivateLockedCover` 把 `bookName`/`bookAuthor` 转交给
/// `BookCover`；封面加载中/加载失败时 `BookCover` 回落默认封面并**绘制**
/// 书名/作者（`CoverSettings.showName` 默认 true）。锁定行虽被强模糊 +
/// 暗色遮罩包裹，仍违反「锁定行不渲染任何真实书名/作者」的隐私不变量。
///
/// 这些用例在锁定行存在真实封面地址（会走默认封面占位）时断言
/// `bookCoverText` 不存在；修复前该 CustomPaint 会被绘制。
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
import 'package:flutter_legado/src/screens/bookmark_screen.dart';
import 'package:flutter_legado/src/screens/read_record_screen.dart';

import '../mocks/privacy_mock_book_api.dart';

const _secretName = '绝不能绘制的秘密书名';
const _secretAuthor = '秘密作者';
const _coverUrl = 'https://a.com/secret-cover.jpg';

final _privateBook = Book(
  bookUrl: 'https://a.com/secret',
  name: _secretName,
  author: _secretAuthor,
  origin: 'https://a.com',
  coverUrl: _coverUrl,
  bookType: BookType.text,
  isPrivate: true,
);

final _privateRecord = ReadRecord(
  deviceId: 'device',
  bookName: _secretName,
  author: _secretAuthor,
  readTime: 61000,
  lastRead: DateTime(2026, 11, 8).millisecondsSinceEpoch,
);

final _privateBookmark = Bookmark(
  id: 1,
  time: DateTime(2026, 11, 8, 12, 30).millisecondsSinceEpoch,
  bookName: _secretName,
  bookAuthor: _secretAuthor,
  chapterIndex: 2,
  chapterName: '秘密章节',
  bookText: '秘密正文',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> boot(WidgetTester tester, Widget screen) async {
    SharedPreferences.setMockInitialValues({
      PrefKeys.privateEnabled: true,
      PrefKeys.privateVerifyOnOpenBook: true,
      PrefKeys.privateUnlockScope: PrivacyUnlockScope.everyTime.storageValue,
    });
    final api = PrivacyMockBookApi(
      books: [_privateBook],
      readRecords: [_privateRecord],
      bookmarks: [_privateBookmark],
    );
    await api.privacySetPassword('pw');
    final container = ProviderContainer(
      overrides: [bookApiProvider.overrideWithValue(api)],
    );
    addTearDown(container.dispose);
    await container.read(privacyNotifierProvider.notifier).ensureLoaded();

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(home: screen),
      ),
    );
    await tester.pump();
    await tester.pump();
  }

  testWidgets('阅读记录锁定行：封面占位不得绘制书名/作者文本', (tester) async {
    await boot(tester, const ReadRecordScreen());

    final tile = find.byKey(const ValueKey('readRecordLockedTile'));
    expect(tile, findsOneWidget);
    expect(
      find.descendant(
        of: tile,
        matching: find.byKey(const ValueKey('bookCoverDefault')),
      ),
      findsOneWidget,
      reason: '真实封面加载前/失败后应显示默认封面背景',
    );
    expect(
      find.descendant(
        of: tile,
        matching: find.byKey(const ValueKey('bookCoverText')),
      ),
      findsNothing,
      reason: '锁定行默认封面不得绘制真实书名/作者',
    );
    expect(find.text(_secretName), findsNothing);
    expect(find.text(_secretAuthor), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('书签锁定行：封面占位不得绘制书名/作者文本', (tester) async {
    await boot(tester, const BookmarkScreen());

    final tile = find.byKey(const ValueKey('bookmarkLockedTile'));
    expect(tile, findsOneWidget);
    expect(
      find.descendant(
        of: tile,
        matching: find.byKey(const ValueKey('bookCoverDefault')),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: tile,
        matching: find.byKey(const ValueKey('bookCoverText')),
      ),
      findsNothing,
      reason: '锁定行默认封面不得绘制真实书名/作者',
    );
    expect(find.text(_secretName), findsNothing);
    expect(find.text(_secretAuthor), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
