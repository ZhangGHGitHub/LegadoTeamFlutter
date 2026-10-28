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
    test('解析 snake_case 字段（read_time）与批20 扩展字段', () {
      final r = RssReadRecordRow.fromJson({
        'origin': 'https://rss.example.com',
        'title': '文章一',
        'link': 'https://rss.example.com/1',
        'read_time': 1750000000000,
        'type': 1,
        'sort': '图片分类',
        'image': 'https://img.example.com/1.jpg',
        'pubDate': '2026-10-27',
        'durPos': 42,
      });
      expect(r.origin, equals('https://rss.example.com'));
      expect(r.title, equals('文章一'));
      expect(r.link, equals('https://rss.example.com/1'));
      expect(r.readTime, equals(1750000000000));
      expect(r.type, equals(1));
      expect(r.sort, equals('图片分类'));
      expect(r.image, equals('https://img.example.com/1.jpg'));
      expect(r.pubDate, equals('2026-10-27'));
      expect(r.durPos, equals(42));
    });

    test('旧数据缺省字段兜底（type=0 / sort 空 / image+pubDate null / durPos=0）', () {
      final r = RssReadRecordRow.fromJson({
        'origin': 'https://rss.example.com',
        'title': '旧文章',
        'link': 'https://rss.example.com/old',
        'read_time': 100,
      });
      expect(r.type, isZero);
      expect(r.sort, isEmpty);
      expect(r.image, isNull);
      expect(r.pubDate, isNull);
      expect(r.durPos, isZero);
    });

    test('缺省字段兜底', () {
      const r = RssReadRecordRow();
      expect(r.origin, isEmpty);
      expect(r.title, isEmpty);
      expect(r.link, isNull);
      expect(r.readTime, isZero);
      expect(r.type, isZero);
      expect(r.sort, isEmpty);
      expect(r.image, isNull);
      expect(r.pubDate, isNull);
      expect(r.durPos, isZero);
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

      when(() => mockApi.rssClearReadRecords(origin: any(named: 'origin')))
          .thenAnswer((_) async {});
      when(() => mockApi.rssListReadRecords(any()))
          .thenAnswer((_) async => []);

      await readNotifier().clear();

      final state = readState();
      expect(state.isClearing, isFalse);
      expect(state.records, isEmpty);
      verify(() => mockApi.rssClearReadRecords(origin: any(named: 'origin')))
          .called(1);
    });

    test('clear(origin) 按源清空并按同范围重新拉取（批29）', () async {
      const origin = 'https://rss.example.com';
      when(() => mockApi.rssListReadRecordsByOrigin(origin, any()))
          .thenAnswer((_) async => [
                {'origin': origin, 'title': '文章1', 'read_time': 100},
              ]);
      await readNotifier().load(origin: origin);
      expect(readState().records.length, equals(1));

      when(() => mockApi.rssClearReadRecords(origin: any(named: 'origin')))
          .thenAnswer((_) async {});
      when(() => mockApi.rssListReadRecordsByOrigin(origin, any()))
          .thenAnswer((_) async => []);

      await readNotifier().clear(origin: origin);

      expect(readState().records, isEmpty);
      verify(
        () => mockApi.rssClearReadRecords(origin: origin),
      ).called(1);
      // 重新拉取仍需按 origin 过滤（不得退化为全局列表）：
      // 首次 load + 清空后 reload = 2 次
      verify(() => mockApi.rssListReadRecordsByOrigin(origin, any())).called(2);
      verifyNever(() => mockApi.rssListReadRecords(any()));
    });

    test('clear 异常时兜底并记录 error', () async {
      when(() => mockApi.rssClearReadRecords(origin: any(named: 'origin')))
          .thenThrow(Exception('ffi'));

      await readNotifier().clear();

      final state = readState();
      expect(state.isClearing, isFalse);
      expect(state.error, isNotNull);
      verifyNever(() => mockApi.rssListReadRecords(any()));
    });
  });
}
