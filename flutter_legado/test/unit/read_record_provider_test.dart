/// ReadRecordNotifier 单元测试
///
/// 覆盖：加载/搜索/排序/删除/总时长（对齐原版 ReadRecordActivity）
library;
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/providers/read_record/read_record_notifier.dart';
import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/screens/read_record_screen.dart';

import '../mocks/mocks.dart';

void main() {
  late MockRustApi mockApi;
  late ProviderContainer container;

  setUpAll(() {
    registerFallbacks();
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    mockApi = MockRustApi();
    container = ProviderContainer(
      overrides: [bookApiProvider.overrideWithValue(mockApi)],
    );
    addTearDown(container.dispose);
  });

  ReadRecordState readState() => container.read(readRecordNotifierProvider);
  ReadRecordNotifier readNotifier() =>
      container.read(readRecordNotifierProvider.notifier);

  void stubRecords(List<ReadRecord> records) {
    when(() => mockApi.getReadRecords()).thenAnswer((_) async => records);
  }

  group('formatDuring', () {
    test('0 与负数显示 0秒', () {
      expect(formatDuring(0), '0秒');
      expect(formatDuring(-1), '0秒');
    });

    test('组合天时分秒', () {
      // 1天 + 2小时 + 3分钟 + 4秒
      final ms = (1 * 86400 + 2 * 3600 + 3 * 60 + 4) * 1000;
      expect(formatDuring(ms), '1天2小时3分钟4秒');
    });
  });

  group('ReadRecordNotifier', () {
    test('load 汇总总时长并按书名排序', () async {
      stubRecords([
        const ReadRecord(bookName: 'BookB', readTime: 3000, lastRead: 200),
        const ReadRecord(bookName: 'BookA', readTime: 5000, lastRead: 100),
      ]);

      await readNotifier().load();

      expect(readState().isLoading, isFalse);
      expect(readState().totalReadTimeMs, 8000);
      expect(readState().records.map((e) => e.bookName), ['BookA', 'BookB']);
    });

    test('搜索过滤书名', () async {
      stubRecords([
        const ReadRecord(bookName: '斗破苍穹', readTime: 1000),
        const ReadRecord(bookName: '完美世界', readTime: 2000),
      ]);
      await readNotifier().load();
      readNotifier().setSearchQuery('完美');
      expect(readState().records, hasLength(1));
      expect(readState().records.first.bookName, '完美世界');
    });

    test('按阅读时长排序', () async {
      stubRecords([
        const ReadRecord(bookName: '短', readTime: 100),
        const ReadRecord(bookName: '长', readTime: 9999),
      ]);
      await readNotifier().load();
      await readNotifier().setSortMode(ReadRecordSortMode.readTime);
      expect(readState().records.first.bookName, '长');
    });

    test('删除后重新加载', () async {
      stubRecords([
        const ReadRecord(bookName: 'A', readTime: 1),
        const ReadRecord(bookName: 'B', readTime: 2),
      ]);
      when(() => mockApi.deleteReadRecord(any())).thenAnswer((_) async {});
      await readNotifier().load();

      when(() => mockApi.getReadRecords()).thenAnswer(
        (_) async => [const ReadRecord(bookName: 'B', readTime: 2)],
      );
      await readNotifier().deleteByName('A');
      verify(() => mockApi.deleteReadRecord('A')).called(1);
      expect(readState().records.map((e) => e.bookName), ['B']);
      expect(readState().totalReadTimeMs, 2);
    });
  });
}
