import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

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

    setUpAll(registerFallbacks);

    setUp(() {
      mockApi = MockRustApi();
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
      when(() => mockApi.getConfig(any())).thenAnswer((_) async => null);
      when(() => mockApi.setConfig(any(), any())).thenAnswer((_) async {});

      await readNotifier().loadRules();

      final state = readState();
      expect(state.isLoading, isFalse);
      expect(state.rules.length, equals(2));
      expect(state.rules.first.name, equals('有道词典'));
      verify(() => mockApi.setConfig('dict_rules', any())).called(1);
    });

    test('loadRules 解析已持久化规则（不重复写回）', () async {
      final stored = jsonEncode([
        {'name': '自定义', 'urlRule': 'https://x.com/{{key}}'},
      ]);
      when(() => mockApi.getConfig(any())).thenAnswer((_) async => stored);

      await readNotifier().loadRules();

      expect(readState().rules.single.name, equals('自定义'));
      verifyNever(() => mockApi.setConfig(any(), any()));
    });

    test('addRule 添加并持久化', () async {
      when(() => mockApi.setConfig(any(), any())).thenAnswer((_) async {});

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
      when(() => mockApi.getConfig(any())).thenAnswer((_) async => null);
      when(() => mockApi.setConfig(any(), any())).thenAnswer((_) async {});
      await readNotifier().loadRules(); // 2 条默认

      await readNotifier().deleteRule(0);

      expect(readState().rules.single.name, equals('剑桥词典'));
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
