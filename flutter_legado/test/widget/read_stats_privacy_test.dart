/// 阅读统计（热力图 / 按天视图）私密脱敏测试（A3）
///
/// 缺陷背景：`readRecordDaily` 只有「日期 + 秒数」两列、没有书籍维度，
/// 热力图与按天视图此前完全无 privacy 引用——私密书的阅读时长会直接
/// 出现在每日统计里。
///
/// 处置（fail-closed）：
/// - 存在「私密且未获准」记录时，时长序列不可信 → 时长视图显示中性占位；
/// - 「按本数」模式数据源是逐条记录，按书剔除后可正常展示；
/// - 策略/私密标记未就绪（首帧竞态）→ 只显示占位，绝不先渲染真实时长；
/// - 非私密书不受影响（防过度脱敏）。
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
import 'package:flutter_legado/src/screens/read_record_screen.dart';
import 'package:flutter_legado/src/utils/read_stats_privacy.dart';

import '../mocks/privacy_mock_book_api.dart';

const _privateUrl = 'https://a.com/private';
const _publicUrl = 'https://a.com/public';
const _today = '2026-11-17';

final _privateBook = Book(
  bookUrl: _privateUrl,
  name: '秘密书名',
  author: '秘密作者',
  origin: 'https://a.com',
  bookType: BookType.text,
  isPrivate: true,
);

final _publicBook = Book(
  bookUrl: _publicUrl,
  name: '公开书名',
  author: '公开作者',
  origin: 'https://a.com',
  bookType: BookType.text,
);

