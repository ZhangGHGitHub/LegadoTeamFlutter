import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:shared_preferences/shared_preferences.dart';

import '../../bridge/ffi.dart';
import '../../models/models.dart';
import '../../services/book_api.dart';
import '../providers.dart';
import 'dict_state.dart';

export 'dict_state.dart';

/// 对齐 Android `LocalConfig.needUpDictRule` 的版本号
const kDictRuleVersionKey = 'dictRuleVersion';
const kDictRuleVersion = 1;

/// 默认字典规则资源（对齐 `app/src/main/assets/defaultData/dictRules.json`）
const kDefaultDictRulesAsset = 'assets/default_data/dictRules.json';

/// 对齐 Android `DefaultData.importDefaultDictRules`：覆盖写入原版默认字典规则。
Future<int> syncDefaultDictRules(
  BookApi api, {
  String? jsonOverride,
}) async {
  final text =
      jsonOverride ?? await rootBundle.loadString(kDefaultDictRulesAsset);
  final list = jsonDecode(text) as List<dynamic>;
  final rules = list
      .whereType<Map<String, dynamic>>()
      .map(DictRule.fromJson)
      .toList();
  await api.setConfig('dict_rules', jsonEncode(rules.map((r) => r.toJson()).toList()));
  return rules.length;
}

/// 字典查询页 Riverpod Notifier
///
/// 职责严格限定（对齐 UI_RESTRUCTURE_PLAN.md §0.2 铁律）：
/// - 在线词典规则经 BookApi.getConfig/setConfig 持久化到 Rust 配置库，键 `dict_rules`，
///   不再使用 SharedPreferences。
/// - 首启/版本升级灌入原版 `dictRules.json`（对标 DefaultData.upVersion）。
/// - 词典释义查询经 `BookApi.dictLookup` 委托 Rust。
class DictNotifier extends Notifier<DictState> {
  /// 配置键
  static const _configKey = 'dict_rules';

  @override
  DictState build() => const DictState();

  /// 加载在线词典规则；首启写入原版默认规则
  Future<void> loadRules() async {
    state = state.copyWith(isLoading: true, error: null);
    try {
      final api = ref.read(bookApiProvider);
      await _ensureDefaultDictRules(api);
      final raw = await api.getConfig(_configKey);
      final rules = (raw == null || raw.isEmpty) ? <DictRule>[] : _decode(raw);
      state = state.copyWith(rules: rules, isLoading: false);
    } catch (e) {
      state = state.copyWith(error: _mapError(e), isLoading: false);
    }
  }

  /// 首启/版本升级导入默认字典规则（对标 DefaultData.upVersion + importDefaultDictRules）
  Future<void> _ensureDefaultDictRules(BookApi api) async {
    final prefs = await SharedPreferences.getInstance();
    final version = prefs.getInt(kDictRuleVersionKey) ?? 0;
    if (version >= kDictRuleVersion) return;
    await syncDefaultDictRules(api);
    await prefs.setInt(kDictRuleVersionKey, kDictRuleVersion);
  }

  /// 菜单「导入默认」：立即覆盖为原版默认内容
  Future<int> importDefaultRules() async {
    final api = ref.read(bookApiProvider);
    final n = await syncDefaultDictRules(api);
    final raw = await api.getConfig(_configKey);
    final rules = (raw == null || raw.isEmpty) ? <DictRule>[] : _decode(raw);
    state = state.copyWith(rules: rules, error: null);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(kDictRuleVersionKey, kDictRuleVersion);
    return n;
  }

  /// 添加在线词典规则
  Future<void> addRule(DictRule rule) async {
    final rules = [...state.rules, rule];
    state = state.copyWith(rules: rules);
    await _persist(rules);
  }

  /// 删除指定下标的在线词典规则
  Future<void> deleteRule(int index) async {
    if (index < 0 || index >= state.rules.length) return;
    final rules = [...state.rules]..removeAt(index);
    state = state.copyWith(rules: rules);
    await _persist(rules);
  }

  /// 查询单词（经 BookApi.dictLookup 委托 Rust）
  Future<void> lookup(String word) async {
    final key = word.trim().toLowerCase();
    if (key.isEmpty) return;
    state = state.copyWith(
      queriedWord: key,
      result: null,
      isLoading: true,
      error: null,
    );
    try {
      final raw = await ref.read(bookApiProvider).dictLookup(key);
      state = state.copyWith(
        result: DictEntry.fromJson(raw),
        isLoading: false,
      );
    } catch (e) {
      state = state.copyWith(error: _mapError(e), isLoading: false);
    }
  }

  Future<void> _persist(List<DictRule> rules) async {
    try {
      await ref.read(bookApiProvider).setConfig(_configKey, _encode(rules));
    } catch (e) {
      state = state.copyWith(error: _mapError(e));
    }
  }

  String _encode(List<DictRule> rules) =>
      jsonEncode(rules.map((r) => r.toJson()).toList());

  List<DictRule> _decode(String raw) {
    final list = jsonDecode(raw) as List<dynamic>;
    return list
        .whereType<Map<String, dynamic>>()
        .map(DictRule.fromJson)
        .toList();
  }

  String _mapError(Object e) {
    if (e is BridgeError) return e.message;
    return e.toString();
  }
}

final dictNotifierProvider = NotifierProvider<DictNotifier, DictState>(
  DictNotifier.new,
);
