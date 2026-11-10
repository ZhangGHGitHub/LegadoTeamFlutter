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
/// - 排序（批12：乐观更新 + `reorderReplaceRules` 全量落库，失败 `load()`
///   回滚并返回 false 供页面提示；不再做纯内存交换）
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
  ///
  /// [批12] 追加到列表末尾（`order = max+1`，对齐 Rust 侧排序语义；
  /// FFI 仅回传 id，本地按同一规则补齐 order 以保持展示一致）
  Future<ReplaceRule> addRule(ReplaceRule rule) async {
    final api = ref.read(bookApiProvider);
    final added = await api.addReplaceRule(rule);
    final nextOrder =
        state.rules.fold<int>(
          -1,
          (maxOrder, r) => r.order > maxOrder ? r.order : maxOrder,
        ) +
        1;
    final placed = added.copyWith(order: nextOrder);
    state = state.copyWith(rules: [...state.rules, placed]);
    return placed;
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

  // ===== [批12 | 2026-11-10] 排序写链路（全量重排，一次 FFI 调用） =====

  /// [批12 P3] 排序写链路串行门闩
  ///
  /// 连续拖动/置顶置底按调用顺序排队执行，避免在途请求与后续乐观更新
  /// 交错导致本地顺序与 DB 分叉。
  Future<void> _orderTail = Future<void>.value();

  /// 入队并串行执行一次排序写操作（队尾吞掉异常，后续操作仍可执行）
  Future<bool> _enqueueOrder(Future<bool> Function() action) {
    final result = _orderTail.then((_) => action());
    _orderTail = result.then<void>((_) {}, onError: (_, _) {});
    return result;
  }

  /// 拖拽排序
  ///
  /// [newIndex] 为 `ReorderableListView.onReorderItem` 已调整的目标索引
  /// （移除后的插入位置）。流程：乐观更新本地列表 → 一次全量
  /// `reorderReplaceRules` 落库 → 失败 `load()` 回滚。
  /// 返回 false 表示落库失败且顺序已回滚，由页面提示用户。
  Future<bool> reorder(int oldIndex, int newIndex) =>
      _enqueueOrder(() => _reorderNow(oldIndex, newIndex));

  /// 将指定规则批量置顶（重排数组后**一次**全量落库）
  ///
  /// 对标原版 `replace_rule_sel.xml` menu_top_sel；替代原「逐条 update」实现。
  Future<bool> moveToTop(List<int> ids) =>
      _enqueueOrder(() => _moveToTopNow(ids));

  /// 将指定规则批量置底（重排数组后**一次**全量落库）
  Future<bool> moveToBottom(List<int> ids) =>
      _enqueueOrder(() => _moveToBottomNow(ids));

  Future<bool> _reorderNow(int oldIndex, int newIndex) async {
    final rules = state.rules;
    if (oldIndex < 0 || oldIndex >= rules.length) return true;
    if (newIndex < 0 || newIndex >= rules.length) return true;
    if (oldIndex == newIndex) return true;
    final ordered = [...rules];
    final moved = ordered.removeAt(oldIndex);
    ordered.insert(newIndex, moved);
    return _commitOrder(ordered);
  }

  Future<bool> _moveToTopNow(List<int> ids) async {
    if (ids.isEmpty) return true;
    final selected = state.rules.where((r) => ids.contains(r.id)).toList();
    if (selected.isEmpty) return true;
    final rest = state.rules.where((r) => !ids.contains(r.id)).toList();
    return _commitOrder([...selected, ...rest]);
  }

  Future<bool> _moveToBottomNow(List<int> ids) async {
    if (ids.isEmpty) return true;
    final selected = state.rules.where((r) => ids.contains(r.id)).toList();
    if (selected.isEmpty) return true;
    final rest = state.rules.where((r) => !ids.contains(r.id)).toList();
    return _commitOrder([...rest, ...selected]);
  }

  /// 乐观应用目标顺序并一次全量落库；失败以 DB 为权威 `load()` 回滚
  Future<bool> _commitOrder(List<ReplaceRule> ordered) async {
    final renumbered = [
      for (var i = 0; i < ordered.length; i++) ordered[i].copyWith(order: i),
    ];
    state = state.copyWith(rules: renumbered);
    try {
      final api = ref.read(bookApiProvider);
      await api.reorderReplaceRules(renumbered.map((r) => r.id).toList());
      // 成功后本地 order 已与 DB 写入顺序一致（0..n-1）；串行门闩保证
      // 下一次排序基于本结果继续，不会与在途请求交错。
      return true;
    } catch (_) {
      // 非法集零写入/网络失败：DB 顺序未变，重读即恢复原顺序
      await load();
      return false;
    }
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
