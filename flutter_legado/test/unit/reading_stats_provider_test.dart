/// ReadingStatsNotifier 单元测试
///
/// 覆盖：初始状态/loadStats/setPeriod/totalBookDuration/StatsPeriod
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:flutter_legado/src/providers/reading_stats/reading_stats_notifier.dart';
import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/bridge/ffi.dart';
import 'package:flutter_legado/src/services/rust_api.dart';

import '../mocks/mocks.dart';

void main() {
  late MockRustApi mockApi;
  late ProviderContainer container;

  setUpAll(() {
    registerFallbacks();
  });

  setUp(() {
    mockApi = MockRustApi();
    container = ProviderContainer(
      overrides: [bookApiProvider.overrideWithValue(mockApi)],
    );
    addTearDown(container.dispose);
  });

  ReadingStatsState readState() => container.read(readingStatsNotifierProvider);
  ReadingStatsNotifier readNotifier() =>
      container.read(readingStatsNotifierProvider.notifier);

  /// 抽空事件队列，等待未 await 的异步 loadStats 完成
  Future<void> pump() async {
    for (var i = 0; i < 5; i++) {
      await Future.delayed(Duration.zero);
    }
  }

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

  group('ReadingStatsNotifier 初始状态', () {
    test('初始 today 为默认值', () {
      expect(readState().today.totalSeconds, equals(0));
      expect(readState().today.bookCount, equals(0));
    });

    test('初始 dailyStats 为空', () {
      expect(readState().dailyStats, isEmpty);
    });

    test('初始 bookStats 为空', () {
      expect(readState().bookStats, isEmpty);
    });

    test('初始 heatmap 为空', () {
      expect(readState().heatmap, isEmpty);
    });

    test('初始周期为 week', () {
      expect(readState().period, equals(StatsPeriod.week));
    });

    test('初始非加载状态', () {
      expect(readState().loading, isFalse);
    });

    test('初始无错误', () {
      expect(readState().error, isNull);
    });

    test('初始 totalBookDuration 为 0', () {
      expect(readState().totalBookDuration, equals(0));
    });
  });

  group('ReadingStatsNotifier loadStats', () {
    test('成功加载全部统计数据', () async {
      setupMockStats();

      await readNotifier().loadStats();

      expect(readState().today.totalSeconds, equals(3600));
      expect(readState().today.bookCount, equals(3));
      expect(readState().dailyStats.length, equals(2));
      expect(readState().bookStats.length, equals(2));
      expect(readState().heatmap.length, equals(2));
      expect(readState().loading, isFalse);
      expect(readState().error, isNull);
    });

    test('totalBookDuration 正确计算', () async {
      setupMockStats();

      await readNotifier().loadStats();

      // 1200 + 800 = 2000
      expect(readState().totalBookDuration, equals(2000));
    });

    test('week 周期请求 7 天数据', () async {
      setupMockStats();

      await readNotifier().loadStats();

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

      await readNotifier().loadStats();

      expect(readState().error, equals('统计加载失败'));
      expect(readState().loading, isFalse);
    });

    test('加载失败设置普通异常', () async {
      when(() => mockApi.getTodayReadingStats()).thenThrow(Exception('网络'));
      when(() => mockApi.getDailyReadingStats(days: any(named: 'days')))
          .thenAnswer((_) async => {});
      when(() => mockApi.getBookReadingStats()).thenAnswer((_) async => {});
      when(() => mockApi.getReadingHeatmap(days: any(named: 'days')))
          .thenAnswer((_) async => {});

      await readNotifier().loadStats();

      expect(readState().error, contains('网络'));
    });

    test('loadStats 触发状态变更通知', () async {
      setupMockStats();
      var notifyCount = 0;
      // NotifierProvider 仅在 state 实际变化时通知：
      // loadStats 先置 loading=true，再写入数据并 loading=false，共两次真实变更
      container.listen(readingStatsNotifierProvider, (_, __) => notifyCount++);

      await readNotifier().loadStats();

      expect(notifyCount, greaterThanOrEqualTo(2));
    });
  });

  group('ReadingStatsNotifier setPeriod', () {
    test('切换到 month 请求 30 天数据', () async {
      setupMockStats();

      readNotifier().setPeriod(StatsPeriod.month);
      // 等待异步 loadStats 完成
      await pump();

      expect(readState().period, equals(StatsPeriod.month));
      verify(() => mockApi.getDailyReadingStats(days: 30)).called(1);
    });

    test('设置相同周期不重新加载', () async {
      setupMockStats();

      // 初始就是 week，再设置 week
      readNotifier().setPeriod(StatsPeriod.week);
      await pump();

      // 不应该调用任何 API（因为没有触发 loadStats）
      verifyNever(() => mockApi.getTodayReadingStats());
    });
  });

  group('StatsPeriod 枚举', () {
    test('包含 week 和 month', () {
      expect(StatsPeriod.values,
          containsAll([StatsPeriod.week, StatsPeriod.month]));
    });
  });
}
