// 批16a/16d 审查回修：高亮规则与自动任务导入边界测试
//
// 覆盖：
// 1. P2-5 高亮规则归一（uuid 形态/超时回退/空白样式/正则可编译）、合并按序
//    重排 sortOrder、比较覆盖 timeoutMillisecond；
// 2. P1-3 自动任务导入传入 camelCase locals（customOrder/lastRunAt 不被清零）；
// 3. P2-3 混合批缺 id 条目调用 FFI 前预生成 id（不被 Rust 合并静默丢弃）；
// 4. P2-4 cron 不可解析 / script 归一后为空明确失败（对齐 validateImportedTask）。

import 'dart:convert';

import 'package:flutter_legado/src/providers/association/association_notifier.dart';
import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' hide Provider;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../mocks/mocks.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('P2-5 高亮规则导入归一/合并/比较', () {
    Map<String, dynamic> baseRule({
      String uuid = '3F2504E0-4F89-41D3-9A0C-0305E82C3301',
      int timeout = 0,
      String style = ' ',
      String scope = '  ',
      bool isRegex = false,
      String pattern = '重要',
    }) => {
      'id': 7,
      'uuid': uuid,
      'name': '关键词',
      'pattern': pattern,
      'isRegex': isRegex,
      'scope': scope,
      'style': style,
      'timeoutMillisecond': timeout,
      'sortOrder': 4,
    };

    test('uuid 归一小写；非法 uuid 明确报错', () {
      final rule = AssociationNotifier.normalizeHighlightRuleForImport(
        baseRule(),
      );
      expect(rule['uuid'], '3f2504e0-4f89-41d3-9a0c-0305e82c3301');

      expect(
        () => AssociationNotifier.normalizeHighlightRuleForImport(
          baseRule(uuid: 'not-a-uuid'),
        ),
        throwsFormatException,
      );
    });

    test('空白 scope 移除、timeout<=0 → 3000、空白 style → 默认样式', () {
      final rule = AssociationNotifier.normalizeHighlightRuleForImport(
        baseRule(),
      );
      expect(rule.containsKey('scope'), isFalse);
      expect(rule['timeoutMillisecond'], 3000);
      expect(rule['style'], AssociationNotifier.highlightRuleDefaultStyle);
    });

    test('isRegex 时正则必须可编译', () {
      expect(
        () => AssociationNotifier.normalizeHighlightRuleForImport(
          baseRule(isRegex: true, pattern: '(未闭合'),
        ),
        throwsFormatException,
      );
      final rule = AssociationNotifier.normalizeHighlightRuleForImport(
        baseRule(isRegex: true, pattern: r'\d+'),
      );
      expect(rule['pattern'], r'\d+');
    });

    test('合并：本地顺序在前保留 id，新规则追加并重排 sortOrder', () {
      const uuidA = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
      const uuidB = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
      const uuidC = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc';
      final local = [
        {'id': 1, 'uuid': uuidA, 'name': '本地A', 'pattern': 'a', 'sortOrder': 9},
        {'id': 2, 'uuid': uuidB, 'name': '本地B', 'pattern': 'b', 'sortOrder': 3},
      ];
      final imported = [
        {'uuid': uuidC, 'name': '新增C', 'pattern': 'c'},
        {
          'uuid': uuidA,
          'name': '覆盖A',
          'pattern': 'a2',
          'timeoutMillisecond': 3000,
          'style': AssociationNotifier.highlightRuleDefaultStyle,
        },
      ];

      final merged = AssociationNotifier.mergeHighlightRulesForImport(
        local,
        imported,
      );
      expect(merged.map((e) => e['uuid']).toList(), [uuidA, uuidB, uuidC]);
      expect(merged[0]['id'], 1, reason: '同 uuid 覆盖保留本地 id');
      expect(merged[0]['name'], '覆盖A');
      expect(merged[1]['id'], 2);
      expect(merged[2].containsKey('id'), isFalse, reason: '新规则交给 Rust 自增');
      expect(merged.map((e) => e['sortOrder']).toList(), [0, 1, 2]);
    });

    test('比较覆盖 timeoutMillisecond（此前遗漏导致误判已存在）', () {
      final a = baseRule(timeout: 3000);
      final b = baseRule(timeout: 5000);
      expect(AssociationNotifier.isSameHighlightRule(a, b), isFalse);
      expect(
        AssociationNotifier.isSameHighlightRule(
          baseRule(timeout: 0),
          baseRule(timeout: 3000),
        ),
        isTrue,
        reason: '缺省 0 与显式默认 3000 视为同值',
      );
    });
  });

  group('P1-3/P2-3/P2-4 自动任务导入', () {
    late MockRustApi api;
    late ProviderContainer container;

    setUpAll(registerFallbacks);

    setUp(() {
      api = MockRustApi();
      container = ProviderContainer(
        overrides: [bookApiProvider.overrideWithValue(api)],
      );
      addTearDown(container.dispose);

      when(
        () => api.autoTaskNextDueAt(
          cron: any(named: 'cron'),
          fromMs: any(named: 'fromMs'),
        ),
      ).thenAnswer((_) async => DateTime.now().millisecondsSinceEpoch + 60000);
      when(
        () => api.autoTaskNormalizeScript(script: any(named: 'script')),
      ).thenAnswer((inv) async {
        final script = inv.namedArguments[#script] as String;
        return script.startsWith('@js:') ? script.substring(4) : script;
      });
    });

    AssociationNotifier notifier() =>
        container.read(associationNotifierProvider.notifier);

    test('camelCase locals 透传 FFI，customOrder/lastRunAt 保留入库', () async {
      // 与 Dart AutoTaskRule.toJson 同形（camelCase）
      final locals = [
        {
          'id': 't1',
          'name': '本地任务',
          'enable': true,
          'cron': '*/30 * * * *',
          'script': 'print(1)',
          'customOrder': 5,
          'lastRunAt': 1712345678901,
          'lastResult': '成功',
          'lastLog': '日志',
        },
      ];
      when(() => api.autoTaskListRules()).thenAnswer((_) async => locals);
      when(
        () => api.autoTaskPrepareImported(
          localTasksJson: any(named: 'localTasksJson'),
          importedJson: any(named: 'importedJson'),
        ),
      ).thenAnswer((inv) async {
        // 断言 Dart → FFI 的 locals 保持 camelCase（P1-3 边界）
        final localJson = inv.namedArguments[#localTasksJson] as String;
        final decodedLocal = (jsonDecode(localJson) as List).single as Map;
        expect(decodedLocal['customOrder'], 5);
        expect(decodedLocal['lastRunAt'], 1712345678901);
        // 混合批：无 id 条目已被预生成（P2-3）
        final importedJson = inv.namedArguments[#importedJson] as String;
        final decodedImported = (jsonDecode(importedJson) as List)
            .cast<Map<String, dynamic>>();
        expect(decodedImported.every((e) => '${e['id']}'.isNotEmpty), isTrue);
        // 模拟 Rust 合并：配置取导入、运行时取本地
        return [
          {
            ...decodedImported[0],
            'customOrder': 5,
            'lastRunAt': 1712345678901,
            'lastResult': '成功',
            'lastLog': '日志',
          },
        ];
      });
      final created = <Map<String, dynamic>>[];
      when(
        () => api.autoTaskCreateRule(ruleJson: any(named: 'ruleJson')),
      ).thenAnswer((inv) async {
        created.add(
          Map<String, dynamic>.from(
            jsonDecode(inv.namedArguments[#ruleJson] as String) as Map,
          ),
        );
        return 't1';
      });

      final result = await notifier().confirmImport(ImportType.autoTask, [
        {
          'id': 't1',
          'name': '导入任务',
          'cron': '0 8 * * *',
          'script': '@js:print(2)',
        },
      ]);

      expect(result.success, 1);
      expect(created.single['customOrder'], 5);
      expect(created.single['lastRunAt'], 1712345678901);
      expect(created.single['script'], 'print(2)');
    });

    test('混合批缺 id 条目在调用 FFI 前预生成 id（P2-3）', () async {
      when(() => api.autoTaskListRules()).thenAnswer((_) async => []);
      String? forwarded;
      when(
        () => api.autoTaskPrepareImported(
          localTasksJson: any(named: 'localTasksJson'),
          importedJson: any(named: 'importedJson'),
        ),
      ).thenAnswer((inv) async {
        forwarded = inv.namedArguments[#importedJson] as String;
        return (jsonDecode(forwarded!) as List).cast<Map<String, dynamic>>();
      });
      when(
        () => api.autoTaskCreateRule(ruleJson: any(named: 'ruleJson')),
      ).thenAnswer((_) async => 'id');

      final result = await notifier().confirmImport(ImportType.autoTask, [
        {'id': 'with-id', 'name': '有 id', 'cron': '0 8 * * *', 'script': 'x'},
        {'name': '无 id', 'cron': '0 9 * * *', 'script': 'y'},
      ]);

      expect(result.success, 2);
      final forwardedList = (jsonDecode(forwarded!) as List).cast<Map>();
      expect(forwardedList.length, 2);
      expect(
        forwardedList.every((e) => '${e['id'] ?? ''}'.isNotEmpty),
        isTrue,
        reason: '缺 id 条目必须先补 id，否则 Rust 合并会丢弃',
      );
    });

    test('cron 不可解析 → 明确失败且不入库（P2-4）', () async {
      when(
        () => api.autoTaskNextDueAt(
          cron: any(named: 'cron'),
          fromMs: any(named: 'fromMs'),
        ),
      ).thenAnswer((_) async => -1);
      final result = await notifier().confirmImport(ImportType.autoTask, [
        {'id': 'bad-cron', 'name': '坏 cron', 'cron': 'bad', 'script': 'x'},
      ]);
      expect(result.success, 0);
      expect(result.failed, 1);
      expect(result.errors.single, contains('请输入有效的五段 Cron 计划'));
      verifyNever(
        () => api.autoTaskCreateRule(ruleJson: any(named: 'ruleJson')),
      );
    });

    test('script 归一后为空 → 明确失败且不入库（P2-4）', () async {
      when(
        () => api.autoTaskNormalizeScript(script: any(named: 'script')),
      ).thenAnswer((_) async => '   ');
      final result = await notifier().confirmImport(ImportType.autoTask, [
        {
          'id': 'bad-script',
          'name': '空脚本',
          'cron': '0 8 * * *',
          'script': '@js: ',
        },
      ]);
      expect(result.success, 0);
      expect(result.failed, 1);
      expect(result.errors.single, contains('请输入 JavaScript 任务脚本'));
      verifyNever(
        () => api.autoTaskCreateRule(ruleJson: any(named: 'ruleJson')),
      );
    });
  });
}
