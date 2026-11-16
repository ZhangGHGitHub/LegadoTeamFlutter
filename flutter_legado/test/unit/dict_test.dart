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

/// 内存版 `dictRules` 表（B7：唯一存储是 FFI 的 dictRules 表）
///
/// 模拟 Rust `DictRuleRepository` 的语义：
/// - `dictRuleList` 空表时注入原版默认 5 源（seed）；
/// - `dictRuleAdd` 名称重复报错（UNIQUE 约束）；
/// - `dictRuleImport` 按 name REPLACE（同名覆盖保留 id、异名插入）；
/// - `dictRuleDelete` 按 id 删除。
class FakeDictRulesRustApi extends MockRustApi {
  final List<Map<String, dynamic>> rows = [];
  var _nextId = 1;

  void seed(List<Map<String, dynamic>> defaults) {
    for (final rule in defaults) {
      rows.add({...rule, 'id': _nextId++});
    }
  }

  @override
  Future<List<Map<String, dynamic>>> dictRuleList() async {
    if (rows.isEmpty) {
      seed(const [
        {
          'name': '百度汉语',
          'urlRule': 'https://dict.baidu.com/s?wd={{key}}',
          'showRule': '',
          'enabled': true,
          'sortNumber': 0,
        },
      ]);
    }
    return [
      for (final row in rows)
        {
          'id': row['id'],
          'name': row['name'] ?? '',
          'urlRule': row['urlRule'] ?? '',
          'showRule': row['showRule'] ?? '',
          'enabled': row['enabled'] ?? true,
          'sortNumber': row['sortNumber'] ?? 0,
        },
    ];
  }

  @override
  Future<int> dictRuleAdd({
    required String name,
    required String urlRule,
    required String showRule,
  }) async {
    if (rows.any((r) => r['name'] == name)) {
      throw Exception('UNIQUE constraint failed: dictRules.name');
    }
    final id = _nextId++;
    rows.add({
      'id': id,
      'name': name,
      'urlRule': urlRule,
      'showRule': showRule,
      'enabled': true,
      'sortNumber': 0,
    });
    return id;
  }

  @override
  Future<bool> dictRuleDelete(int id) async {
    final before = rows.length;
    rows.removeWhere((r) => (r['id'] as num?)?.toInt() == id);
    return rows.length != before;
  }

  @override
  Future<int> dictRuleImport({
    required String jsonOrUrl,
    required String kind,
  }) async {
    final decoded = jsonDecode(jsonOrUrl);
    final items = decoded is List
        ? decoded.whereType<Map<String, dynamic>>().toList()
        : [decoded as Map<String, dynamic>];
    for (final item in items) {
      final name = (item['name'] ?? '').toString();
      if (name.isEmpty) continue;
      final idx = rows.indexWhere((r) => r['name'] == name);
      final record = {
        'id': idx >= 0 ? rows[idx]['id'] : _nextId++,
        'name': name,
        'urlRule': item['urlRule'] ?? '',
        'showRule': item['showRule'] ?? '',
        'enabled': item['enabled'] ?? true,
        'sortNumber': item['sortNumber'] ?? 0,
      };
      if (idx >= 0) {
        rows[idx] = record;
      } else {
        rows.add(record);
      }
    }
    return items.length;
  }
}

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
    late FakeDictRulesRustApi mockApi;
    late ProviderContainer container;
    late Map<String, String> configStore;

    setUpAll(() {
      TestWidgetsFlutterBinding.ensureInitialized();
      registerFallbacks();
    });

    setUp(() {
      SharedPreferences.setMockInitialValues({});
      mockApi = FakeDictRulesRustApi();
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
      when(() => mockApi.deleteConfig(any())).thenAnswer((inv) async {
        configStore.remove(inv.positionalArguments[0] as String);
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

    test('loadRules 从 dictRules 表读取（空表由 Rust 侧 seed）', () async {
      await readNotifier().loadRules();

      final state = readState();
      expect(state.isLoading, isFalse);
      expect(state.error, isNull);
      expect(state.rules, isNotEmpty);
      expect(state.rules.first.name, equals('百度汉语'));
      // 不再写 config:dict_rules
      expect(configStore.containsKey(kLegacyDictRulesConfigKey), isFalse);
    });

    test('addRule 写入 dictRules 表并可被列表读回', () async {
      await readNotifier().addRule(
        const DictRule(
          name: '必应',
          urlRule: 'https://bing.com/dict?q={{key}}',
        ),
      );

      expect(readState().rules.map((r) => r.name), contains('必应'));
      expect(mockApi.rows.map((r) => r['name']), contains('必应'));
    });

    test('addRule 名称重复抛错且记录 error（不再静默）', () async {
      await readNotifier().addRule(
        const DictRule(name: '重复源', urlRule: 'https://a.com/{{key}}'),
      );
      await expectLater(
        readNotifier().addRule(
          const DictRule(name: '重复源', urlRule: 'https://b.com/{{key}}'),
        ),
        throwsA(isA<Exception>()),
      );
      expect(readState().error, isNotNull);
    });

    test('deleteRule 按下标映射到行 id 删除', () async {
      // 至少两条：Rust `dictRuleList` 在表为空时会重新 seed 默认源
      await readNotifier().addRule(
        const DictRule(name: '待删', urlRule: 'https://del.com/{{key}}'),
      );
      await readNotifier().addRule(
        const DictRule(name: '保留', urlRule: 'https://keep.com/{{key}}'),
      );
      await readNotifier().loadRules();
      final before = readState().rules.length;
      expect(before, greaterThan(1));
      final targetId = (mockApi.rows.first['id'] as num).toInt();

      await readNotifier().deleteRule(0);

      expect(readState().rules.length, equals(before - 1));
      expect(mockApi.rows.any((r) => r['id'] == targetId), isFalse);
    });

    test('loadRules 把旧 config:dict_rules 一次性导表并清键（B7 迁移）', () async {
      configStore[kLegacyDictRulesConfigKey] = jsonEncode([
        {'name': '旧规则', 'urlRule': 'https://old.com/{{key}}'},
      ]);

      await readNotifier().loadRules();

      expect(readState().rules.map((r) => r.name), contains('旧规则'));
      expect(
        configStore.containsKey(kLegacyDictRulesConfigKey),
        isFalse,
        reason: '迁移成功后应删除旧配置键',
      );
    });

    test('loadRules 旧配置非法时保留键且不阻断（不丢用户数据）', () async {
      configStore[kLegacyDictRulesConfigKey] = '{not json';

      await readNotifier().loadRules();

      expect(readState().isLoading, isFalse);
      expect(readState().error, isNotNull);
      expect(
        configStore.containsKey(kLegacyDictRulesConfigKey),
        isTrue,
        reason: '解析失败时保留原键供排查',
      );
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
