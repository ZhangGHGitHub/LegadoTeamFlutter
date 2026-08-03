import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/providers/rss_history/rss_history_notifier.dart';

import '../mocks/mocks.dart';

void main() {
  group('RssReadRecordRow.fromJson', () {
    test('解析 snake_case 字段（read_time）', () {
      final r = RssReadRecordRow.fromJson({
        'origin': 'https://rss.example.com',
        'title': '文章一',
        'link': 'https://rss.example.com/1',
        'read_time': 1750000000000,
      });
      expect(r.origin, equals('https://rss.example.com'));
      expect(r.title, equals('文章一'));
      expect(r.link, equals('https://rss.example.com/1'));
      expect(r.readTime, equals(1750000000000));
    });

    test('缺省字段兜底', () {
      const r = RssReadRecordRow();
      expect(r.origin, isEmpty);
      expect(r.title, isEmpty);
      expect(r.link, isNull);
      expect(r.readTime, isZero);
    });
  });

  group('RssHistoryNotifier', () {
    late MockRustApi mockApi;
    late ProviderContainer container;

    setUpAll(registerFallbacks);

    setUp(() {
      mockApi = MockRustApi();
      container = ProviderContainer(
        overrides: [bookApiProvider.overrideWithValue(mockApi)],
      );
      addTearDown(container.dispose);
    });

    RssHistoryState readState() =>
        container.read(rssHistoryNotifierProvider);
    RssHistoryNotifier readNotifier() =>
        container.read(rssHistoryNotifierProvider.notifier);

    test('初始状态为空', () {
      final state = readState();
      expect(state.records, isEmpty);
      expect(state.isLoading, isFalse);
      expect(state.error, isNull);
    });

    test('load 解析已读记录（透传 limit）', () async {
      when(() => mockApi.rssListReadRecords(any())).thenAnswer((_) async => [
            {'origin': 'https://a.com', 'title': '文章1', 'read_time': 100},
            {'origin': 'https://b.com', 'title': '文章2', 'read_time': 200},
          ]);

      await readNotifier().load(limit: 50);

      final state = readState();
      expect(state.isLoading, isFalse);
      expect(state.records.length, equals(2));
      expect(state.records.first.title, equals('文章1'));
      expect(state.records[1].readTime, equals(200));
      verify(() => mockApi.rssListReadRecords(50)).called(1);
    });

    test('load 异常时兜底并记录 error', () async {
      when(() => mockApi.rssListReadRecords(any()))
          .thenThrow(Exception('ffi'));

      await readNotifier().load();

      final state = readState();
      expect(state.isLoading, isFalse);
      expect(state.records, isEmpty);
      expect(state.error, isNotNull);
    });

    test('clear 清空后重新拉取列表', () async {
      when(() => mockApi.rssListReadRecords(any())).thenAnswer((_) async => [
            {'origin': 'https://a.com', 'title': '文章1', 'read_time': 100},
          ]);
      await readNotifier().load();
      expect(readState().records.length, equals(1));

      when(() => mockApi.rssClearReadRecords()).thenAnswer((_) async {});
      when(() => mockApi.rssListReadRecords(any()))
          .thenAnswer((_) async => []);

      await readNotifier().clear();

      final state = readState();
      expect(state.isClearing, isFalse);
      expect(state.records, isEmpty);
      verify(() => mockApi.rssClearReadRecords()).called(1);
    });

    test('clear 异常时兜底并记录 error', () async {
      when(() => mockApi.rssClearReadRecords()).thenThrow(Exception('ffi'));

      await readNotifier().clear();

      final state = readState();
      expect(state.isClearing, isFalse);
      expect(state.error, isNotNull);
      verifyNever(() => mockApi.rssListReadRecords(any()));
    });
  });
}
