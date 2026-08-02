import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;

import '../../bridge/ffi.dart';
import '../../models/models.dart';
import '../providers.dart';
import 'txt_toc_rules_state.dart';

export 'txt_toc_rules_state.dart';

/// TXT 目录规则 Riverpod Notifier
///
/// 职责严格限定（对齐 UI_RESTRUCTURE_PLAN.md §0.2 铁律）：
/// - 规则列表经 BookApi.getConfig/setConfig 持久化到 Rust 配置库，键 `txt_toc_rules`，
///   不再使用内存态（重启即丢失）。
/// - 规则 CRUD 与启停透传；首次加载若无持久化数据则写入内置默认规则。
/// - 不含章节拆分/正则匹配业务逻辑（实际 TXT 解析由 Rust parseTxt 完成；
///   页面的「在线测试」仅为本地正则预览，不参与数据流）。
class TxtTocRulesNotifier extends Notifier<TxtTocRulesState> {
  /// 配置键
  static const _configKey = 'txt_toc_rules';

  /// 内置默认规则（首次使用时写入）
  static const _defaultRules = [
    TxtTocRule(
      id: 1,
      name: '中文章节',
      rule: r'^第\s*[0-9一二三四五六七八九十百千零两]+\s*[章节卷集部篇回则话]',
      serialNumber: 0,
      enable: true,
    ),
    TxtTocRule(
      id: 2,
      name: '数字编号',
      rule: r'^\s*\d+[\.、．]\s*\S+',
      serialNumber: 1,
      enable: true,
    ),
    TxtTocRule(
      id: 3,
      name: '英文 Chapter',
      rule: r'^\s*Chapter\s+\d+',
      serialNumber: 2,
      enable: false,
    ),
  ];

  @override
  TxtTocRulesState build() => const TxtTocRulesState();

  /// 加载规则列表；无持久化数据时写入内置默认规则
  Future<void> load() async {
    state = state.copyWith(isLoading: true, error: null);
    try {
      final api = ref.read(bookApiProvider);
      final raw = await api.getConfig(_configKey);
      List<TxtTocRule> rules;
      if (raw == null || raw.isEmpty) {
        rules = _defaultRules;
        await api.setConfig(_configKey, _encode(rules));
      } else {
        rules = _decode(raw);
      }
      state = state.copyWith(rules: rules, isLoading: false);
    } catch (e) {
      state = state.copyWith(error: _mapError(e), isLoading: false);
    }
  }

  /// 添加规则（自动生成 id 与 serialNumber）
  Future<void> addRule(TxtTocRule rule) async {
    final nextId =
        state.rules.fold<int>(0, (m, r) => r.id > m ? r.id : m) + 1;
    final added = rule.copyWith(id: nextId, serialNumber: state.rules.length);
    final rules = [...state.rules, added];
    state = state.copyWith(rules: rules);
    await _persist(rules);
  }

  /// 更新规则
  Future<void> updateRule(TxtTocRule rule) async {
    final idx = state.rules.indexWhere((r) => r.id == rule.id);
    if (idx < 0) return;
    final rules = [...state.rules];
    rules[idx] = rule;
    state = state.copyWith(rules: rules);
    await _persist(rules);
  }

  /// 删除规则
  Future<void> deleteRule(int id) async {
    final rules = state.rules.where((r) => r.id != id).toList();
    state = state.copyWith(rules: rules);
    await _persist(rules);
  }

  /// 启用/禁用规则
  Future<void> setEnabled(int id, bool enable) async {
    final idx = state.rules.indexWhere((r) => r.id == id);
    if (idx < 0) return;
    final rules = [...state.rules];
    rules[idx] = rules[idx].copyWith(enable: enable);
    state = state.copyWith(rules: rules);
    await _persist(rules);
  }

  /// 持久化全量规则到 Rust 配置库
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

  /// 统一错误映射
  String _mapError(Object e) {
    if (e is BridgeError) return e.message;
    return e.toString();
  }
}

/// TXT 目录规则 Notifier 全局 Provider
///
/// 使用方式：
/// ```dart
/// final state = ref.watch(txtTocRulesNotifierProvider);
/// ref.read(txtTocRulesNotifierProvider.notifier).load();
/// ```
final txtTocRulesNotifierProvider =
    NotifierProvider<TxtTocRulesNotifier, TxtTocRulesState>(
  TxtTocRulesNotifier.new,
);
