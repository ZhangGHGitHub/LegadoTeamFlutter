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

/// 内存版 `txtTocRules` 表（B8：唯一存储是 FFI 的 txtTocRules 表）
class FakeTxtTocRulesRustApi extends MockRustApi {
  final List<Map<String, dynamic>> rows = [];
  var _nextId = 1;
  var importDefaultCalls = 0;

  /// 置真时 `txtTocRuleList` 抛错（覆盖加载失败分支）
  var failList = false;

  @override
  Future<List<Map<String, dynamic>>> txtTocRuleList() async {
    if (failList) throw Exception('读取失败');
    final ordered = List<Map<String, dynamic>>.from(rows)
      ..sort((a, b) {
        final bySerial = (a['serialNumber'] as int).compareTo(
          b['serialNumber'] as int,
        );
        return bySerial != 0
            ? bySerial
            : (a['id'] as int).compareTo(b['id'] as int);
      });
    return ordered.map((r) => Map<String, dynamic>.from(r)).toList();
  }

  @override
  Future<int> txtTocRuleAdd({
    required String name,
    required String rule,
    required String replacement,
    required bool enable,
    String? example,
    required int serialNumber,
  }) async {
    final order = serialNumber >= 0 ? serialNumber : rows.length;
    final id = _nextId++;
    rows.add({
      'id': id,
      'name': name,
      'rule': rule,
      'replacement': replacement,
      'serialNumber': order,
      'enable': enable,
      'example': example,
    });
    return id;
  }

  @override
  Future<bool> txtTocRuleUpdate({
    required int id,
    required String name,
    required String rule,
    required String replacement,
    required bool enable,
    String? example,
    required int serialNumber,
  }) async {
    final hits = rows.where((r) => r['id'] == id).toList();
    if (hits.isEmpty) return false;
    final row = hits.first;
    row['name'] = name;
    row['rule'] = rule;
    row['replacement'] = replacement;
    row['enable'] = enable;
    row['example'] = example;
    row['serialNumber'] = serialNumber;
    return true;
  }

  @override
  Future<bool> txtTocRuleDelete(int id) async {
    final before = rows.length;
    rows.removeWhere((r) => r['id'] == id);
    return rows.length < before;
  }

  @override
  Future<bool> txtTocRuleSetEnabled({
    required int id,
    required bool enabled,
  }) async {
    if (!rows.any((r) => r['id'] == id)) return false;
    for (final r in rows) {
      if (r['id'] == id) r['enable'] = enabled;
    }
    return true;
  }

  @override
  Future<int> txtTocRuleImport({
    required String jsonOrUrl,
    required String kind,
  }) async {
    final decoded = jsonDecode(jsonOrUrl);
    final items = decoded is List
        ? decoded.whereType<Map<String, dynamic>>().toList()
        : [decoded as Map<String, dynamic>];
    var count = 0;
    for (final item in items) {
      final name = (item['name'] ?? '').toString();
      if (name.isEmpty) continue;
      final idx = rows.indexWhere((r) => r['name'] == name);
      final record = {
        'id': idx >= 0 ? rows[idx]['id'] : _nextId++,
        'name': name,
        'rule': item['rule'] ?? '',
        'replacement': item['replacement'] ?? '',
        'serialNumber': item['serialNumber'] ?? 0,
        'enable': item['enable'] ?? true,
        'example': item['example'],
      };
      if (idx >= 0) {
        rows[idx] = record;
      } else {
        rows.add(record);
      }
      count++;
    }
    return count;
  }

  @override
  Future<int> txtTocRuleImportDefault() async {
    importDefaultCalls++;
    // 模拟 Rust 语义：删除默认行（负数 id）后重灌一条默认规则
    rows.removeWhere((r) => (r['id'] as int) < 0);
    rows.add({
      'id': -1,
      'name': '目录',
      'rule': r'^第.+章',
      'replacement': '',
      'serialNumber': 0,
      'enable': true,
      'example': null,
    });
    return 1;
  }
}

