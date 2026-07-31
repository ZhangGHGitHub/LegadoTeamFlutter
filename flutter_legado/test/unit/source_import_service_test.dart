/// SourceImportService 单元测试
///
/// 覆盖：importFromJson/validateSource/ImportResult
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:flutter_legado/src/services/source_import_service.dart';

import '../mocks/mocks.dart';

void main() {
  late SourceImportService service;
  late MockRustApi mockApi;

  setUpAll(() {
    registerFallbacks();
  });

  setUp(() {
    mockApi = MockRustApi();
    service = SourceImportService(mockApi);
  });

  group('ImportResult 模型', () {
    test('hasErrors 有错误时返回 true', () {
      const result = ImportResult(
        total: 1, success: 0, failed: 1, skipped: 0,
        errors: ['失败'],
      );
      expect(result.hasErrors, isTrue);
    });

    test('hasErrors 无错误时返回 false', () {
      const result = ImportResult(
        total: 2, success: 2, failed: 0, skipped: 0,
        errors: [],
      );
      expect(result.hasErrors, isFalse);
    });

    test('summary 包含成功数', () {
      const result = ImportResult(
        total: 5, success: 3, failed: 1, skipped: 1,
        errors: ['err'],
      );
      final summary = result.summary;
      expect(summary, contains('共 5 个书源'));
      expect(summary, contains('成功 3'));
      expect(summary, contains('失败 1'));
      expect(summary, contains('跳过 1'));
    });

    test('summary 只有成功时不显示失败和跳过', () {
      const result = ImportResult(
        total: 2, success: 2, failed: 0, skipped: 0,
        errors: [],
      );
      final summary = result.summary;
      expect(summary, contains('成功 2'));
      expect(summary, isNot(contains('失败')));
      expect(summary, isNot(contains('跳过')));
    });
  });

  group('SourceImportService validateSource', () {
    test('有效书源通过校验', () {
      final errors = service.validateSource({
        'bookSourceUrl': 'http://source.com',
        'bookSourceName': '测试源',
      });
      expect(errors, isEmpty);
    });

    test('缺少 bookSourceUrl 报错', () {
      final errors = service.validateSource({
        'bookSourceName': '测试源',
      });
      expect(errors, contains('缺少 bookSourceUrl'));
    });

    test('bookSourceUrl 为空字符串报错', () {
      final errors = service.validateSource({
        'bookSourceUrl': '',
        'bookSourceName': '测试源',
      });
      expect(errors, contains('缺少 bookSourceUrl'));
    });

    test('缺少 bookSourceName 报错', () {
      final errors = service.validateSource({
        'bookSourceUrl': 'http://source.com',
      });
      expect(errors, contains('缺少 bookSourceName'));
    });

    test('bookSourceName 为空字符串报错', () {
      final errors = service.validateSource({
        'bookSourceUrl': 'http://source.com',
        'bookSourceName': '',
      });
      expect(errors, contains('缺少 bookSourceName'));
    });

    test('同时缺少两个必要字段报两个错', () {
      final errors = service.validateSource({});
      expect(errors.length, equals(2));
    });
  });

  group('SourceImportService importFromJson', () {
    test('导入有效书源数组成功', () async {
      when(() => mockApi.importBookSources(any())).thenAnswer((_) async => 1);

      final jsonStr = '''
      [
        {"bookSourceUrl": "http://s1.com", "bookSourceName": "源1"},
        {"bookSourceUrl": "http://s2.com", "bookSourceName": "源2"}
      ]
      ''';
      final result = await service.importFromJson(jsonStr);

      expect(result.total, equals(2));
      expect(result.success, equals(2));
      expect(result.failed, equals(0));
      expect(result.skipped, equals(0));
      expect(result.hasErrors, isFalse);
    });

    test('导入单个书源对象成功', () async {
      when(() => mockApi.importBookSources(any())).thenAnswer((_) async => 1);

      final jsonStr = '{"bookSourceUrl": "http://s1.com", "bookSourceName": "源1"}';
      final result = await service.importFromJson(jsonStr);

      expect(result.total, equals(1));
      expect(result.success, equals(1));
    });

    test('无效 JSON 格式返回错误', () async {
      final result = await service.importFromJson('not json');

      expect(result.total, equals(0));
      expect(result.hasErrors, isTrue);
      expect(result.errors[0], contains('JSON 解析错误'));
    });

    test('JSON 为非对象/数组类型返回错误', () async {
      final result = await service.importFromJson('"just a string"');

      expect(result.total, equals(0));
      expect(result.errors[0], contains('无效的 JSON 格式'));
    });

    test('数组中含非对象项标记为失败', () async {
      when(() => mockApi.importBookSources(any())).thenAnswer((_) async => 1);

      final jsonStr = '[{"bookSourceUrl": "http://s.com", "bookSourceName": "源"}, "invalid"]';
      final result = await service.importFromJson(jsonStr);

      expect(result.total, equals(2));
      expect(result.success, equals(1));
      expect(result.failed, equals(1));
    });

    test('校验不通过的书源标记为跳过', () async {
      final jsonStr = '[{"bookSourceUrl": "", "bookSourceName": ""}]';
      final result = await service.importFromJson(jsonStr);

      expect(result.total, equals(1));
      expect(result.skipped, equals(1));
      expect(result.success, equals(0));
    });

    test('API 调用失败标记为失败', () async {
      when(() => mockApi.importBookSources(any())).thenThrow(Exception('API错误'));

      final jsonStr = '[{"bookSourceUrl": "http://s.com", "bookSourceName": "源"}]';
      final result = await service.importFromJson(jsonStr);

      expect(result.total, equals(1));
      expect(result.failed, equals(1));
      expect(result.errors[0], contains('API错误'));
    });
  });

  group('SourceImportService importFromFile', () {
    test('文件不存在返回错误', () async {
      final result = await service.importFromFile('/nonexist/path.json');

      expect(result.total, equals(0));
      expect(result.hasErrors, isTrue);
      expect(result.errors[0], contains('文件不存在'));
    });
  });

  group('TimeoutException', () {
    test('toString 返回消息', () {
      const e = TimeoutException('超时了');
      expect(e.toString(), equals('超时了'));
    });
  });
}
