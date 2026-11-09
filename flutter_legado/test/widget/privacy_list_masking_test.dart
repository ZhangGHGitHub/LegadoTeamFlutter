/// 列表页私密脱敏测试（批9c）
///
/// 覆盖：阅读记录脱敏（书名/作者/时长不渲染，只留模糊封面+时间）、
/// 书签脱敏（章节/书名/正文不渲染）、缓存管理脱敏（书名/作者置空）；
/// 授权后恢复显示。
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
import 'package:flutter_legado/src/providers/read_record/read_record_notifier.dart';
import 'package:flutter_legado/src/screens/bookmark_screen.dart';
import 'package:flutter_legado/src/screens/offline_cache_screen.dart';
import 'package:flutter_legado/src/screens/read_record_screen.dart';
import 'package:flutter_legado/src/screens/search_screen.dart';

import '../mocks/privacy_mock_book_api.dart';

final _privateBook = Book(
  bookUrl: 'https://a.com/secret',
  name: '秘密书名',
  author: '秘密作者',
  origin: 'https://a.com',
  bookType: BookType.text,
  isPrivate: true,
);

final _privateRecord = ReadRecord(
  deviceId: 'device',
  bookName: _privateBook.name,
  author: _privateBook.author,
  readTime: 61000,
  lastRead: DateTime(2026, 11, 8).millisecondsSinceEpoch,
  lastChapterTitle: '秘密章节',
);

final _privateBookmark = Bookmark(
  id: 1,
  time: DateTime(2026, 11, 8, 12, 30).millisecondsSinceEpoch,
  bookName: _privateBook.name,
  bookAuthor: _privateBook.author,
  chapterIndex: 2,
  chapterName: '秘密书签章节',
  bookText: '秘密正文片段',
  content: '秘密备注',
);

/// 记录 findBookByName 调用（锁定行点击不应触发）
class _SpyReadRecordNotifier extends ReadRecordNotifier {
  int findBookByNameCalls = 0;

