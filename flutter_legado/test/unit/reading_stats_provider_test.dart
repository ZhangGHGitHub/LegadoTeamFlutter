/// ReadingStatsProvider 单元测试
///
/// 覆盖：loadStats/setPeriod/totalBookDuration
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:flutter_legado/src/providers/reading_stats_provider.dart';
import 'package:flutter_legado/src/services/rust_api.dart';
import 'package:flutter_legado/src/bridge/ffi.dart';

import '../mocks/mocks.dart';

void main() {
  late ReadingStatsProvider provider;
  late MockRustApi mockApi;

  setUpAll(() {
    registerFallbacks();
  });

  setUp(() {
    mockApi = MockRustApi();
    provider = ReadingStatsProvider(mockApi);
  });

  /// 设置 mock 返回标准统计数据
  void setupMockStats() {
    when(() => mockApi.getTodayReadingStats()).thenAnswer(
      (_) async => const ReadingStatsToday(
        totalSeconds: 3600,
        bookCount: 3,
        durationSeconds: 1800,
        wordCount: 5000,
        readingSpeed: 2.5,
      ),
    );
    when(() => mockApi.getDailyReadingStats(days: any(named: 'days')))
        .thenAnswer((_) async => {'2025-01-01': 600, '2025-01-02': 900});
    when(() => mockApi.getBookReadingStats()).thenAnswer(
      (_) async => {'斗破苍穹': 1200, '完美世界': 800},
    );
    when(() => mockApi.getReadingHeatmap(days: any(named: 'days')))
        .thenAnswer((_) async => {'2025-01-01': 3, '2025-01-02': 5});
  }

  group('ReadingStatsProvider 初始状态', () {
    test('初始 today 为默认值', () {
      expect(provider.today.totalSeconds, equals(0));
      expect(provider.today.bookCount, equals(0));
    });

    test('初始 dailyStats 为空', () {
      expect(provider.dailyStats, isEmpty);
    });

    test('初始 bookStats 为空', () {
      expect(provider.bookStats, isEmpty);
    });

    test('初始 heatmap 为空', () {
      expect(provider.heatmap, isEmpty);
    });

    test('初始周期为 week', () {
      expect(provider.period, equals(StatsPeriod.week));
    });

    test('初始非加载状态', () {
      expect(provider.loading, isFalse);
    });

    test('初始无错误', () {
      expect(provider.error, isNull);
    });

    test('初始 totalBookDuration 为 0', () {
      expect(provider.totalBookDuration, equals(0));
    });
  });

  group('ReadingStatsProvider loadStats', () {
    test('成功加载全部统计数据', () async {
      setupMockStats();

      await provider.loadStats();

      expect(provider.today.totalSeconds, equals(3600));
      expect(provider.today.bookCount, equals(3));
      expect(provider.dailyStats.length, equals(2));
      expect(provider.bookStats.length, equals(2));
      expect(provider.heatmap.length, equals(2));
      expect(provider.loading, isFalse);
      expect(provider.error, isNull);
    });

    test('totalBookDuration 正确计算', () async {
      setupMockStats();

      await provider.loadStats();

      // 1200 + 800 = 2000
      expect(provider.totalBookDuration, equals(2000));
    });

    test('week 周期请求 7 天数据', () async {
      setupMockStats();

      await provider.loadStats();

      verify(() => mockApi.getDailyReadingStats(days: 7)).called(1);
    });

    test('加载失败设置 BridgeError', () async {
      when(() => mockApi.getTodayReadingStats())
          .thenThrow(const BridgeError(message: '统计加载失败'));
      when(() => mockApi.getDailyReadingStats(days: any(named: 'days')))
          .thenAnswer((_) async => {});
      when(() => mockApi.getBookReadingStats()).thenAnswer((_) async => {});
      when(() => mockApi.getReadingHeatmap(days: any(named: 'days')))
          .thenAnswer((_) async => {});

      await provider.loadStats();

      expect(provider.error, equals('统计加载失败'));
      expect(provider.loading, isFalse);
    });

    test('加载失败设置普通异常', () async {
      when(() => mockApi.getTodayReadingStats()).thenThrow(Exception('网络'));
      when(() => mockApi.getDailyReadingStats(days: any(named: 'days')))
          .thenAnswer((_) async => {});
      when(() => mockApi.getBookReadingStats()).thenAnswer((_) async => {});
      when(() => mockApi.getReadingHeatmap(days: any(named: 'days')))
          .thenAnswer((_) async => {});

      await provider.loadStats();

      expect(provider.error, contains('网络'));
    });

    test('loadStats 触发通知', () async {
      setupMockStats();
      var notifyCount = 0;
      provider.addListener(() => notifyCount++);

      await provider.loadStats();

      expect(notifyCount, greaterThanOrEqualTo(2));
    });
  });

  group('ReadingStatsProvider setPeriod', () {
    test('切换到 month 请求 30 天数据', () async {
      setupMockStats();

      provider.setPeriod(StatsPeriod.month);
      // 等待异步 loadStats 完成
      await Future.delayed(Duration.zero);

      expect(provider.period, equals(StatsPeriod.month));
      verify(() => mockApi.getDailyReadingStats(days: 30)).called(1);
    });

    test('设置相同周期不重新加载', () async {
      setupMockStats();

      // 初始就是 week，再设置 week
      provider.setPeriod(StatsPeriod.week);
      await Future.delayed(Duration.zero);

      // 不应该调用任何 API（因为没有触发 loadStats）
      verifyNever(() => mockApi.getTodayReadingStats());
    });
  });

  group('StatsPeriod 枚举', () {
    test('包含 week 和 month', () {
      expect(StatsPeriod.values, containsAll([StatsPeriod.week, StatsPeriod.month]));
    });
  });
}