ReadRecord _record(Book book, {int readTime = 3600000}) => ReadRecord(
  deviceId: 'device',
  bookName: book.name,
  author: book.author,
  readTime: readTime,
  lastRead: DateTime(2026, 11, 17).millisecondsSinceEpoch,
  lastChapterTitle: '章节',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late PrivacyMockBookApi api;
  late ProviderContainer container;

  /// 每日时长：今日 1 小时（`formatDuring` 口径 → 「1小时」）
  final daily = <Map<String, dynamic>>[
    {'date': _today, 'seconds': 3600},
  ];

  Future<void> boot({
    required List<Book> books,
    required List<ReadRecord> records,
    bool enabled = true,
  }) async {
    SharedPreferences.setMockInitialValues({
      PrefKeys.privateEnabled: enabled,
      PrefKeys.privateVerifyOnOpenBook: true,
      PrefKeys.privateUnlockScope: PrivacyUnlockScope.everyTime.storageValue,
    });
    api = PrivacyMockBookApi(books: books, readRecords: records, daily: daily);
    if (enabled) await api.privacySetPassword('pw');
    container = ProviderContainer(
      overrides: [bookApiProvider.overrideWithValue(api)],
    );
    addTearDown(container.dispose);
  }

  Future<void> pumpScreen(WidgetTester tester) async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: ReadRecordScreen()),
      ),
    );
    await tester.pump();
    await tester.pumpAndSettle();
  }

  Future<void> switchToDailyView(WidgetTester tester) async {
    await tester.tap(find.text('按天'));
    await tester.pumpAndSettle();
  }

  group('按天视图', () {
    testWidgets('私密书未授权：每日时长不出现，显示中性占位', (tester) async {
      await boot(books: [_privateBook], records: [_record(_privateBook)]);
      await pumpScreen(tester);
      await switchToDailyView(tester);

      expect(
        find.byKey(const ValueKey('readRecordDailyPrivacyMasked')),
        findsOneWidget,
      );
      expect(find.text('1小时'), findsNothing, reason: '每日时长聚合含私密书时长，不得展示');
      expect(find.textContaining(_today), findsNothing);
    });

    testWidgets('非私密书：正常显示每日时长（防过度脱敏）', (tester) async {
      await boot(books: [_publicBook], records: [_record(_publicBook)]);
      await pumpScreen(tester);
      await switchToDailyView(tester);

      expect(
        find.byKey(const ValueKey('readRecordDailyPrivacyMasked')),
        findsNothing,
      );
      expect(find.text('1小时'), findsWidgets, reason: '非私密记录不受脱敏影响');
    });

    testWidgets('私密书已获准（会话级解锁）：恢复显示时长', (tester) async {
      await boot(books: [_privateBook], records: [_record(_privateBook)]);
      await container.read(privacyNotifierProvider.notifier).ensureLoaded();
      await container
          .read(privacyNotifierProvider.notifier)
          .verifyForTarget('pw', bookUrl: _privateUrl);
      await pumpScreen(tester);
      await switchToDailyView(tester);

      expect(
        find.byKey(const ValueKey('readRecordDailyPrivacyMasked')),
        findsNothing,
      );
      expect(find.text('1小时'), findsWidgets);
    });
  });

  group('热力图', () {
    testWidgets('私密书未授权：按时长模式显示占位，不出现时长', (tester) async {
      await boot(books: [_privateBook], records: [_record(_privateBook)]);
      await pumpScreen(tester);

      // 展开热力图区块
      await tester.tap(find.text('阅读热力图'));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('readRecordHeatmapPrivacyMasked')),
        findsOneWidget,
      );
    });

    testWidgets('非私密书：热力图正常渲染（无脱敏占位）', (tester) async {
      await boot(books: [_publicBook], records: [_record(_publicBook)]);
      await pumpScreen(tester);

      await tester.tap(find.text('阅读热力图'));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('readRecordHeatmapPrivacyMasked')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('readRecordHeatmapPrivacyPending')),
        findsNothing,
      );
    });
  });

  group('成就卡', () {
    testWidgets('私密未授权：累计时长按已剔除口径并标注', (tester) async {
      await boot(books: [_privateBook], records: [_record(_privateBook)]);
      await pumpScreen(tester);

      expect(find.textContaining('不含未解锁内容'), findsOneWidget);
      expect(find.textContaining('1小时'), findsNothing, reason: '私密书时长不得计入累计');
    });

    testWidgets('非私密书：累计时长照常显示', (tester) async {
      await boot(books: [_publicBook], records: [_record(_publicBook)]);
      await pumpScreen(tester);

      expect(find.textContaining('不含未解锁内容'), findsNothing);
      expect(find.text('累计 1小时'), findsOneWidget);
    });
  });

  group('首帧竞态', () {
    testWidgets('快照未就绪：按天视图与成就卡只显示占位', (tester) async {
      await boot(books: [_privateBook], records: [_record(_privateBook)]);
      // 不等待 ensureLoaded，直接首帧渲染
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: ReadRecordScreen()),
        ),
      );
      // 首帧：策略/标记尚未加载，绝不得先渲染真实时长
      expect(find.textContaining('1小时'), findsNothing);
      expect(find.textContaining('已读 — 本'), findsOneWidget);

      await tester.pumpAndSettle();
      expect(
        find.textContaining('1小时'),
        findsNothing,
        reason: '就绪后仍因私密未授权而不展示',
      );
    });
  });

  group('纯函数判定', () {
    test('readStatsPrivacyReady：策略/标记未就绪为 false', () async {
      await boot(books: [_privateBook], records: [_record(_privateBook)]);
      // 未加载
      expect(
        readStatsPrivacyReady(
          container.read(privacyNotifierProvider),
          container.read(privacyContentProvider),
        ),
        isFalse,
      );
      await container.read(privacyNotifierProvider.notifier).ensureLoaded();
      final content = await container
          .read(privacyContentProvider.notifier)
          .ensureLoaded();
      expect(
        readStatsPrivacyReady(container.read(privacyNotifierProvider), content),
        isTrue,
      );
    });

    test('filterLockedRecords：私密未授权记录被剔除，非私密保留', () async {
      await boot(
        books: [_privateBook, _publicBook],
        records: [_record(_privateBook), _record(_publicBook)],
      );
      await container.read(privacyNotifierProvider.notifier).ensureLoaded();
      final content = await container
          .read(privacyContentProvider.notifier)
          .ensureLoaded();
      final privacy = container.read(privacyNotifierProvider);
      final records = [
        ReadRecordShow(
          bookName: _privateBook.name,
          author: _privateBook.author,
          physicalBookName: _privateBook.name,
        ),
        ReadRecordShow(
          bookName: _publicBook.name,
          author: _publicBook.author,
          physicalBookName: _publicBook.name,
        ),
      ];

      final visible = filterLockedRecords(records, privacy, content);
      expect(visible.map((r) => r.bookName), [_publicBook.name]);
      expect(hasLockedRecordsForStats(records, privacy, content), isTrue);
    });

    test('总开关关闭：不做任何剔除', () async {
      await boot(
        books: [_privateBook],
        records: [_record(_privateBook)],
        enabled: false,
      );
      await container.read(privacyNotifierProvider.notifier).ensureLoaded();
      final content = await container
          .read(privacyContentProvider.notifier)
          .ensureLoaded();
      final privacy = container.read(privacyNotifierProvider);
      final records = [
        ReadRecordShow(
          bookName: _privateBook.name,
          author: _privateBook.author,
          physicalBookName: _privateBook.name,
        ),
      ];
      expect(filterLockedRecords(records, privacy, content), records);
      expect(hasLockedRecordsForStats(records, privacy, content), isFalse);
    });
  });
}
