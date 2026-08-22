/// BackupService 单元测试
///
/// 覆盖：exportBooks/exportSources/exportSelectedSources/
///       exportAllSourcesFormatted/importSources/fullBackup/
///       parseBackup/restoreSourcesFromBackup/serializeSources
library;
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:flutter_legado/src/services/backup_service.dart';
import 'package:flutter_legado/src/models/models.dart';

import '../mocks/mocks.dart';

void main() {
  late BackupService service;
  late MockRustApi mockApi;

  setUpAll(() {
    registerFallbacks();
  });

  setUp(() {
    mockApi = MockRustApi();
    service = BackupService(mockApi);
  });

  group('BackupService exportBooks', () {
    test('导出书架数据为 JSON 数组', () async {
      when(() => mockApi.getBooks()).thenAnswer((_) async => [
            const Book(bookUrl: 'http://b1.com', name: '书1'),
            const Book(bookUrl: 'http://b2.com', name: '书2'),
          ]);

      final result = await service.exportBooks();
      final decoded = jsonDecode(result) as List;

      expect(decoded.length, equals(2));
      expect(decoded[0]['name'], equals('书1'));
    });

    test('空书架导出为空数组', () async {
      when(() => mockApi.getBooks()).thenAnswer((_) async => []);

      final result = await service.exportBooks();
      expect(result, equals('[]'));
    });
  });

  group('BackupService exportSources', () {
    test('导出书源数据', () async {
      when(() => mockApi.exportBookSources())
          .thenAnswer((_) async => '[{"bookSourceUrl":"http://s.com"}]');

      final result = await service.exportSources();
      expect(result, contains('bookSourceUrl'));
    });
  });

  group('BackupService exportSelectedSources', () {
    test('导出选中的书源', () async {
      when(() => mockApi.getBookSources()).thenAnswer((_) async => [
            const BookSource(bookSourceUrl: 'http://s1.com', bookSourceName: '源1'),
            const BookSource(bookSourceUrl: 'http://s2.com', bookSourceName: '源2'),
            const BookSource(bookSourceUrl: 'http://s3.com', bookSourceName: '源3'),
          ]);

      final result = await service.exportSelectedSources(
        ['http://s1.com', 'http://s3.com'],
      );
      final decoded = jsonDecode(result) as List;

      expect(decoded.length, equals(2));
    });

    test('选中为空时返回空数组', () async {
      when(() => mockApi.getBookSources()).thenAnswer((_) async => [
            const BookSource(bookSourceUrl: 'http://s1.com', bookSourceName: '源1'),
          ]);

      final result = await service.exportSelectedSources([]);
      expect(result, equals('[]'));
    });

    test('选中的 URL 不存在时返回空数组', () async {
      when(() => mockApi.getBookSources()).thenAnswer((_) async => [
            const BookSource(bookSourceUrl: 'http://s1.com', bookSourceName: '源1'),
          ]);

      final result = await service.exportSelectedSources(['http://nope.com']);
      expect(result, equals('[]'));
    });
  });

  group('BackupService exportAllSourcesFormatted', () {
    test('导出全部书源为格式化 JSON', () async {
      when(() => mockApi.getBookSources()).thenAnswer((_) async => [
            const BookSource(bookSourceUrl: 'http://s1.com', bookSourceName: '源1'),
          ]);

      final result = await service.exportAllSourcesFormatted();

      // 格式化 JSON 包含缩进
      expect(result, contains('  '));
      expect(result, contains('源1'));
    });
  });

  group('BackupService importSources', () {
    test('导入书源返回数量', () async {
      when(() => mockApi.importBookSources(any())).thenAnswer((_) async => 5);

      final count = await service.importSources('[{}]');
      expect(count, equals(5));
    });
  });

  group('BackupService fullBackup', () {
    test('完整备份包含版本和时间戳', () async {
      when(() => mockApi.getBooks()).thenAnswer((_) async => []);
      when(() => mockApi.exportBookSources()).thenAnswer((_) async => '[]');

      final result = await service.fullBackup();
      final decoded = jsonDecode(result) as Map<String, dynamic>;

      expect(decoded['version'], equals(1));
      expect(decoded['timestamp'], isNotNull);
      expect(decoded.containsKey('books'), isTrue);
      expect(decoded.containsKey('sources'), isTrue);
    });
  });

  group('BackupService parseBackup', () {
    test('解析备份 JSON', () async {
      final backupJson = jsonEncode({
        'version': 1,
        'timestamp': '2025-01-01T00:00:00',
        'books': '[]',
        'sources': '[]',
      });

      final data = await service.parseBackup(backupJson);

      expect(data['version'], equals(1));
      expect(data['timestamp'], equals('2025-01-01T00:00:00'));
    });
  });

  group('BackupService restoreSourcesFromBackup', () {
    test('从备份恢复书源', () async {
      when(() => mockApi.importBookSources(any())).thenAnswer((_) async => 3);

      final backupJson = jsonEncode({
        'version': 1,
        'sources': '[{"bookSourceUrl":"http://s.com"}]',
      });

      final count = await service.restoreSourcesFromBackup(backupJson);
      expect(count, equals(3));
    });

    test('备份中无 sources 字段使用空数组', () async {
      when(() => mockApi.importBookSources(any())).thenAnswer((_) async => 0);

      final backupJson = jsonEncode({'version': 1});

      final count = await service.restoreSourcesFromBackup(backupJson);
      expect(count, equals(0));
    });
  });

  group('BackupService serializeSources', () {
    test('序列化书源列表为格式化 JSON', () {
      final sources = [
        const BookSource(bookSourceUrl: 'http://s1.com', bookSourceName: '源1'),
        const BookSource(bookSourceUrl: 'http://s2.com', bookSourceName: '源2'),
      ];

      final result = service.serializeSources(sources);
      final decoded = jsonDecode(result) as List;

      expect(decoded.length, equals(2));
      // 格式化输出包含缩进
      expect(result, contains('  '));
    });

    test('空列表序列化为空数组', () {
      final result = service.serializeSources([]);
      expect(result, equals('[]'));
    });
  });
}
