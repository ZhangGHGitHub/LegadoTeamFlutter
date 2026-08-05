import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;

import '../../bridge/ffi.dart';
import '../providers.dart';
import 'highlight_rules_state.dart';

export 'highlight_rules_state.dart';

/// 高亮规则列表 Riverpod Notifier
///
/// [审计修复 §4.3 第二批] JSON 解析与规则 CRUD 下沉至本层 — Qoder
///
/// 职责严格限定（对齐 UI_RESTRUCTURE_PLAN.md §0.2 铁律）：
/// - 调用 BookApi.highlightRule* → 接收纯数据 → 更新 immutable State
/// - JSON 解析在本层完成（UI 层仅消费类型化的 [HighlightRule]）
/// - 对标 Android 原版 HighlightRuleActivity 的加载/开关/删除/保存行为
class HighlightRulesNotifier extends Notifier<HighlightRulesState> {
  @override
  HighlightRulesState build() => const HighlightRulesState();

  /// 加载规则列表（Rust 侧按 sortOrder 升序返回）
  Future<void> load() async {
    state = state.copyWith(isLoading: true, clearError: true);
    try {
      final raw = await ref.read(bookApiProvider).highlightRuleList();
      state = state.copyWith(rules: _decode(raw), isLoading: false);
    } catch (e) {
      state = state.copyWith(
        rules: const [],
        isLoading: false,
        error: _mapError(e),
      );
    }
  }

  /// 切换规则启用状态（保存后刷新列表）
  Future<void> toggleEnabled(HighlightRule rule, bool enabled) async {
    await _save(rule.copyWith(isEnabled: enabled));
  }

  /// 删除规则（成功后刷新列表）
  Future<void> deleteRule(HighlightRule rule) async {
    try {
      await ref.read(bookApiProvider).highlightRuleDelete(id: rule.id);
      await load();
    } catch (e) {
      state = state.copyWith(error: _mapError(e));
    }
  }

  /// 保存规则（新增或编辑，成功后刷新列表）
  Future<void> saveRule(HighlightRule rule) async {
    await _save(rule);
  }

  Future<void> _save(HighlightRule rule) async {
    try {
      await ref
          .read(bookApiProvider)
          .highlightRuleSave(ruleJson: jsonEncode(rule.toJson()));
      await load();
    } catch (e) {
      state = state.copyWith(error: _mapError(e));
    }
  }

  /// 解析规则 JSON 数组（容错：非法条目跳过）
  List<HighlightRule> _decode(String raw) {
    if (raw.isEmpty || raw == 'null') return const [];
    final decoded = jsonDecode(raw);
    if (decoded is! List) return const [];
    return decoded
        .whereType<Map<String, dynamic>>()
        .map(HighlightRule.fromJson)
        .toList();
  }

  /// 统一错误映射
  String _mapError(Object e) {
    if (e is BridgeError) return e.message;
    return e.toString();
  }
}

/// 高亮规则 Notifier 全局 Provider
///
/// 使用方式：
/// ```dart
/// final state = ref.watch(highlightRulesNotifierProvider);
/// ref.read(highlightRulesNotifierProvider.notifier).load();
/// ```
final highlightRulesNotifierProvider =
    NotifierProvider<HighlightRulesNotifier, HighlightRulesState>(
  HighlightRulesNotifier.new,
);
