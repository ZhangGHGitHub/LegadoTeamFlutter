import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:shared_preferences/shared_preferences.dart';

import '../../bridge/ffi.dart';
import '../../models/models.dart';
import '../../services/book_api.dart';
import '../providers.dart';
import 'txt_toc_rules_state.dart';

export 'txt_toc_rules_state.dart';

/// 对齐 Android `LocalConfig.needUpTxtTocRule` 的版本号
const kTxtTocRuleVersionKey = 'txtTocRuleVersion';
const kTxtTocRuleVersion = 1;

/// 默认 TXT 目录规则（对齐 `app/src/main/assets/defaultData/txtTocRule.json`）
const kDefaultTxtTocRulesAsset = 'assets/default_data/txtTocRule.json';

/// 对齐 Android `DefaultData.importDefaultTocRules`：删除默认 id(<0) 后灌入原版规则。
///
/// [replaceAll] 为 true 时整表覆盖（首启从错误内置默认迁移时用）。
Future<int> syncDefaultTxtTocRules(
  BookApi api, {
  String? jsonOverride,
  bool replaceAll = false,
}) async {
  final text =
      jsonOverride ?? await rootBundle.loadString(kDefaultTxtTocRulesAsset);
  final list = jsonDecode(text) as List<dynamic>;
  final defaults = list
      .whereType<Map<String, dynamic>>()
      .map(TxtTocRule.fromJson)
      .toList();

  List<TxtTocRule> merged;
  if (replaceAll) {
    merged = defaults;
  } else {
    final raw = await api.getConfig('txt_toc_rules');
    final existing = <TxtTocRule>[];
    if (raw != null && raw.isNotEmpty) {
      final decoded = jsonDecode(raw) as List<dynamic>;
      for (final item in decoded.whereType<Map<String, dynamic>>()) {
        final rule = TxtTocRule.fromJson(item);
        // 对标 deleteDefault：仅移除 id < 0 的默认规则，保留用户自定义
        if (rule.id >= 0) existing.add(rule);
      }
    }
    merged = [...defaults, ...existing];
  }
  await api.setConfig(
    'txt_toc_rules',
    jsonEncode(merged.map((r) => r.toJson()).toList()),
  );
  return defaults.length;
}

/// TXT 目录规则 Riverpod Notifier
///
/// 规则列表经 BookApi.getConfig/setConfig 持久化，键 `txt_toc_rules`。
/// 首启/「导入默认」对齐 Android DefaultData.txtTocRules。
class TxtTocRulesNotifier extends Notifier<TxtTocRulesState> {
  static const _configKey = 'txt_toc_rules';

  @override
  TxtTocRulesState build() => const TxtTocRulesState();

  /// 加载规则列表；首启写入原版默认规则
  Future<void> load() async {
    state = state.copyWith(isLoading: true, error: null);
    try {
      final api = ref.read(bookApiProvider);
      await _ensureDefaultTxtTocRules(api);
      final raw = await api.getConfig(_configKey);
      final rules = (raw == null || raw.isEmpty) ? <TxtTocRule>[] : _decode(raw);
      state = state.copyWith(rules: rules, isLoading: false);
    } catch (e) {
      state = state.copyWith(error: _mapError(e), isLoading: false);
    }
  }

  Future<void> _ensureDefaultTxtTocRules(BookApi api) async {
    final prefs = await SharedPreferences.getInstance();
    final version = prefs.getInt(kTxtTocRuleVersionKey) ?? 0;
    if (version >= kTxtTocRuleVersion) return;
    // 版本 0→1：覆盖错误内置默认（id 1/2/3），对齐原版 assets
    await syncDefaultTxtTocRules(api, replaceAll: true);
    await prefs.setInt(kTxtTocRuleVersionKey, kTxtTocRuleVersion);
  }

  /// 菜单「导入默认」：覆盖默认规则（保留用户自定义 id>=0）
  Future<int> importDefaultRules() async {
    final api = ref.read(bookApiProvider);
    final n = await syncDefaultTxtTocRules(api);
    final raw = await api.getConfig(_configKey);
    final rules = (raw == null || raw.isEmpty) ? <TxtTocRule>[] : _decode(raw);
    state = state.copyWith(rules: rules, error: null);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(kTxtTocRuleVersionKey, kTxtTocRuleVersion);
    return n;
  }

  Future<void> addRule(TxtTocRule rule) async {
    final nextId =
        state.rules.fold<int>(0, (m, r) => r.id > m ? r.id : m) + 1;
    final added = rule.copyWith(id: nextId, serialNumber: state.rules.length);
    final rules = [...state.rules, added];
    state = state.copyWith(rules: rules);
    await _persist(rules);
  }

  Future<void> updateRule(TxtTocRule rule) async {
    final idx = state.rules.indexWhere((r) => r.id == rule.id);
    if (idx < 0) return;
    final rules = [...state.rules];
    rules[idx] = rule;
    state = state.copyWith(rules: rules);
    await _persist(rules);
  }

  Future<void> deleteRule(int id) async {
    final rules = state.rules.where((r) => r.id != id).toList();
    state = state.copyWith(rules: rules);
    await _persist(rules);
  }

  Future<void> setEnabled(int id, bool enable) async {
    final idx = state.rules.indexWhere((r) => r.id == id);
    if (idx < 0) return;
    final rules = [...state.rules];
    rules[idx] = rules[idx].copyWith(enable: enable);
    state = state.copyWith(rules: rules);
    await _persist(rules);
  }

  Future<void> _persist(List<TxtTocRule> rules) async {
    try {
      await ref.read(bookApiProvider).setConfig(_configKey, _encode(rules));
    } catch (e) {
      state = state.copyWith(error: _mapError(e));
    }
  }

  String _encode(List<TxtTocRule> rules) =>
      jsonEncode(rules.map((r) => r.toJson()).toList());

  List<TxtTocRule> _decode(String raw) {
    final list = jsonDecode(raw) as List<dynamic>;
    return list
        .whereType<Map<String, dynamic>>()
        .map(TxtTocRule.fromJson)
        .toList();
  }

  String _mapError(Object e) {
    if (e is BridgeError) return e.message;
    return e.toString();
  }
}

final txtTocRulesNotifierProvider =
    NotifierProvider<TxtTocRulesNotifier, TxtTocRulesState>(
  TxtTocRulesNotifier.new,
);
