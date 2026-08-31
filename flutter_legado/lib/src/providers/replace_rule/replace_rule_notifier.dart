import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;

import '../../bridge/ffi.dart';
import '../../models/models.dart';
import '../providers.dart';
import '../../utils/error_message.dart';
import 'replace_rule_state.dart';

export 'replace_rule_state.dart';

/// 替换规则 Riverpod Notifier
///
/// 职责严格限定（对齐旧 ReplaceRuleProvider）：
/// - 调用 BookApi → 接收纯数据 → 更新 immutable State
/// - 管理列表加载三态（loading/error/data）
/// - 规则 CRUD 与启停透传
/// - 本地排序（moveUp/moveDown）
class ReplaceRuleNotifier extends Notifier<ReplaceRuleState> {
  @override
  ReplaceRuleState build() {
    // 原 ReplaceRuleProvider 不在构造时自动加载，由页面 initState 触发 load()
    return const ReplaceRuleState();
  }

  /// 加载所有替换规则
  Future<void> load() async {
    state = state.copyWith(loading: true, error: null);
    try {
      final api = ref.read(bookApiProvider);
      final rules = await api.getReplaceRules();
      state = state.copyWith(rules: rules);
    } catch (e) {
      if (e is BridgeError) {
        state = state.copyWith(error: e.message);
      } else {
        state = state.copyWith(error: errorMessage(e));
      }
    } finally {
      state = state.copyWith(loading: false);
    }
  }

  /// 添加替换规则
  Future<ReplaceRule> addRule(ReplaceRule rule) async {
    final api = ref.read(bookApiProvider);
    final added = await api.addReplaceRule(rule);
    state = state.copyWith(rules: [...state.rules, added]);
    return added;
  }

  /// 更新替换规则
  Future<void> updateRule(ReplaceRule rule) async {
    final api = ref.read(bookApiProvider);
    await api.updateReplaceRule(rule);
    final idx = state.rules.indexWhere((r) => r.id == rule.id);
    if (idx >= 0) {
      final list = [...state.rules];
      list[idx] = rule;
      state = state.copyWith(rules: list);
    }
  }

  /// 删除替换规则
  Future<void> deleteRule(int id) async {
    final api = ref.read(bookApiProvider);
    await api.deleteReplaceRule(id);
    state = state.copyWith(
      rules: state.rules.where((r) => r.id != id).toList(),
    );
  }

  /// 启用/禁用替换规则
  Future<void> setEnabled(int id, bool enabled) async {
    final api = ref.read(bookApiProvider);
    await api.setReplaceRuleEnabled(id, enabled);
    final idx = state.rules.indexWhere((r) => r.id == id);
    if (idx >= 0) {
      final list = [...state.rules];
      list[idx] = list[idx].copyWith(isEnabled: enabled);
      state = state.copyWith(rules: list);
    }
  }

  /// 上移规则
  void moveUp(int index) {
    if (index <= 0 || index >= state.rules.length) return;
    final list = [...state.rules];
    final current = list[index];
    final prev = list[index - 1];
    list[index] = prev.copyWith(order: current.order);
    list[index - 1] = current.copyWith(order: prev.order);
    list.sort((a, b) => a.order.compareTo(b.order));
    state = state.copyWith(rules: list);
  }

  /// 下移规则
  void moveDown(int index) {
    if (index < 0 || index >= state.rules.length - 1) return;
    final list = [...state.rules];
    final current = list[index];
    final next = list[index + 1];
    list[index] = next.copyWith(order: current.order);
    list[index + 1] = current.copyWith(order: next.order);
    list.sort((a, b) => a.order.compareTo(b.order));
    state = state.copyWith(rules: list);
  }

  // [UI-fix v2.0.2 | 2026-08-06] 批量置顶/置底（对标原版
  // replace_rule_sel.xml menu_top_sel/menu_bottom_sel），重排后逐条持久化 — Qoder

  /// 将指定规则批量置顶并持久化 order
  Future<void> moveToTop(List<int> ids) async {
    if (ids.isEmpty) return;
    final selected = state.rules.where((r) => ids.contains(r.id)).toList();
    final rest = state.rules.where((r) => !ids.contains(r.id)).toList();
    await _persistOrder([...selected, ...rest]);
  }

  /// 将指定规则批量置底并持久化 order
  Future<void> moveToBottom(List<int> ids) async {
    if (ids.isEmpty) return;
    final selected = state.rules.where((r) => ids.contains(r.id)).toList();
    final rest = state.rules.where((r) => !ids.contains(r.id)).toList();
    await _persistOrder([...rest, ...selected]);
  }

  /// 按目标顺序重排 order（连续编号）并逐条持久化
  Future<void> _persistOrder(List<ReplaceRule> ordered) async {
    final api = ref.read(bookApiProvider);
    final updated = <ReplaceRule>[];
    for (var i = 0; i < ordered.length; i++) {
      final rule = ordered[i].copyWith(order: i);
      if (rule.order != ordered[i].order) {
        await api.updateReplaceRule(rule);
      }
      updated.add(rule);
    }
    state = state.copyWith(rules: updated);
  }
}

/// 替换规则 Notifier 全局 Provider
///
/// 使用方式：
/// ```dart
/// final state = ref.watch(replaceRuleNotifierProvider);
/// ref.read(replaceRuleNotifierProvider.notifier).load();
/// ```
final replaceRuleNotifierProvider =
    NotifierProvider<ReplaceRuleNotifier, ReplaceRuleState>(
  ReplaceRuleNotifier.new,
);
