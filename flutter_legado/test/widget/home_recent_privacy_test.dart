/// 首页「最近阅读」卡隐私脱敏回归测试（审查：首页裸书名匹配 + 无隐私判定）
///
/// 根因：
/// 1. 首页最近阅读按 `Book.name == ReadRecordShow.bookName` 裸书名匹配书架，
///    私密书改名后旧记录匹配不到 → 卡片消失（体验缺陷）；
/// 2. 匹配成功后直接渲染 `name/author/durChapterTitle`，未做私密/授权判定
///    → 私密书作为最近阅读时，首页明文展示书名、作者、章节名（隐私泄漏，
///    与批31 已脱敏的阅读记录页不一致）。
///
/// 本文件覆盖：
/// 1. 私密书作为最近阅读 → 不出现书名/作者/章节名，点击不打开阅读器；
/// 2. 非私密书 → 正常显示（防过度脱敏）；
/// 3. 私密书改名 → 仍能按别名桥匹配（卡片不消失），未授权占位、授权后显示新名；
/// 4. 隐私快照未加载完成的首帧 → 不出现私密书名（中性占位）。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/constants/pref_keys.dart';
import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/providers/bookshelf/bookshelf_notifier.dart';
import 'package:flutter_legado/src/providers/privacy/privacy_content_notifier.dart';
import 'package:flutter_legado/src/providers/privacy/privacy_notifier.dart';
import 'package:flutter_legado/src/providers/privacy/privacy_state.dart';
import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/providers/read_record/read_record_notifier.dart';
import 'package:flutter_legado/src/screens/home_tab_screen.dart';
import 'package:flutter_legado/src/services/privacy_record_alias_store.dart';

import '../mocks/privacy_mock_book_api.dart';

const _secretName = '绝不能外发的秘密书名';
const _secretAuthor = '秘密作者';
const _secretChapter = '秘密章节名';

/// 路由记录（断言锁定点击不产生任何导航）
class _RouteLog extends NavigatorObserver {
  final List<Route<dynamic>> pushed = [];

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    pushed.add(route);
    super.didPush(route, previousRoute);
  }
}

/// 隐私标记延迟返回：模拟隐私快照加载中（首帧竞态）
class _DelayedPrivacyApi extends PrivacyMockBookApi {
  _DelayedPrivacyApi({super.books, super.readRecords});

  final Completer<void> markerGate = Completer<void>();

  @override
  Future<List<String>> getPrivateBookUrls() async {
    await markerGate.future;
    return super.getPrivateBookUrls();
  }
}

/// 立即返回书籍的书架 Notifier（不等待隐私快照，构造「书架已就绪、
/// 隐私快照未就绪」的首帧窗口）
class _ImmediateBookshelfNotifier extends BookshelfNotifier {
  _ImmediateBookshelfNotifier(this._books);

  final List<Book> _books;

  @override
  BookshelfState build() => BookshelfState(books: _books);
}

Book _buildBook({
  required String name,
  required bool isPrivate,
  String chapterTitle = _secretChapter,
}) => Book(
  bookUrl: 'https://a.com/secret',
  name: name,
  author: _secretAuthor,
  origin: 'https://a.com',
  bookType: BookType.text,
  isPrivate: isPrivate,
  totalChapterNum: 100,
  durChapterIndex: 5,
  durChapterTitle: chapterTitle,
);

ReadRecord _buildRecord({required String bookName}) => ReadRecord(
  deviceId: 'device',
  bookName: bookName,
  author: _secretAuthor,
  readTime: 61000,
  lastRead: DateTime(2026, 11, 13, 9, 30).millisecondsSinceEpoch,
  lastChapterTitle: _secretChapter,
);

Future<ProviderContainer> _bootContainer({
  required PrivacyMockBookApi api,
  List<Book>? immediateShelfBooks,
  bool preloadPrivacyContent = true,
}) async {
  SharedPreferences.setMockInitialValues({
    PrefKeys.privateEnabled: true,
    PrefKeys.privateVerifyOnOpenBook: true,
    PrefKeys.privateUnlockScope: PrivacyUnlockScope.everyTime.storageValue,
  });
  await api.privacySetPassword('pw');
  final container = ProviderContainer(
    overrides: [
      bookApiProvider.overrideWithValue(api),
      if (immediateShelfBooks != null)
        bookshelfNotifierProvider.overrideWith(
          () => _ImmediateBookshelfNotifier(immediateShelfBooks),
        ),
    ],
  );
  addTearDown(container.dispose);
  await container.read(privacyNotifierProvider.notifier).ensureLoaded();
  if (preloadPrivacyContent) {
    await container.read(privacyContentProvider.notifier).ensureLoaded();
  }
  return container;
}