void main() {
  group('TxtTocRulesNotifier', () {
    late FakeTxtTocRulesRustApi mockApi;
    late ProviderContainer container;
    late Map<String, String> configStore;

    setUpAll(() {
      TestWidgetsFlutterBinding.ensureInitialized();
      registerFallbacks();
    });

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      mockApi = FakeTxtTocRulesRustApi();
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

    TxtTocRulesState readState() => container.read(txtTocRulesNotifierProvider);
    TxtTocRulesNotifier readNotifier() =>
        container.read(txtTocRulesNotifierProvider.notifier);

    test('初始状态为空', () {
      expect(readState().rules, isEmpty);
      expect(readState().isLoading, isFalse);
      expect(readState().error, isNull);
    });

    test('load 从 txtTocRules 表读取（不再读写 config:txt_toc_rules）', () async {
      mockApi.rows.add({
        'id': 9,
        'name': '自定义',
        'rule': r'^\d+',
        'replacement': '',
        'serialNumber': 0,
        'enable': true,
        'example': null,
      });

      await readNotifier().load();

      final state = readState();
      expect(state.isLoading, isFalse);
      expect(state.error, isNull);
      expect(state.rules.single.id, equals(9));
      expect(state.rules.single.name, equals('自定义'));
      expect(configStore.containsKey(kLegacyTxtTocRulesConfigKey), isFalse);
    });

    test('addRule 写入表并追加到末尾', () async {
      mockApi.rows.addAll([
        {
          'id': 1,
          'name': 'a',
          'rule': r'^a',
          'replacement': '',
          'serialNumber': 0,
          'enable': true,
          'example': null,
        },
        {
          'id': 2,
          'name': 'b',
          'rule': r'^b',
          'replacement': '',
          'serialNumber': 1,
          'enable': true,
          'example': null,
        },
      ]);
      await readNotifier().load();

      await readNotifier().addRule(const TxtTocRule(name: '新增', rule: r'^x'));

      final state = readState();
      expect(state.rules.length, equals(3));
      final added = state.rules.last;
      expect(added.name, equals('新增'));
      expect(added.serialNumber, equals(2));
      expect(mockApi.rows.length, equals(3));
    });

    test('updateRule 更新指定规则', () async {
      mockApi.rows.add({
        'id': 2,
        'name': '旧',
        'rule': r'^第',
        'replacement': '',
        'serialNumber': 1,
        'enable': true,
        'example': null,
      });
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
      mockApi.rows.addAll([
        {
          'id': 1,
          'name': 'a',
          'rule': r'^a',
          'replacement': '',
          'serialNumber': 0,
          'enable': true,
          'example': null,
        },
        {
          'id': 2,
          'name': 'b',
          'rule': r'^b',
          'replacement': '',
          'serialNumber': 1,
          'enable': true,
          'example': null,
        },
      ]);
      await readNotifier().load();

      await readNotifier().deleteRule(1);

      final state = readState();
      expect(state.rules.length, equals(1));
      expect(state.rules.any((r) => r.id == 1), isFalse);
    });

    test('setEnabled 切换启停', () async {
      mockApi.rows.add({
        'id': 3,
        'name': 'c',
        'rule': r'^c',
        'replacement': '',
        'serialNumber': 0,
        'enable': false,
        'example': null,
      });
      await readNotifier().load();

      await readNotifier().setEnabled(3, true);

      expect(readState().rules.firstWhere((r) => r.id == 3).enable, isTrue);
    });

    test('importDefaultRules 走 FFI 并保留用户自建规则', () async {
      mockApi.rows.add({
        'id': 7,
        'name': '用户规则',
        'rule': r'^用户',
        'replacement': '',
        'serialNumber': 0,
        'enable': true,
        'example': null,
      });
      await readNotifier().load();

      final n = await readNotifier().importDefaultRules();

      expect(n, equals(1));
      expect(mockApi.importDefaultCalls, equals(1));
      final names = readState().rules.map((r) => r.name);
      expect(names, contains('用户规则'));
      expect(names, contains('目录'));
    });

    test('load 把旧 config:txt_toc_rules 一次性导表并清键（B8 迁移）', () async {
      configStore[kLegacyTxtTocRulesConfigKey] = jsonEncode([
        {'name': '旧规则', 'rule': r'^旧'},
      ]);

      await readNotifier().load();

      expect(readState().rules.map((r) => r.name), contains('旧规则'));
      expect(
        configStore.containsKey(kLegacyTxtTocRulesConfigKey),
        isFalse,
        reason: '迁移成功后应删除旧配置键',
      );
    });

    test('load 旧配置非法时保留键且不阻断（不丢用户数据）', () async {
      configStore[kLegacyTxtTocRulesConfigKey] = '{not json';

      await readNotifier().load();

      expect(readState().isLoading, isFalse);
      expect(readState().error, isNotNull);
      expect(
        configStore.containsKey(kLegacyTxtTocRulesConfigKey),
        isTrue,
        reason: '解析失败时保留原键供排查',
      );
    });

    test('load 异常时记录 error', () async {
      mockApi.failList = true;

      await readNotifier().load();

      final state = readState();
      expect(state.isLoading, isFalse);
      expect(state.error, contains('读取失败'));
    });
  });
}