  @override
  Future<Book?> findBookByName(String bookName) async {
    findBookByNameCalls++;
    return null;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late PrivacyMockBookApi api;
  late ProviderContainer container;

  Future<void> boot(
    WidgetTester tester,
    Widget screen, {
    Set<String> grantedBookUrls = const {},
    bool settle = true,
    ReadRecordNotifier Function()? readRecordFactory,
  }) async {
    SharedPreferences.setMockInitialValues({
      PrefKeys.privateEnabled: true,
      PrefKeys.privateVerifyOnOpenBook: true,
      PrefKeys.privateUnlockScope: PrivacyUnlockScope.everyTime.storageValue,
    });
    api = PrivacyMockBookApi(
      books: [_privateBook],
      readRecords: [_privateRecord],
      bookmarks: [_privateBookmark],
    );
    await api.privacySetPassword('pw');
    container = ProviderContainer(
      overrides: [
        bookApiProvider.overrideWithValue(api),
        if (readRecordFactory != null)
          readRecordNotifierProvider.overrideWith(readRecordFactory),
      ],
    );
    addTearDown(container.dispose);
    await container.read(privacyNotifierProvider.notifier).ensureLoaded();
    for (final url in grantedBookUrls) {
      await container
          .read(privacyNotifierProvider.notifier)
          .verifyForTarget('pw', bookUrl: url);
    }
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(home: screen),
      ),
    );
    await tester.pump();
    await tester.pump();
    if (settle) {
      await tester.pumpAndSettle();
    } else {
      await tester.pump();
    }
  }

  testWidgets('阅读记录：书名/作者/时长不渲染，保留模糊封面与时间', (tester) async {
    await boot(tester, const ReadRecordScreen());

    expect(find.byKey(const ValueKey('readRecordLockedTile')), findsOneWidget);
    expect(find.text('秘密书名'), findsNothing);
    expect(find.text('秘密作者'), findsNothing);
    expect(find.textContaining('阅读时长'), findsNothing);
    expect(
      find.textContaining('最后阅读：2026-11-08'),
      findsOneWidget,
      reason: '时间不是身份信息，保留',
    );
  });

  testWidgets('阅读记录：EveryTime 授权该本后恢复显示', (tester) async {
    await boot(
      tester,
      const ReadRecordScreen(),
      grantedBookUrls: {_privateBook.bookUrl},
    );

    expect(find.byKey(const ValueKey('readRecordLockedTile')), findsNothing);
    expect(find.text('秘密书名'), findsOneWidget);
    expect(find.text('秘密作者'), findsOneWidget);
    expect(find.textContaining('阅读时长'), findsOneWidget);
  });

  testWidgets('书签：章节/书名/正文/备注不渲染，时间保留', (tester) async {
    await boot(tester, const BookmarkScreen());

    expect(find.byKey(const ValueKey('bookmarkLockedTile')), findsOneWidget);
    expect(find.text('秘密书签章节'), findsNothing);
    expect(find.text('秘密书名'), findsNothing);
    expect(find.text('秘密正文片段'), findsNothing);
    expect(find.textContaining('秘密备注'), findsNothing);
    expect(find.textContaining('2026-11-08'), findsOneWidget);
  });

  testWidgets('锁定阅读记录删除确认不泄漏书名；取消不删除', (tester) async {
    await boot(tester, const ReadRecordScreen());
    await tester.ensureVisible(find.text('清空').last);
    await tester.tap(find.text('清空').last);
    await tester.pumpAndSettle();

    expect(find.textContaining('本书'), findsOneWidget);
    expect(
      find.textContaining('秘密书名'),
      findsNothing,
      reason: '锁定态删除确认不得出现真实书名',
    );
    await tester.tap(find.text('取消').last);
    await tester.pumpAndSettle();
    expect(api.deleteReadRecordCalls, 0);
  });

  testWidgets('阅读记录删除失败提示失败（不静默/不假成功）', (tester) async {
    await boot(tester, const ReadRecordScreen());
    api.failDeleteReadRecord = true;
    await tester.ensureVisible(find.text('清空').last);
    await tester.tap(find.text('清空').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();

    expect(api.deleteReadRecordCalls, 1);
    expect(find.textContaining('删除失败'), findsOneWidget);
    expect(find.text('已删除阅读记录'), findsNothing);
  });

  testWidgets('锁定书签删除确认不泄漏章节；取消不删除', (tester) async {
    await boot(tester, const BookmarkScreen());
    await tester.longPress(find.byKey(const ValueKey('bookmarkLockedTile')));
    await tester.pumpAndSettle();

    expect(find.textContaining('本书'), findsOneWidget);
    expect(find.textContaining('秘密书签章节'), findsNothing);
    await tester.tap(find.text('取消').last);
    await tester.pumpAndSettle();
    expect(api.deleteBookmarkCalls, 0);
  });

  testWidgets('书签删除失败提示失败（不静默/不假成功）', (tester) async {
    await boot(tester, const BookmarkScreen());
    api.failDeleteBookmark = true;
    await tester.longPress(find.byKey(const ValueKey('bookmarkLockedTile')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();

    expect(api.deleteBookmarkCalls, 1);
    expect(find.textContaining('删除失败'), findsOneWidget);
    expect(find.text('书签已删除'), findsNothing);
  });

  testWidgets('锁定阅读记录行点击不触发书籍查找/搜索跳转', (tester) async {
    final spy = _SpyReadRecordNotifier();
    await boot(tester, const ReadRecordScreen(), readRecordFactory: () => spy);
    await tester.tap(find.byKey(const ValueKey('readRecordLockedTile')));
    await tester.pumpAndSettle();

    expect(spy.findBookByNameCalls, 0, reason: '锁定行 onTap 必须禁用，不得进入打开书籍/搜索链路');
    expect(find.byType(SearchScreen), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('缓存管理：私密书书名/作者置空，缓存进度保留', (tester) async {
    await boot(tester, const OfflineCacheScreen(), settle: false);

    expect(find.text('秘密书名'), findsNothing);
    expect(find.text('秘密作者'), findsNothing);
    expect(
      find.textContaining('已缓存'),
      findsOneWidget,
      reason: '缓存条目与进度保留，用户仍可清缓存',
    );
  });

  testWidgets('360dp + 大字号：阅读记录脱敏行无溢出', (tester) async {
    tester.view.physicalSize = const Size(1080, 1920);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);
    await boot(tester, const ReadRecordScreen());
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(
          size: Size(360, 640),
          textScaler: TextScaler.linear(1.8),
        ),
        child: UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: ReadRecordScreen()),
        ),
      ),
    );
    await tester.pump();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.byKey(const ValueKey('readRecordLockedTile')), findsOneWidget);
  });
}