Future<_RouteLog> _pumpHome(
  WidgetTester tester,
  ProviderContainer container,
) async {
  final routeLog = _RouteLog();
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: const HomeTabScreen(),
        navigatorObservers: [routeLog],
      ),
    ),
  );
  await tester.pumpAndSettle();
  return routeLog;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('私密书作为最近阅读：书名/作者/章节不渲染，点击不打开阅读器', (tester) async {
    final api = PrivacyMockBookApi(
      books: [_buildBook(name: _secretName, isPrivate: true)],
      readRecords: [_buildRecord(bookName: _secretName)],
    );
    final container = await _bootContainer(api: api);
    final routeLog = await _pumpHome(tester, container);

    expect(find.text('私密书籍'), findsOneWidget, reason: '未授权私密书必须显示中性占位');
    expect(find.text(_secretName), findsNothing, reason: '私密书名不得在首页明文显示');
    expect(find.text(_secretAuthor), findsNothing, reason: '私密作者不得在首页明文显示');
    expect(find.text(_secretChapter), findsNothing, reason: '私密章节名不得在首页明文显示');

    final pushesBeforeTap = routeLog.pushed.length;
    await tester.tap(find.byKey(const ValueKey('homeRecentCard')));
    await tester.pumpAndSettle();

    expect(find.textContaining('请先在书架解锁'), findsOneWidget);
    expect(
      routeLog.pushed.length,
      pushesBeforeTap,
      reason: '未授权私密卡点击不得打开阅读器/详情/第三方搜索',
    );
  });

  testWidgets('非私密书作为最近阅读：正常显示书名/作者/章节（防过度脱敏）', (tester) async {
    final api = PrivacyMockBookApi(
      books: [_buildBook(name: '公开书名', isPrivate: false, chapterTitle: '公开章节')],
      readRecords: [_buildRecord(bookName: '公开书名')],
    );
    final container = await _bootContainer(api: api);
    await _pumpHome(tester, container);

    expect(find.text('公开书名'), findsOneWidget);
    expect(find.text(_secretAuthor), findsOneWidget);
    expect(find.text('公开章节'), findsOneWidget);
    expect(find.text('私密书籍'), findsNothing, reason: '非私密书不得被误脱敏');
  });

  testWidgets('私密书改名：别名桥仍能匹配，未授权占位、授权后显示新名', (tester) async {
    const newName = '改名后的新书名';
    final book = _buildBook(name: newName, isPrivate: true);
    final record = _buildRecord(bookName: _secretName);
    final api = PrivacyMockBookApi(books: [book], readRecords: [record]);
    // 先建容器（会重置 SharedPreferences mock），再登记改名别名，
    // 最后加载隐私快照，确保别名桥进入反查索引。
    final container = await _bootContainer(
      api: api,
      preloadPrivacyContent: false,
    );
    await const PrivacyRecordAliasStore().register(
      oldName: _secretName,
      oldAuthor: _secretAuthor,
      bookUrl: book.bookUrl,
    );
    await container.read(privacyContentProvider.notifier).ensureLoaded();
    await _pumpHome(tester, container);

    expect(
      find.byKey(const ValueKey('homeRecentCard')),
      findsOneWidget,
      reason: '改名后旧记录必须仍能匹配到书籍，卡片不得消失',
    );
    expect(find.text(_secretName), findsNothing, reason: '旧私密书名不得泄漏');
    expect(find.text(newName), findsNothing, reason: '未授权时当前书名也不得显示');
    expect(find.text('私密书籍'), findsOneWidget);

    await container
        .read(privacyNotifierProvider.notifier)
        .verifyForTarget('pw', bookUrl: book.bookUrl);
    await tester.pumpAndSettle();

    expect(find.text(newName), findsOneWidget, reason: '授权后显示改名后的当前书名');
    expect(find.text(_secretName), findsNothing);
    expect(find.text('私密书籍'), findsNothing);
  });

  testWidgets('隐私快照未加载完成的首帧：不出现私密书名（中性占位）', (tester) async {
    final book = _buildBook(name: _secretName, isPrivate: true);
    final api = _DelayedPrivacyApi(
      books: [book],
      readRecords: [_buildRecord(bookName: _secretName)],
    );
    final container = await _bootContainer(
      api: api,
      immediateShelfBooks: [book],
      preloadPrivacyContent: false,
    );

    final routeLog = _RouteLog();
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: const HomeTabScreen(),
          navigatorObservers: [routeLog],
        ),
      ),
    );
    // 等阅读记录加载完成，但隐私快照仍被延迟
    for (var i = 0; i < 20; i++) {
      if (container.read(readRecordNotifierProvider).records.isNotEmpty) break;
      await tester.pump(const Duration(milliseconds: 10));
    }
    expect(container.read(readRecordNotifierProvider).records, isNotEmpty);
    expect(container.read(privacyContentProvider).loaded, isFalse);
    // 记录状态变更后再推一帧，确保首页按最新记录重建
    await tester.pump();

    expect(find.text(_secretName), findsNothing, reason: '首帧快照未就绪不得明文渲染私密书名');
    expect(find.text(_secretAuthor), findsNothing);
    expect(find.text(_secretChapter), findsNothing);
    expect(
      find.byKey(const ValueKey('homeRecentPending')),
      findsOneWidget,
      reason: '快照未就绪时先渲染中性占位',
    );

    api.markerGate.complete();
    await tester.pumpAndSettle();

    expect(container.read(privacyContentProvider).loaded, isTrue);
    expect(find.text('私密书籍'), findsOneWidget);
    expect(find.text(_secretName), findsNothing);
  });
}
