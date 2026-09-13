// [书源作用域 | 2026-09-13] scopeSource 全链路 Dart 侧测试
//
// 覆盖三层（对应任务要求「模型序列化 / 服务透传 / 导入挂钩单测」）：
// 1. 模型序列化：ReplaceRule.fromJson/toJson 的 scopeSource 字段
//    （JSON key 'scopeSource'，缺省 false，显式 true 往返）。
// 2. 服务透传：MockBookApi.applyReplaceRulesToSource 原样返回输入并
//    累计调用计数（applyReplaceRulesToSourceCalls），供导入挂钩测试断言；
//    addReplaceRule/updateReplaceRule 保留 scopeSource 字段（整对象替换语义）。
// 3. 导入挂钩：SourceImportService.importFromJson（服务统一入口，
//    importFromUrl/importFromFile 委托于此，一并覆盖）与
//    SourceNotifier.importSources（原始 JSON 直传入口）两入口：
//    - 有命中：交 importBookSources 的 JSON 已被替换（模拟规则命中）；
//    - 无命中：applyReplaceRulesToSource 返回原文 → 导入原文；
//    - 替换抛异常：保持原文且导入不中断（对齐原版语义）。
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/services/mock_book_api.dart';
import 'package:flutter_legado/src/services/source_import_service.dart';
import 'package:flutter_legado/src/providers/source/source_notifier.dart';
import 'package:flutter_legado/src/providers/providers.dart';

import '../mocks/mocks.dart';

/// 构造一段含可被替换 token 的书源 JSON（单对象）
String _sourceJson({String token = '旧站', String name = '起点', String url = 'https://www.qidian.com'}) =>
    jsonEncode({
      'bookSourceUrl': url,
      'bookSourceName': name,
      'ruleSearch': {'searchUrl': 'https://www.{$token}/search/{{key}}'},
    });

