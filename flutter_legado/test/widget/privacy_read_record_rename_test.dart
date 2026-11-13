/// 私密书改名后阅读记录脱敏测试（审查 P2-3）
///
/// 根因：`readRecord`/`bookmarks` 表只存「书名 + 作者」，脱敏反查按
/// **当前** `books.name + author` 建键；私密书改名后旧记录仍持旧名 →
/// 反查落空 → fail-open → 旧书名明文显示，点击还会把旧书名作为关键词
/// 发给第三方书源搜索。
///
/// 本文件走真实 UI 改名链路（编辑书籍信息 → 保存），验证：
/// 1. 私密书改名后阅读记录列表不出现旧书名，行呈锁定态；
/// 2. 点击该记录不触发书籍查找 / 第三方搜索（搜索路由参数为空）；
/// 3. 列表渲染后书籍才变为私密的竞态：点击前兜底校验必须阻止外发；
/// 4. 非私密书改名后记录不被误脱敏，并按当前书名正常显示。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/constants/pref_keys.dart';
import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/providers/privacy/privacy_content_notifier.dart';
import 'package:flutter_legado/src/providers/privacy/privacy_notifier.dart';
import 'package:flutter_legado/src/providers/privacy/privacy_state.dart';
import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/providers/read_record/read_record_notifier.dart';
import 'package:flutter_legado/src/routes.dart';
import 'package:flutter_legado/src/screens/edit_book_info_screen.dart';
import 'package:flutter_legado/src/screens/read_record_screen.dart';

import '../mocks/privacy_mock_book_api.dart';

const _oldName = '绝不能外发的旧书名';
const _newName = '改名后的新书名';
const _author = '秘密作者';

/// 记录打开书籍前的按名查找（锁定态不得进入该链路）
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
  int searchPushes = 0;
  Object? searchArguments;

  Book buildBook({required bool isPrivate}) => Book(
    bookUrl: 'https://a.com/secret',
    name: _oldName,
    author: _author,
    origin: 'https://a.com',
    bookType: BookType.text,
    isPrivate: isPrivate,
  );

  ReadRecord buildRecord() => ReadRecord(
    deviceId: 'device',
    // 改名后旧记录仍持落库时的旧书名；作者列在真实写路径中常为空
    bookName: _oldName,
    readTime: 61000,
    lastRead: DateTime(2026, 11, 8).millisecondsSinceEpoch,
    lastChapterTitle: '秘密章节',
  );

  Future<void> boot({
    required Book book,
    required List<ReadRecord> records,
    bool enabled = true,
    ReadRecordNotifier Function()? readRecordFactory,
  }) async {
    searchPushes = 0;
    searchArguments = null;
    SharedPreferences.setMockInitialValues({
      PrefKeys.privateEnabled: enabled,
      PrefKeys.privateVerifyOnOpenBook: true,
      PrefKeys.privateVerifyOnEnterGroup: true,
      PrefKeys.privateUnlockScope: PrivacyUnlockScope.everyTime.storageValue,
    });
    api = PrivacyMockBookApi(books: [book], readRecords: records);
    if (enabled) await api.privacySetPassword('pw');
    container = ProviderContainer(
      overrides: [
        bookApiProvider.overrideWithValue(api),
        if (readRecordFactory != null)
          readRecordNotifierProvider.overrideWith(readRecordFactory),
      ],
    );
    addTearDown(container.dispose);
    await container.read(privacyNotifierProvider.notifier).ensureLoaded();
  }

  /// 真实 UI 链路：打开编辑页 → 改书名 → 保存（触发改名副作用的登记）
  Future<void> renameBookViaUi(
    WidgetTester tester,
    Book book,
    String newName,
  ) async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => EditBookInfoScreen(book: book),
                    ),
                  ),
                  child: const Text('open-edit'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open-edit'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField).first, newName);
    await tester.tap(find.widgetWithText(FilledButton, '保存'));
    await tester.pumpAndSettle();
    expect(api.books.single.name, newName, reason: '改名应已落库');
  }

  Future<void> openReadRecords(WidgetTester tester) async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: const ReadRecordScreen(),
          routes: {
            AppRoutes.search: (context) {
              searchPushes++;
              searchArguments = ModalRoute.of(context)?.settings.arguments;
              return const Scaffold(body: Text('third-party-search'));
            },
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('私密书改名后：旧书名不出现，点击不触发第三方搜索', (tester) async {
    final spy = _SpyReadRecordNotifier();
    await boot(
      book: buildBook(isPrivate: true),
      records: [buildRecord()],
      readRecordFactory: () => spy,
    );
    await renameBookViaUi(tester, buildBook(isPrivate: true), _newName);

    await openReadRecords(tester);

    expect(find.text(_oldName), findsNothing, reason: '改名后旧书名不得在阅读记录列表明文显示');
    expect(find.text(_newName), findsNothing, reason: '私密且未授权时连当前书名也不得显示');
    expect(
      find.byKey(const ValueKey('readRecordLockedTile')),
      findsOneWidget,
      reason: '改名后的旧记录必须走脱敏行',
    );

    await tester.tap(find.textContaining('最后阅读：'));
    await tester.pumpAndSettle();

    expect(spy.findBookByNameCalls, 0, reason: '锁定记录不得进入打开书籍链路');
    expect(searchPushes, 0, reason: '不得把私密书书名发给第三方搜索');
    expect(searchArguments, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('列表渲染后才变为私密：点击前兜底校验阻止第三方搜索', (tester) async {
    final spy = _SpyReadRecordNotifier();
    // 开始时非私密：列表按普通行渲染（显示当前书名），快照已就绪
    await boot(
      book: buildBook(isPrivate: false),
      records: [buildRecord()],
      readRecordFactory: () => spy,
    );
    await renameBookViaUi(tester, buildBook(isPrivate: false), _newName);

    await openReadRecords(tester);
    expect(
      find.byKey(const ValueKey('readRecordLockedTile')),
      findsNothing,
      reason: '非私密书改名后不得过度脱敏',
    );
    expect(find.text(_newName), findsOneWidget, reason: '应按当前书名展示');

    // 列表已渲染后书籍被标记为私密（模拟标记变化/状态滞后），不 pump 重建
    api.books[0] = api.books[0].copyWith(isPrivate: true);
    await container.read(privacyContentProvider.notifier).refresh();

    await tester.tap(find.textContaining('最后阅读：'));
    await tester.pumpAndSettle();

    expect(spy.findBookByNameCalls, 0, reason: '未授权私密记录不得进入打开书籍链路');
    expect(searchPushes, 0, reason: '跳转前兜底校验必须阻止第三方搜索');
    expect(searchArguments, isNull);
    expect(find.textContaining('私密'), findsOneWidget, reason: '必须给出阻止提示');
  });

  testWidgets('非私密书改名后：记录不过度脱敏，显示当前书名', (tester) async {
    await boot(
      book: buildBook(isPrivate: false),
      records: [buildRecord()],
      enabled: false,
    );
    await renameBookViaUi(tester, buildBook(isPrivate: false), _newName);

    await openReadRecords(tester);

    expect(find.byKey(const ValueKey('readRecordLockedTile')), findsNothing);
    expect(
      find.text(_newName),
      findsOneWidget,
      reason: '非私密书改名后阅读记录应显示当前书名，不得残留旧名',
    );
    expect(find.text(_oldName), findsNothing);
    expect(find.textContaining('阅读时长'), findsOneWidget);
  });
}
