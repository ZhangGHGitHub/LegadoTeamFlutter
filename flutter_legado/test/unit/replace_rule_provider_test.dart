/// ReplaceRuleProvider 单元测试
///
/// 覆盖：load/addRule/updateRule/deleteRule/setEnabled/moveUp/moveDown
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:flutter_legado/src/providers/replace_rule_provider.dart';
import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/bridge/ffi.dart';

import '../mocks/mocks.dart';

void main() {
  late ReplaceRuleProvider provider;
  late MockRustApi mockApi;

  setUpAll(() {
    registerFallbacks();
  });

  setUp(() {
    mockApi = MockRustApi();
    provider = ReplaceRuleProvider(mockApi);
  });

  group('ReplaceRuleProvider 初始状态', () {
    test('初始规则列表为空', () {
      expect(provider.rules, isEmpty);
    });

    test('初始非加载状态', () {
      expect(provider.loading, isFalse);
    });

    test('初始无错误', () {
      expect(provider.error, isNull);
    });
  });

  group('ReplaceRuleProvider load', () {
    test('成功加载规则列表', () async {
      final rules = [
        const ReplaceRule(id: 1, name: '规则1', pattern: '广告', replacement: ''),
        const ReplaceRule(id: 2, name: '规则2', pattern: '\\n+', replacement: '\n'),
      ];
      when(() => mockApi.getReplaceRules()).thenAnswer((_) async => rules);

      await provider.load();

      expect(provider.rules.length, equals(2));
      expect(provider.loading, isFalse);
      expect(provider.error, isNull);
    });

    test('加载失败设置 BridgeError', () async {
      when(() => mockApi.getReplaceRules())
          .thenThrow(const BridgeError(message: '规则加载失败'));

      await provider.load();

      expect(provider.error, equals('规则加载失败'));
      expect(provider.loading, isFalse);
    });

    test('加载失败设置普通异常', () async {
      when(() => mockApi.getReplaceRules()).thenThrow(Exception('异常'));

      await provider.load();

      expect(provider.error, contains('异常'));
    });

    test('load 触发通知', () async {
      when(() => mockApi.getReplaceRules()).thenAnswer((_) async => []);
      var notifyCount = 0;
      provider.addListener(() => notifyCount++);

      await provider.load();

      expect(notifyCount, greaterThanOrEqualTo(2));
    });
  });

  group('ReplaceRuleProvider addRule', () {
    test('添加规则成功追加到列表', () async {
      const newRule = ReplaceRule(id: 1, name: '新规则', pattern: 'test');
      when(() => mockApi.addReplaceRule(any())).thenAnswer((_) async => newRule);

      final result = await provider.addRule(newRule);

      expect(result.name, equals('新规则'));
      expect(provider.rules.length, equals(1));
      expect(provider.rules[0].name, equals('新规则'));
    });
  });

  group('ReplaceRuleProvider updateRule', () {
    test('更新规则成功替换列表中对应项', () async {
      // 先加载
      when(() => mockApi.getReplaceRules()).thenAnswer((_) async => [
            const ReplaceRule(id: 1, name: '旧名', pattern: 'a'),
          ]);
      await provider.load();

      when(() => mockApi.updateReplaceRule(any())).thenAnswer((_) async {});
      const updated = ReplaceRule(id: 1, name: '新名', pattern: 'b');

      await provider.updateRule(updated);

      expect(provider.rules[0].name, equals('新名'));
      expect(provider.rules[0].pattern, equals('b'));
    });

    test('更新不存在的规则不改变列表', () async {
      when(() => mockApi.getReplaceRules()).thenAnswer((_) async => [
            const ReplaceRule(id: 1, name: '规则', pattern: 'a'),
          ]);
      await provider.load();

      when(() => mockApi.updateReplaceRule(any())).thenAnswer((_) async {});
      const notExist = ReplaceRule(id: 99, name: '不存在', pattern: 'x');

      await provider.updateRule(notExist);

      expect(provider.rules.length, equals(1));
      expect(provider.rules[0].name, equals('规则'));
    });
  });

  group('ReplaceRuleProvider deleteRule', () {
    test('删除规则成功移除', () async {
      when(() => mockApi.getReplaceRules()).thenAnswer((_) async => [
            const ReplaceRule(id: 1, name: '规则1'),
            const ReplaceRule(id: 2, name: '规则2'),
          ]);
      await provider.load();

      when(() => mockApi.deleteReplaceRule(any())).thenAnswer((_) async {});

      await provider.deleteRule(1);

      expect(provider.rules.length, equals(1));
      expect(provider.rules[0].id, equals(2));
    });
  });

  group('ReplaceRuleProvider setEnabled', () {
    test('启用/禁用规则', () async {
      when(() => mockApi.getReplaceRules()).thenAnswer((_) async => [
            const ReplaceRule(id: 1, name: '规则', isEnabled: true),
          ]);
      await provider.load();

      when(() => mockApi.setReplaceRuleEnabled(any(), any()))
          .thenAnswer((_) async {});

      await provider.setEnabled(1, false);

      expect(provider.rules[0].isEnabled, isFalse);
    });

    test('设置不存在的规则不改变列表', () async {
      when(() => mockApi.getReplaceRules()).thenAnswer((_) async => [
            const ReplaceRule(id: 1, name: '规则', isEnabled: true),
          ]);
      await provider.load();

      when(() => mockApi.setReplaceRuleEnabled(any(), any()))
          .thenAnswer((_) async {});

      await provider.setEnabled(99, false);

      expect(provider.rules[0].isEnabled, isTrue);
    });
  });

  group('ReplaceRuleProvider moveUp/moveDown', () {
    setUp(() async {
      when(() => mockApi.getReplaceRules()).thenAnswer((_) async => [
            const ReplaceRule(id: 1, name: 'A', order: 0),
            const ReplaceRule(id: 2, name: 'B', order: 1),
            const ReplaceRule(id: 3, name: 'C', order: 2),
          ]);
      await provider.load();
    });

    test('moveUp 交换相邻规则', () {
      provider.moveUp(1);

      expect(provider.rules[0].name, equals('B'));
      expect(provider.rules[1].name, equals('A'));
    });

    test('moveUp 第一个元素不操作', () {
      provider.moveUp(0);

      expect(provider.rules[0].name, equals('A'));
    });

    test('moveUp 越界不操作', () {
      provider.moveUp(5);
      expect(provider.rules[0].name, equals('A'));
    });

    test('moveDown 交换相邻规则', () {
      provider.moveDown(0);

      expect(provider.rules[0].name, equals('B'));
      expect(provider.rules[1].name, equals('A'));
    });

    test('moveDown 最后一个元素不操作', () {
      provider.moveDown(2);

      expect(provider.rules[2].name, equals('C'));
    });

    test('moveDown 负索引不操作', () {
      provider.moveDown(-1);
      expect(provider.rules[0].name, equals('A'));
    });

    test('moveUp 触发通知', () {
      var notified = false;
      provider.addListener(() => notified = true);
      provider.moveUp(1);
      expect(notified, isTrue);
    });
  });
}
