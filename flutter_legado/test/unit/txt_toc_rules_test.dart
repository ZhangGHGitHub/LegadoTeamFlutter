import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/providers/txt_toc_rules/txt_toc_rules_notifier.dart';

import '../mocks/mocks.dart';

void main() {
  group('TxtTocRulesNotifier', () {
    late MockRustApi mockApi;
    late ProviderContainer container;

    setUpAll(registerFallbacks);

    setUp(() {
      mockApi = MockRustApi();
      container = ProviderContainer(
        overrides: [bookApiProvider.overrideWithValue(mockApi)],
      );
      addTearDown(container.dispose);
    });

    TxtTocRulesState readState() =>
        container.read(txtTocRulesNotifierProvider);
    TxtTocRulesNotifier readNotifier() =>
        container.read(txtTocRulesNotifierProvider.notifier);

    /// 桩入 getConfig/setConfig（默认无持久化数据）
    void stubConfig({String? stored}) {
      when(() => mockApi.getConfig(any())).thenAnswer((_) async => stored);
      when(() => mockApi.setConfig(any(), any())).thenAnswer((_) async {});
    }

    test('初始状态为空', () {
      expect(readState().rules, isEmpty);
      expect(readState().isLoading, isFalse);
      expect(readState().error, isNull);
    });

    test('load 无持久化数据时写入内置默认规则', () async {
      stubConfig();

      await readNotifier().load();

      final state = readState();
      expect(state.isLoading, isFalse);
      expect(state.rules.length, equals(3));
      expect(state.rules.first.name, equals('中文章节'));
      verify(() => mockApi.setConfig('txt_toc_rules', any())).called(1);
    });

    test('load 解析已持久化的规则（不重复写回）', () async {
      final stored = jsonEncode([
        {'id': 9, 'name': '自定义', 'rule': r'^\d+', 'enable': true},
      ]);
      stubConfig(stored: stored);

      await readNotifier().load();

      final state = readState();
      expect(state.rules.single.id, equals(9));
      expect(state.rules.single.name, equals('自定义'));
      verifyNever(() => mockApi.setConfig(any(), any()));
    });

    test('addRule 自动生成 id 与 serialNumber 并持久化', () async {
      stubConfig();
      await readNotifier().load(); // 3 条默认规则（id 1~3）

      await readNotifier().addRule(const TxtTocRule(name: '新增', rule: r'^x'));

      final state = readState();
      expect(state.rules.length, equals(4));
      final added = state.rules.last;
      expect(added.id, equals(4)); // max(1,2,3)+1
      expect(added.serialNumber, equals(3));
      // load 种子写入 + addRule 持久化
      verify(() => mockApi.setConfig('txt_toc_rules', any())).called(2);
    });

    test('updateRule 更新指定规则', () async {
      stubConfig();
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
      stubConfig();
      await readNotifier().load();

      await readNotifier().deleteRule(1);

      final state = readState();
      expect(state.rules.length, equals(2));
      expect(state.rules.any((r) => r.id == 1), isFalse);
    });

    test('setEnabled 切换启停', () async {
      stubConfig();
      await readNotifier().load();

      // 默认 id=3（英文 Chapter）为禁用，切换为启用
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
