import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/providers/dict/dict_notifier.dart';
import 'package:flutter_legado/src/providers/providers.dart';

import '../mocks/mocks.dart';

void main() {
  group('DictRule.buildUrl', () {
    test('将 {{key}} 占位符替换为查询单词', () {
      const rule = DictRule(
        name: '有道',
        urlRule: 'https://dict.youdao.com/w/{{key}}',
      );
      expect(
        rule.buildUrl('chapter'),
        equals('https://dict.youdao.com/w/chapter'),
      );
    });
  });

  group('DictNotifier', () {
    late MockRustApi mockApi;
    late ProviderContainer container;
    late Map<String, String?> configStore;

    setUpAll(() {
      TestWidgetsFlutterBinding.ensureInitialized();
      registerFallbacks();
    });

    setUp(() {
      SharedPreferences.setMockInitialValues({});
      mockApi = MockRustApi();
      configStore = {};
      // getConfig 回读 setConfig 写入值，模拟 Rust 配置库
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

    DictState readState() => container.read(dictNotifierProvider);
    DictNotifier readNotifier() => container.read(dictNotifierProvider.notifier);

    test('初始状态为空', () {
      final state = readState();
      expect(state.rules, isEmpty);
      expect(state.queriedWord, isNull);
      expect(state.result, isNull);
      expect(state.isLoading, isFalse);
    });

    test('loadRules 无持久化数据时写入默认规则', () async {
      await readNotifier().loadRules();

      final state = readState();
      expect(state.isLoading, isFalse);
      expect(state.error, isNull);
      expect(state.rules, isNotEmpty);
      expect(state.rules.first.name, equals('百度汉语'));
      verify(() => mockApi.setConfig('dict_rules', any())).called(1);
    });

    test('loadRules 解析已持久化规则（不重复写回）', () async {
      // 已完成默认导入版本，避免 assets 覆盖
      SharedPreferences.setMockInitialValues({
        kDictRuleVersionKey: kDictRuleVersion,
      });
      final stored = jsonEncode([
        {'name': '自定义', 'urlRule': 'https://x.com/{{key}}'},
      ]);
      configStore['dict_rules'] = stored;

      await readNotifier().loadRules();

      expect(readState().rules.single.name, equals('自定义'));
      verifyNever(() => mockApi.setConfig(any(), any()));
    });

    test('addRule 添加并持久化', () async {
      await readNotifier().addRule(
        const DictRule(
          name: '必应',
          urlRule: 'https://bing.com/dict?q={{key}}',
        ),
      );

      expect(readState().rules.single.name, equals('必应'));
      verify(() => mockApi.setConfig('dict_rules', any())).called(1);
    });

    test('deleteRule 删除指定下标规则', () async {
      await readNotifier().loadRules(); // 默认多条
      final before = readState().rules.length;
      expect(before, greaterThan(1));
      final secondName = readState().rules[1].name;

      await readNotifier().deleteRule(0);

      expect(readState().rules.length, equals(before - 1));
      expect(readState().rules.first.name, equals(secondName));
    });

    test('lookup 委托 Rust dictLookup 并解析（大小写归一化）', () async {
      when(() => mockApi.dictLookup(any())).thenAnswer((_) async => {
            'word': 'chapter',
            'phonetic': '/ˈtʃæptə(r)/',
            'definitions': ['n. 章，章节'],
          });

      await readNotifier().lookup('Chapter');

      final state = readState();
      expect(state.queriedWord, equals('chapter'));
      expect(state.isLoading, isFalse);
      expect(state.result, isNotNull);
      expect(state.result!.word, equals('chapter'));
      expect(state.result!.definitions, isNotEmpty);
      verify(() => mockApi.dictLookup('chapter')).called(1);
    });

    test('lookup 未收录词返回空 definitions（非异常）', () async {
      when(() => mockApi.dictLookup(any())).thenAnswer((_) async => {
            'word': 'zzz',
            'phonetic': '',
            'definitions': <String>[],
          });

      await readNotifier().lookup('zzz');

      final state = readState();
      expect(state.queriedWord, equals('zzz'));
      expect(state.result, isNotNull);
      expect(state.result!.definitions, isEmpty);
    });

    test('lookup 异常时兜底并记录 error', () async {
      when(() => mockApi.dictLookup(any())).thenThrow(Exception('ffi'));

      await readNotifier().lookup('chapter');

      final state = readState();
      expect(state.isLoading, isFalse);
      expect(state.result, isNull);
      expect(state.error, isNotNull);
    });

    test('lookup 空字符串被忽略（不触发契约）', () async {
      await readNotifier().lookup('   ');
      expect(readState().queriedWord, isNull);
      verifyNever(() => mockApi.dictLookup(any()));
    });
  });
}
