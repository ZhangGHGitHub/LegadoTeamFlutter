import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;

import '../../bridge/ffi.dart';
import '../../models/models.dart';
import '../providers.dart';
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
        state = state.copyWith(error: e.toString());
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
