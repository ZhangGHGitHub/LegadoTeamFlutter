import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_legado/src/services/cache_service.dart';

import '../mocks/mocks.dart';

void main() {
  late CacheService service;
  late MockRustApi mockApi;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    mockApi = MockRustApi();
    service = CacheService(mockApi);
  });

  group('CacheService.formatSize 静态方法', () {
    test('小于 1KB 显示字节', () {
      expect(CacheService.formatSize(0), equals('0 B'));
      expect(CacheService.formatSize(512), equals('512 B'));
      expect(CacheService.formatSize(1023), equals('1023 B'));
    });

    test('1KB 到 1MB 之间显示 KB', () {
      expect(CacheService.formatSize(1024), equals('1.0 KB'));
      expect(CacheService.formatSize(1536), equals('1.5 KB'));
      expect(CacheService.formatSize(10240), equals('10.0 KB'));
      expect(CacheService.formatSize(1048575), equals('1024.0 KB'));
    });

    test('1MB 到 1GB 之间显示 MB', () {
      expect(CacheService.formatSize(1048576), equals('1.0 MB'));
      expect(CacheService.formatSize(5242880), equals('5.0 MB'));
      expect(CacheService.formatSize(104857600), equals('100.0 MB'));
    });

    test('大于等于 1GB 显示 GB', () {
      expect(CacheService.formatSize(1073741824), equals('1.00 GB'));
      expect(CacheService.formatSize(2684354560), equals('2.50 GB'));
    });

    test('边界值 1024 字节为 1.0 KB', () {
      expect(CacheService.formatSize(1024), equals('1.0 KB'));
    });

    test('边界值 1048576 字节为 1.0 MB', () {
      expect(CacheService.formatSize(1048576), equals('1.0 MB'));
    });
  });

  group('CacheService getCacheStats（mock API）', () {
    test('正确返回缓存统计', () async {
      when(() => mockApi.getCacheSize()).thenAnswer((_) async => 5242880);
      when(() => mockApi.getCacheBookCount()).thenAnswer((_) async => 10);
      when(() => mockApi.getCacheChapterCount()).thenAnswer((_) async => 200);

      final stats = await service.getCacheStats();

      expect(stats['totalSize'], equals(5242880));
      expect(stats['bookCount'], equals(10));
      expect(stats['chapterCount'], equals(200));
    });

    test('缓存为空时统计为 0', () async {
      when(() => mockApi.getCacheSize()).thenAnswer((_) async => 0);
      when(() => mockApi.getCacheBookCount()).thenAnswer((_) async => 0);
      when(() => mockApi.getCacheChapterCount()).thenAnswer((_) async => 0);

      final stats = await service.getCacheStats();

      expect(stats['totalSize'], equals(0));
      expect(stats['bookCount'], equals(0));
      expect(stats['chapterCount'], equals(0));
    });
  });

  group('CacheService clearCache（mock API）', () {
    test('清除全部缓存返回清除大小', () async {
      // 使用计数器模拟两次调用返回不同值
      var callCount = 0;
      when(() => mockApi.getCacheSize()).thenAnswer((_) async {
        callCount++;
        return callCount == 1 ? 1000 : 0;
      });
      when(() => mockApi.clearCache()).thenAnswer((_) async {});

      final cleared = await service.clearCache();

      expect(cleared, equals(1000));
      verify(() => mockApi.clearCache()).called(1);
    });

    test('按时间清除缓存', () async {
      final before = DateTime(2025, 1, 1);
      var callCount = 0;
      when(() => mockApi.getCacheSize()).thenAnswer((_) async {
        callCount++;
        return callCount == 1 ? 500 : 200;
      });
      when(() => mockApi.clearCacheBefore(any())).thenAnswer((_) async {});

      final cleared = await service.clearCache(before: before);

      expect(cleared, equals(300));
      verify(() => mockApi.clearCacheBefore(before.millisecondsSinceEpoch)).called(1);
    });

    test('清除后大小大于清除前时返回 0', () async {
      var callCount = 0;
      when(() => mockApi.getCacheSize()).thenAnswer((_) async {
        callCount++;
        return callCount == 1 ? 100 : 200; // 异常：清除后反而变大
      });
      when(() => mockApi.clearCache()).thenAnswer((_) async {});

      final cleared = await service.clearCache();

      expect(cleared, equals(0));
    });

    test('清除前后大小相同时返回 0', () async {
      when(() => mockApi.getCacheSize()).thenAnswer((_) async => 0);
      when(() => mockApi.clearCache()).thenAnswer((_) async {});

      final cleared = await service.clearCache();

      expect(cleared, equals(0));
    });
  });

  group('CacheService 自动过期天数（SharedPreferences）', () {
    test('默认自动过期天数为 0（永不过期）', () async {
      expect(await service.getAutoExpireDays(), equals(0));
    });

    test('设置并读取自动过期天数', () async {
      await service.setAutoExpireDays(30);
      expect(await service.getAutoExpireDays(), equals(30));
    });

    test('设置为 0 表示永不过期', () async {
      await service.setAutoExpireDays(30);
      await service.setAutoExpireDays(0);
      expect(await service.getAutoExpireDays(), equals(0));
    });

    test('设置较大天数', () async {
      await service.setAutoExpireDays(365);
      expect(await service.getAutoExpireDays(), equals(365));
    });
  });
}
