import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/providers/txt_toc_rules/txt_toc_rules_notifier.dart';

import '../mocks/mocks.dart';

void main() {
  group('TxtTocRulesNotifier', () {
    late MockRustApi mockApi;
    late ProviderContainer container;
    late Map<String, String?> configStore;

    setUpAll(() {
      TestWidgetsFlutterBinding.ensureInitialized();
      registerFallbacks();
    });

    setUp(() async {
      SharedPreferences.setMockInitialValues({
        // 已完成默认导入，避免 load 走 assets 覆盖桩数据
        kTxtTocRuleVersionKey: kTxtTocRuleVersion,
      });
      mockApi = MockRustApi();
      configStore = {};
      when(() => mockApi.getConfig(any())).thenAnswer((inv) async {
        final key = inv.positionalArguments[0] as String;
        return configStore[key];
      });
      when(() => mockApi.setConfig(any(), any())).thenAnswer((inv) async {
        final key = inv.positionalArguments[0] as String;
        final value = inv.positionalArguments[1] as String;
        configStore[key] = value;
      });
      container = ProviderContainer(
        overrides: [bookApiProvider.overrideWithValue(mockApi)],
      );
      addTearDown(container.dispose);
    });

    TxtTocRulesState readState() =>
        container.read(txtTocRulesNotifierProvider);
    TxtTocRulesNotifier readNotifier() =>
        container.read(txtTocRulesNotifierProvider.notifier);

    void stubStored(String? stored) {
      if (stored == null) {
        configStore.remove('txt_toc_rules');
      } else {
        configStore['txt_toc_rules'] = stored;
      }
    }

    test('初始状态为空', () {
      expect(readState().rules, isEmpty);
      expect(readState().isLoading, isFalse);
      expect(readState().error, isNull);
    });

    test('load 无持久化且需升级时写入原版默认规则', () async {
      SharedPreferences.setMockInitialValues({});
      stubStored(null);

      await readNotifier().load();

      final state = readState();
      expect(state.isLoading, isFalse);
      expect(state.error, isNull);
      expect(state.rules, isNotEmpty);
      expect(state.rules.first.id, lessThan(0)); // 原版默认 id 为负数
      verify(() => mockApi.setConfig('txt_toc_rules', any()))
          .called(greaterThan(0));
    });

    test('load 解析已持久化的规则（不重复写回）', () async {
      final stored = jsonEncode([
        {'id': 9, 'name': '自定义', 'rule': r'^\d+', 'enable': true},
      ]);
      stubStored(stored);

      await readNotifier().load();

      final state = readState();
      expect(state.rules.single.id, equals(9));
      expect(state.rules.single.name, equals('自定义'));
      verifyNever(() => mockApi.setConfig(any(), any()));
    });

    test('addRule 自动生成 id 与 serialNumber 并持久化', () async {
      stubStored(jsonEncode([
        {'id': 1, 'name': 'a', 'rule': r'^a', 'enable': true, 'serialNumber': 0},
        {'id': 2, 'name': 'b', 'rule': r'^b', 'enable': true, 'serialNumber': 1},
        {'id': 3, 'name': 'c', 'rule': r'^c', 'enable': false, 'serialNumber': 2},
      ]));
      await readNotifier().load();

      await readNotifier().addRule(const TxtTocRule(name: '新增', rule: r'^x'));

      final state = readState();
      expect(state.rules.length, equals(4));
      final added = state.rules.last;
      expect(added.id, equals(4));
      expect(added.serialNumber, equals(3));
      verify(() => mockApi.setConfig('txt_toc_rules', any())).called(1);
    });

    test('updateRule 更新指定规则', () async {
      stubStored(jsonEncode([
        {'id': 2, 'name': '旧', 'rule': r'^第', 'enable': true, 'serialNumber': 1},
      ]));
      await readNotifier().load();

      await readNotifier().updateRule(
        const TxtTocRule(id: 2, name: '改名', rule: r'^第', serialNumber: 1),
      );

      expect(
        readState().rules.firstWhere((r) => r.id == 2).name,
        equals('改名'),
      );
    });

    test('deleteRule 删除指定规则', () async {
      stubStored(jsonEncode([
        {'id': 1, 'name': 'a', 'rule': r'^a', 'enable': true},
        {'id': 2, 'name': 'b', 'rule': r'^b', 'enable': true},
      ]));
      await readNotifier().load();

      await readNotifier().deleteRule(1);

      final state = readState();
      expect(state.rules.length, equals(1));
      expect(state.rules.any((r) => r.id == 1), isFalse);
    });

    test('setEnabled 切换启停', () async {
      stubStored(jsonEncode([
        {'id': 3, 'name': 'c', 'rule': r'^c', 'enable': false},
      ]));
      await readNotifier().load();

      await readNotifier().setEnabled(3, true);

      expect(
        readState().rules.firstWhere((r) => r.id == 3).enable,
        isTrue,
      );
    });

    test('load 异常时记录 error', () async {
      when(() => mockApi.getConfig(any())).thenThrow(Exception('读取失败'));

      await readNotifier().load();

      final state = readState();
      expect(state.isLoading, isFalse);
      expect(state.error, contains('读取失败'));
    });
  });
}