void main() {
  // ============================================================
  // 1. 模型序列化
  // ============================================================
  group('ReplaceRule 模型序列化 scopeSource', () {
    test('缺省 scopeSource 为 false', () {
      const rule = ReplaceRule(name: 'r', pattern: 'a', replacement: 'b');
      expect(rule.scopeSource, isFalse);
    });

    test('显式 true 经 toJson → fromJson 往返保持', () {
      final rule = const ReplaceRule(
        name: 'r',
        pattern: 'a',
        replacement: 'b',
        scopeSource: true,
      );
      final json = rule.toJson();
      // JSON key 为 camelCase 'scopeSource'（对齐原版字段名）
      expect(json['scopeSource'], isTrue);
      final restored = ReplaceRule.fromJson(json);
      expect(restored.scopeSource, isTrue);
    });

    test('fromJson 缺失 scopeSource 键回退默认 false', () {
      final rule = ReplaceRule.fromJson(const {
        'name': 'r',
        'pattern': 'a',
        'replacement': 'b',
      });
      expect(rule.scopeSource, isFalse);
    });

    test('fromJson 显式 false 保持 false（区别于缺省）', () {
      final rule = ReplaceRule.fromJson(const {
        'name': 'r',
        'pattern': 'a',
        'replacement': 'b',
        'scopeSource': false,
      });
      expect(rule.scopeSource, isFalse);
    });
  });

  // ============================================================
  // 2. 服务透传（MockBookApi）
  // ============================================================
  group('MockBookApi.applyReplaceRulesToSource 透传', () {
    late MockBookApi api;

    setUp(() {
      api = MockBookApi();
    });

    test('原样返回输入 JSON 并累计调用计数', () async {
      final input = _sourceJson();
      final result =
          await api.applyReplaceRulesToSource(input, '起点', 'https://www.qidian.com');
      // Mock 不实现真实替换引擎：原样返回（对齐契约「任何错误原样返回」保守语义）
      expect(result, input);
      expect(api.applyReplaceRulesToSourceCalls, 1);

      // 再次调用计数累加
      await api.applyReplaceRulesToSource(input, 'A', 'http://a');
      expect(api.applyReplaceRulesToSourceCalls, 2);
    });

    test('addReplaceRule 保留 scopeSource 字段（整对象语义）', () async {
      final rule = ReplaceRule(
        name: 'ss',
        pattern: 'a',
        replacement: 'b',
        scopeSource: true,
      );
      final added = await api.addReplaceRule(rule);
      expect(added.scopeSource, isTrue);
      final list = await api.getReplaceRules();
      expect(list.single.scopeSource, isTrue);
    });

    test('updateReplaceRule 保留 scopeSource 字段（整对象替换语义）', () async {
      final rule = ReplaceRule(
        name: 'ss',
        pattern: 'a',
        replacement: 'b',
        scopeSource: true,
      );
      final added = await api.addReplaceRule(rule);
      // 以「完整对象」更新（读自 API 后 copyWith），scopeSource 保持 true
      final updated = added.copyWith(scopeSource: true);
      await api.updateReplaceRule(updated);
      final list = await api.getReplaceRules();
      expect(list.single.scopeSource, isTrue);
    });
  });

  // ============================================================
  // 3. 导入挂钩 — SourceImportService.importFromJson（服务统一入口）
  //    importFromUrl / importFromFile 委托于此，一并覆盖
  // ============================================================
  group('SourceImportService.importFromJson 导入挂钩', () {
    late SourceImportService service;
    late MockRustApi mockApi;

    setUpAll(registerFallbacks);

    setUp(() {
      mockApi = MockRustApi();
      service = SourceImportService(mockApi);
    });

    test('有命中：交 importBookSources 的 JSON 已被替换', () async {
      // 模拟规则命中：把 token 替换掉（Rust 侧真实行为，此处 mock 模拟）
      final applied = _sourceJson(token: '旧站').replaceAll('旧站', '新站');
      when(() => mockApi.applyReplaceRulesToSource(any(), any(), any()))
          .thenAnswer((_) async => applied);
      // 捕获实际交给 importBookSources 的 payload
      String? importedPayload;
      when(() => mockApi.importBookSources(any())).thenAnswer((inv) async {
        importedPayload = inv.positionalArguments.first as String;
        return 1;
      });

      await service.importFromJson(_sourceJson(token: '旧站', name: '起点'));

      // 导入未中断且成功
      expect(importedPayload, isNotNull);
      // 关键断言：payload 是「替换后」的 JSON（含 新站、不含 旧站）
      expect(importedPayload, contains('新站'));
      expect(importedPayload, isNot(contains('旧站')));
      // 且确实调用了 applyReplaceRulesToSource（挂钩生效）
      verify(() => mockApi.applyReplaceRulesToSource(any(), any(), any()))
          .called(1);
    });

    test('无命中：applyReplaceRulesToSource 返回原文 → 导入原文', () async {
      final original = _sourceJson(token: '甲词');
      // 无命中：规则不匹配，返回原文
      when(() => mockApi.applyReplaceRulesToSource(any(), any(), any()))
          .thenAnswer((_) async => original);
      String? importedPayload;
      when(() => mockApi.importBookSources(any())).thenAnswer((inv) async {
        importedPayload = inv.positionalArguments.first as String;
        return 1;
      });

      final result = await service.importFromJson(original, unit: '书源');

      expect(result.success, 1);
      // 导入的是原文（未命中不改动）。payload 为 JSON 数组串 '[{...}]'
      final decoded = jsonDecode(importedPayload!) as List<dynamic>;
      expect((decoded.first as Map<String, dynamic>)['bookSourceName'], '起点');
    });

    test('替换抛异常：保持原文且导入不中断', () async {
      final original = _sourceJson(token: '乙词');
      // 模拟 FFI 未就绪/环境不支持：applyReplaceRulesToSource 抛异常
      when(() => mockApi.applyReplaceRulesToSource(any(), any(), any()))
          .thenThrow(Exception('FFI 未就绪'));
      String? importedPayload;
      when(() => mockApi.importBookSources(any())).thenAnswer((inv) async {
        importedPayload = inv.positionalArguments.first as String;
        return 1;
      });

      final result = await service.importFromJson(original, unit: '书源');

      // 替换失败不中断导入：成功 1 条，导入原文（payload 为数组串 '[{...}]'）
      expect(result.success, 1);
      final decoded = jsonDecode(importedPayload!) as List<dynamic>;
      expect((decoded.first as Map<String, dynamic>)['bookSourceName'], '起点');
    });

    test('importFromUrl / importFromFile 委托 importFromJson 亦受挂钩', () async {
      // 仅验证挂钩存在：对 importFromJson 的委托路径，
      // applyReplaceRulesToSource 会被调用（经由 importFromJson 内同一挂钩点）
      when(() => mockApi.applyReplaceRulesToSource(any(), any(), any()))
          .thenAnswer((inv) async => inv.positionalArguments.first as String);
      when(() => mockApi.importBookSources(any())).thenAnswer((_) async => 1);
      // importFromUrl/importFromFile 依赖网络/文件系统，此处以 importFromJson
      // 的委托关系佐证（见 service 源码 importFromUrl→importFromJson、
      // importFromFile→importFromJson），不重复真实 IO
      final json = _sourceJson(token: '旧站');
      final result = await service.importFromJson(json);
      expect(result.success, 1);
      verify(() => mockApi.applyReplaceRulesToSource(any(), any(), any()))
          .called(1);
    });
  });

  // ============================================================
  // 4. 导入挂钩 — SourceNotifier.importSources（原始 JSON 直传入口）
  // ============================================================
  group('SourceNotifier.importSources 导入挂钩', () {
    late MockRustApi mockApi;
    late ProviderContainer container;

    setUpAll(registerFallbacks);

    setUp(() {
      mockApi = MockRustApi();
      container = ProviderContainer(
        overrides: [bookApiProvider.overrideWithValue(mockApi)],
      );
      addTearDown(container.dispose);
      when(() => mockApi.getBookSources()).thenAnswer((_) async => []);
    });

    SourceNotifier readNotifier() =>
        container.read(sourceNotifierProvider.notifier);

    test('有命中：交 importBookSources 的 JSON 已被替换', () async {
      final applied =
          _sourceJson(token: '旧站').replaceAll('旧站', '新站');
      when(() => mockApi.applyReplaceRulesToSource(any(), any(), any()))
          .thenAnswer((_) async => applied);
      String? importedPayload;
      when(() => mockApi.importBookSources(any())).thenAnswer((inv) async {
        importedPayload = inv.positionalArguments.first as String;
        return 1;
      });

      await readNotifier().importSources(_sourceJson(token: '旧站', name: '起点'));

      expect(importedPayload, isNotNull);
      expect(importedPayload, contains('新站'));
      expect(importedPayload, isNot(contains('旧站')));
      verify(() => mockApi.applyReplaceRulesToSource(any(), any(), any()))
          .called(1);
    });

    test('无命中：返回原文 → 导入原文', () async {
      final original = _sourceJson(token: '丙词');
      when(() => mockApi.applyReplaceRulesToSource(any(), any(), any()))
          .thenAnswer((inv) async => inv.positionalArguments.first as String);
      String? importedPayload;
      when(() => mockApi.importBookSources(any())).thenAnswer((inv) async {
        importedPayload = inv.positionalArguments.first as String;
        return 1;
      });

      await readNotifier().importSources('[$original]');

      final decoded =
          jsonDecode(importedPayload!) as List<dynamic>;
      expect((decoded.first as Map<String, dynamic>)['bookSourceName'], '起点');
    });

    test('替换抛异常：保持原文且导入不中断', () async {
      final original = _sourceJson(token: '丁词');
      when(() => mockApi.applyReplaceRulesToSource(any(), any(), any()))
          .thenThrow(Exception('FFI 未就绪'));
      String? importedPayload;
      when(() => mockApi.importBookSources(any())).thenAnswer((inv) async {
        importedPayload = inv.positionalArguments.first as String;
        return 1;
      });

      await readNotifier().importSources('[$original]');

      // 替换失败不中断导入
      expect(importedPayload, isNotNull);
      final decoded =
          jsonDecode(importedPayload!) as List<dynamic>;
      expect((decoded.first as Map<String, dynamic>)['bookSourceName'], '起点');
    });
  });
}
