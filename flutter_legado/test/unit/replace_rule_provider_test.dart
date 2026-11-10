/// ReplaceRuleNotifier 单元测试
///
/// 覆盖：load/addRule/updateRule/deleteRule/setEnabled，
/// 以及批12 排序写链路（reorder/moveToTop/moveToBottom 全量重排 + 失败回滚）
library;

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
    // [批12] reorderReplaceRules(List<int>) 的 any()/captureAny() 需要 fallback
    registerFallbackValue(<int>[]);
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

  /// 捕获唯一一次 `reorderReplaceRules` 入参（同时断言只调了一次）
  List<int> captureReorderedIds() {
    final captured = verify(
      () => mockApi.reorderReplaceRules(captureAny()),
    ).captured;
    expect(captured, hasLength(1), reason: '应恰好一次全量调用');
    return captured.single as List<int>;
  }

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
        const ReplaceRule(
          id: 2,
          name: '规则2',
          pattern: '\\n+',
          replacement: '\n',
        ),
      ];
      when(() => mockApi.getReplaceRules()).thenAnswer((_) async => rules);

      await readNotifier().load();

      expect(readState().rules.length, equals(2));
      expect(readState().loading, isFalse);
      expect(readState().error, isNull);
    });

    test('加载失败设置 BridgeError', () async {
      when(
        () => mockApi.getReplaceRules(),
      ).thenThrow(const BridgeError(message: '规则加载失败'));

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
      container.listen(replaceRuleNotifierProvider, (_, _) => notifyCount++);

      await readNotifier().load();

      // loading: false→true→false，产生两次真实变化
      expect(notifyCount, greaterThanOrEqualTo(2));
    });
  });

  group('ReplaceRuleNotifier addRule', () {
    test('添加规则成功追加到列表', () async {
      const newRule = ReplaceRule(id: 1, name: '新规则', pattern: 'test');
      when(
        () => mockApi.addReplaceRule(any()),
      ).thenAnswer((_) async => newRule);

      final result = await readNotifier().addRule(newRule);

      expect(result.name, equals('新规则'));
      expect(readState().rules.length, equals(1));
      expect(readState().rules[0].name, equals('新规则'));
    });
  });

  group('ReplaceRuleNotifier updateRule', () {
    test('更新规则成功替换列表中对应项', () async {
      // 先加载
      when(() => mockApi.getReplaceRules()).thenAnswer(
        (_) async => [const ReplaceRule(id: 1, name: '旧名', pattern: 'a')],
      );
      await readNotifier().load();

      when(() => mockApi.updateReplaceRule(any())).thenAnswer((_) async {});
      const updated = ReplaceRule(id: 1, name: '新名', pattern: 'b');

      await readNotifier().updateRule(updated);

      expect(readState().rules[0].name, equals('新名'));
      expect(readState().rules[0].pattern, equals('b'));
    });

    test('更新不存在的规则不改变列表', () async {
      when(() => mockApi.getReplaceRules()).thenAnswer(
        (_) async => [const ReplaceRule(id: 1, name: '规则', pattern: 'a')],
      );
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
      when(() => mockApi.getReplaceRules()).thenAnswer(
        (_) async => [
          const ReplaceRule(id: 1, name: '规则1'),
          const ReplaceRule(id: 2, name: '规则2'),
        ],
      );
      await readNotifier().load();

      when(() => mockApi.deleteReplaceRule(any())).thenAnswer((_) async {});

      await readNotifier().deleteRule(1);

      expect(readState().rules.length, equals(1));
      expect(readState().rules[0].id, equals(2));
    });
  });

  group('ReplaceRuleNotifier setEnabled', () {
    test('启用/禁用规则', () async {
      when(() => mockApi.getReplaceRules()).thenAnswer(
        (_) async => [const ReplaceRule(id: 1, name: '规则', isEnabled: true)],
      );
      await readNotifier().load();

      when(
        () => mockApi.setReplaceRuleEnabled(any(), any()),
      ).thenAnswer((_) async {});

      await readNotifier().setEnabled(1, false);

      expect(readState().rules[0].isEnabled, isFalse);
    });

    test('设置不存在的规则不改变列表', () async {
      when(() => mockApi.getReplaceRules()).thenAnswer(
        (_) async => [const ReplaceRule(id: 1, name: '规则', isEnabled: true)],
      );
      await readNotifier().load();

      when(
        () => mockApi.setReplaceRuleEnabled(any(), any()),
      ).thenAnswer((_) async {});

      await readNotifier().setEnabled(99, false);

      expect(readState().rules[0].isEnabled, isTrue);
    });
  });

  // ===== [批12 | 2026-11-10] 排序写链路：一次全量 reorderReplaceRules =====
  group('ReplaceRuleNotifier reorder（全量重排）', () {
    List<ReplaceRule> initialRules() => const [
      ReplaceRule(id: 1, name: 'A', order: 0),
      ReplaceRule(id: 2, name: 'B', order: 1),
      ReplaceRule(id: 3, name: 'C', order: 2),
    ];

    setUp(() async {
      when(
        () => mockApi.getReplaceRules(),
      ).thenAnswer((_) async => initialRules());
      await readNotifier().load();
    });

    test('拖动 0→2：乐观更新顺序并只调一次全量 FFI', () async {
      when(() => mockApi.reorderReplaceRules(any())).thenAnswer((_) async => 3);

      final ok = await readNotifier().reorder(0, 2);

      expect(ok, isTrue);
      expect(
        readState().rules.map((r) => r.name).toList(),
        equals(['B', 'C', 'A']),
      );
      expect(
        readState().rules.map((r) => r.order).toList(),
        equals([0, 1, 2]),
        reason: '乐观更新后 order 应连续重编号',
      );
      expect(captureReorderedIds(), equals([2, 3, 1]));
    });

    test('拖动 2→0：只调一次全量 FFI', () async {
      when(() => mockApi.reorderReplaceRules(any())).thenAnswer((_) async => 3);

      final ok = await readNotifier().reorder(2, 0);

      expect(ok, isTrue);
      expect(
        readState().rules.map((r) => r.name).toList(),
        equals(['C', 'A', 'B']),
      );
      expect(captureReorderedIds(), equals([3, 1, 2]));
    });

    test('非法索引不调用 FFI', () async {
      final ok = await readNotifier().reorder(5, 0);

      expect(ok, isTrue);
      verifyNever(() => mockApi.reorderReplaceRules(any()));
    });

    test('FFI 抛错 → load 回滚原顺序并返回 false', () async {
      when(
        () => mockApi.reorderReplaceRules(any()),
      ).thenThrow(const BridgeError(message: '重排替换规则参数错误: 缺失 id'));
      var loads = 0;
      when(() => mockApi.getReplaceRules()).thenAnswer((_) async {
        loads++;
        return initialRules();
      });

      final ok = await readNotifier().reorder(0, 2);

      expect(ok, isFalse, reason: '失败应返回 false 供页面提示');
      expect(loads, 1, reason: '失败后应重新 load 回滚');
      expect(
        readState().rules.map((r) => r.name).toList(),
        equals(['A', 'B', 'C']),
        reason: '顺序应恢复为 DB 原顺序',
      );
      expect(readState().error, isNull, reason: '回滚成功不应留下错误态');
    });

    test('moveToTop 单条：一次全量调用且置顶', () async {
      when(() => mockApi.reorderReplaceRules(any())).thenAnswer((_) async => 3);

      final ok = await readNotifier().moveToTop([3]);

      expect(ok, isTrue);
      expect(
        readState().rules.map((r) => r.name).toList(),
        equals(['C', 'A', 'B']),
      );
      expect(captureReorderedIds(), equals([3, 1, 2]));
    });

    test('moveToTop 多选保持相对顺序，一次全量调用', () async {
      when(() => mockApi.reorderReplaceRules(any())).thenAnswer((_) async => 3);

      final ok = await readNotifier().moveToTop([2, 3]);

      expect(ok, isTrue);
      expect(
        readState().rules.map((r) => r.name).toList(),
        equals(['B', 'C', 'A']),
      );
      expect(captureReorderedIds(), equals([2, 3, 1]));
    });

    test('moveToBottom 单条：一次全量调用且置底', () async {
      when(() => mockApi.reorderReplaceRules(any())).thenAnswer((_) async => 3);

      final ok = await readNotifier().moveToBottom([1]);

      expect(ok, isTrue);
      expect(
        readState().rules.map((r) => r.name).toList(),
        equals(['B', 'C', 'A']),
      );
      expect(captureReorderedIds(), equals([2, 3, 1]));
    });

    test('moveToBottom 多选保持相对顺序，一次全量调用', () async {
      when(() => mockApi.reorderReplaceRules(any())).thenAnswer((_) async => 3);

      final ok = await readNotifier().moveToBottom([1, 2]);

      expect(ok, isTrue);
      expect(
        readState().rules.map((r) => r.name).toList(),
        equals(['C', 'A', 'B']),
      );
      expect(captureReorderedIds(), equals([3, 1, 2]));
    });

    test('置顶失败 → 返回 false 且回滚', () async {
      when(
        () => mockApi.reorderReplaceRules(any()),
      ).thenThrow(const BridgeError(message: '重排失败'));
      when(
        () => mockApi.getReplaceRules(),
      ).thenAnswer((_) async => initialRules());

      final ok = await readNotifier().moveToTop([3]);

      expect(ok, isFalse);
      expect(
        readState().rules.map((r) => r.name).toList(),
        equals(['A', 'B', 'C']),
      );
    });
  });
}
