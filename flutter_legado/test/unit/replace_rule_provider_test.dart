/// ReplaceRuleNotifier 单元测试
///
/// 覆盖：load/addRule/updateRule/deleteRule/setEnabled/moveUp/moveDown
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/providers/replace_rule/replace_rule_notifier.dart';
import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/bridge/ffi.dart';

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

  ReplaceRuleState readState() => container.read(replaceRuleNotifierProvider);
  ReplaceRuleNotifier readNotifier() =>
      container.read(replaceRuleNotifierProvider.notifier);

  group('ReplaceRuleNotifier 初始状态', () {
    test('初始规则列表为空', () {
      expect(readState().rules, isEmpty);
    });

    test('初始非加载状态', () {
      expect(readState().loading, isFalse);
    });

    test('初始无错误', () {
      expect(readState().error, isNull);
    });
  });

  group('ReplaceRuleNotifier load', () {
    test('成功加载规则列表', () async {
      final rules = [
        const ReplaceRule(id: 1, name: '规则1', pattern: '广告', replacement: ''),
        const ReplaceRule(id: 2, name: '规则2', pattern: '\\n+', replacement: '\n'),
      ];
      when(() => mockApi.getReplaceRules()).thenAnswer((_) async => rules);

      await readNotifier().load();

      expect(readState().rules.length, equals(2));
      expect(readState().loading, isFalse);
      expect(readState().error, isNull);
    });

    test('加载失败设置 BridgeError', () async {
      when(() => mockApi.getReplaceRules())
          .thenThrow(const BridgeError(message: '规则加载失败'));

      await readNotifier().load();

      expect(readState().error, equals('规则加载失败'));
      expect(readState().loading, isFalse);
    });

    test('加载失败设置普通异常', () async {
      when(() => mockApi.getReplaceRules()).thenThrow(Exception('异常'));

      await readNotifier().load();

      expect(readState().error, contains('异常'));
    });

    test('load 触发通知（loading 状态真实翻转 → 至少 2 次）', () async {
      when(() => mockApi.getReplaceRules()).thenAnswer((_) async => []);
      var notifyCount = 0;
      container.listen(
        replaceRuleNotifierProvider,
        (_, __) => notifyCount++,
      );

      await readNotifier().load();

      // loading: false→true→false，产生两次真实变化
      expect(notifyCount, greaterThanOrEqualTo(2));
    });
  });

  group('ReplaceRuleNotifier addRule', () {
    test('添加规则成功追加到列表', () async {
      const newRule = ReplaceRule(id: 1, name: '新规则', pattern: 'test');
      when(() => mockApi.addReplaceRule(any())).thenAnswer((_) async => newRule);

      final result = await readNotifier().addRule(newRule);

      expect(result.name, equals('新规则'));
      expect(readState().rules.length, equals(1));
      expect(readState().rules[0].name, equals('新规则'));
    });
  });

  group('ReplaceRuleNotifier updateRule', () {
    test('更新规则成功替换列表中对应项', () async {
      // 先加载
      when(() => mockApi.getReplaceRules()).thenAnswer((_) async => [
            const ReplaceRule(id: 1, name: '旧名', pattern: 'a'),
          ]);
      await readNotifier().load();

      when(() => mockApi.updateReplaceRule(any())).thenAnswer((_) async {});
      const updated = ReplaceRule(id: 1, name: '新名', pattern: 'b');

      await readNotifier().updateRule(updated);

      expect(readState().rules[0].name, equals('新名'));
      expect(readState().rules[0].pattern, equals('b'));
    });

    test('更新不存在的规则不改变列表', () async {
      when(() => mockApi.getReplaceRules()).thenAnswer((_) async => [
            const ReplaceRule(id: 1, name: '规则', pattern: 'a'),
          ]);
      await readNotifier().load();

      when(() => mockApi.updateReplaceRule(any())).thenAnswer((_) async {});
      const notExist = ReplaceRule(id: 99, name: '不存在', pattern: 'x');

      await readNotifier().updateRule(notExist);

      expect(readState().rules.length, equals(1));
      expect(readState().rules[0].name, equals('规则'));
    });
  });

  group('ReplaceRuleNotifier deleteRule', () {
    test('删除规则成功移除', () async {
      when(() => mockApi.getReplaceRules()).thenAnswer((_) async => [
            const ReplaceRule(id: 1, name: '规则1'),
            const ReplaceRule(id: 2, name: '规则2'),
          ]);
      await readNotifier().load();

      when(() => mockApi.deleteReplaceRule(any())).thenAnswer((_) async {});

      await readNotifier().deleteRule(1);

      expect(readState().rules.length, equals(1));
      expect(readState().rules[0].id, equals(2));
    });
  });

  group('ReplaceRuleNotifier setEnabled', () {
    test('启用/禁用规则', () async {
      when(() => mockApi.getReplaceRules()).thenAnswer((_) async => [
            const ReplaceRule(id: 1, name: '规则', isEnabled: true),
          ]);
      await readNotifier().load();

      when(() => mockApi.setReplaceRuleEnabled(any(), any()))
          .thenAnswer((_) async {});

      await readNotifier().setEnabled(1, false);

      expect(readState().rules[0].isEnabled, isFalse);
    });

    test('设置不存在的规则不改变列表', () async {
      when(() => mockApi.getReplaceRules()).thenAnswer((_) async => [
            const ReplaceRule(id: 1, name: '规则', isEnabled: true),
          ]);
      await readNotifier().load();

      when(() => mockApi.setReplaceRuleEnabled(any(), any()))
          .thenAnswer((_) async {});

      await readNotifier().setEnabled(99, false);

      expect(readState().rules[0].isEnabled, isTrue);
    });
  });

  group('ReplaceRuleNotifier moveUp/moveDown', () {
    setUp(() async {
      when(() => mockApi.getReplaceRules()).thenAnswer((_) async => [
            const ReplaceRule(id: 1, name: 'A', order: 0),
            const ReplaceRule(id: 2, name: 'B', order: 1),
            const ReplaceRule(id: 3, name: 'C', order: 2),
          ]);
      await readNotifier().load();
    });

    test('moveUp 交换相邻规则', () {
      readNotifier().moveUp(1);

      expect(readState().rules[0].name, equals('B'));
      expect(readState().rules[1].name, equals('A'));
    });

    test('moveUp 第一个元素不操作', () {
      readNotifier().moveUp(0);

      expect(readState().rules[0].name, equals('A'));
    });

    test('moveUp 越界不操作', () {
      readNotifier().moveUp(5);
      expect(readState().rules[0].name, equals('A'));
    });

    test('moveDown 交换相邻规则', () {
      readNotifier().moveDown(0);

      expect(readState().rules[0].name, equals('B'));
      expect(readState().rules[1].name, equals('A'));
    });

    test('moveDown 最后一个元素不操作', () {
      readNotifier().moveDown(2);

      expect(readState().rules[2].name, equals('C'));
    });

    test('moveDown 负索引不操作', () {
      readNotifier().moveDown(-1);
      expect(readState().rules[0].name, equals('A'));
    });

    test('moveUp 触发通知（先制造真实变化）', () {
      var notified = false;
      container.listen(
        replaceRuleNotifierProvider,
        (_, __) => notified = true,
      );
      readNotifier().moveUp(1);
      expect(notified, isTrue);
    });
  });
}
