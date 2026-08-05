import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;

import '../../bridge/ffi.dart';
import '../../models/models.dart';
import '../providers.dart';

/// 规则订阅列表状态
class RuleSubState {
  final bool loading;
  final String? error;

  /// 订阅列表（按 customOrder 排序，与 Rust list_subs_db 一致）
  final List<RuleSub> subs;

  const RuleSubState({
    this.loading = false,
    this.error,
    this.subs = const [],
  });

  RuleSubState copyWith({
    bool? loading,
    String? error,
    bool clearError = false,
    List<RuleSub>? subs,
  }) {
    return RuleSubState(
      loading: loading ?? this.loading,
      error: clearError ? null : (error ?? this.error),
      subs: subs ?? this.subs,
    );
  }
}

/// 规则订阅 Notifier（接通契约 §2.39 ruleSub* 七方法）
///
/// 对标原版 RuleSubActivity 数据职责：列表 CRUD / 拖拽排序 /
/// 启用切换 / 检查更新 / 应用更新。URL 重复校验在 UI 层
/// （对标原版 findByUrl 前置检查），本层提供 [findDuplicate]。
class RuleSubNotifier extends Notifier<RuleSubState> {
  @override
  RuleSubState build() => const RuleSubState();

  /// 加载订阅列表（对标 initData flowAll）
  Future<void> loadSubs() async {
    state = state.copyWith(loading: state.subs.isEmpty, clearError: true);
    try {
      final api = ref.read(bookApiProvider);
      final list = await api.ruleSubList();
      final subs = list.map(RuleSub.fromJson).toList()
        ..sort((a, b) => a.customOrder.compareTo(b.customOrder));
      state = state.copyWith(subs: subs, loading: false);
    } catch (e) {
      state = state.copyWith(error: _mapError(e), loading: false);
    }
  }

  /// 查找 URL 重复的订阅（对标原版 findByUrl，排除自身）
  RuleSub? findDuplicate(String url, {int excludeId = 0}) {
    for (final sub in state.subs) {
      if (sub.url == url && sub.id != excludeId) return sub;
    }
    return null;
  }

  /// 新增/更新订阅（对标原版 okButton 保存；新增时 customOrder 追加到末尾）
  Future<void> saveSub(RuleSub sub) async {
    try {
      final api = ref.read(bookApiProvider);
      final effective = sub.id > 0
          ? sub
          : sub.copyWith(
              customOrder: state.subs.isEmpty
                  ? 1
                  : state.subs.map((s) => s.customOrder).reduce(
                        (a, b) => a > b ? a : b,
                      ) +
                      1,
              createdAt: sub.createdAt > 0
                  ? sub.createdAt
                  : DateTime.now().millisecondsSinceEpoch,
            );
      await api.ruleSubSave(subJson: jsonEncode(effective.toJson()));
      await loadSubs();
    } catch (e) {
      state = state.copyWith(error: _mapError(e));
    }
  }

  /// 删除订阅（对标原版 delSubscription）
  Future<void> deleteSub(int id) async {
    try {
      final api = ref.read(bookApiProvider);
      await api.ruleSubDelete(id: id);
      state = state.copyWith(
        subs: state.subs.where((s) => s.id != id).toList(),
      );
    } catch (e) {
      state = state.copyWith(error: _mapError(e));
    }
  }

  /// 切换启用状态（Rust 轨扩展，驱动自动更新调度开关）
  Future<void> setEnabled(int id, bool enabled) async {
    final index = state.subs.indexWhere((s) => s.id == id);
    if (index == -1) return;
    try {
      final api = ref.read(bookApiProvider);
      await api.ruleSubSetEnabled(id: id, enabled: enabled);
      final subs = List<RuleSub>.of(state.subs);
      subs[index] = subs[index].copyWith(isEnabled: enabled);
      state = state.copyWith(subs: subs);
    } catch (e) {
      state = state.copyWith(error: _mapError(e));
    }
  }

  /// 拖拽排序持久化（对标原版 swap + upOrder：按新顺序重写 customOrder）
  Future<void> reorder(int oldIndex, int newIndex) async {
    if (oldIndex < newIndex) newIndex -= 1;
    final subs = List<RuleSub>.of(state.subs);
    final moved = subs.removeAt(oldIndex);
    subs.insert(newIndex, moved);
    // 乐观更新 UI
    state = state.copyWith(subs: subs);
    try {
      final api = ref.read(bookApiProvider);
      await api.ruleSubUpdateOrder(ids: subs.map((s) => s.id).toList());
    } catch (e) {
      state = state.copyWith(error: _mapError(e));
      await loadSubs();
    }
  }

  /// 检查更新（契约 §2.39 CheckUpdate：dueForUpdate / hasUpdate / error）
  Future<Map<String, dynamic>> checkUpdate(int id) {
    return ref.read(bookApiProvider).ruleSubCheckUpdate(id: id);
  }

  /// 应用更新（契约 §2.39 ApplyUpdate：success / items* / error）
  Future<Map<String, dynamic>> applyUpdate(int id) async {
    final result =
        await ref.read(bookApiProvider).ruleSubApplyUpdate(id: id);
    // 应用成功后 Rust 已回写版本号与最后更新时间，刷新列表
    if (result['success'] == true) await loadSubs();
    return result;
  }

  /// 统一错误映射
  String _mapError(Object e) {
    if (e is BridgeError) return e.message;
    return e.toString();
  }
}

/// 规则订阅 Notifier 全局 Provider
final ruleSubNotifierProvider =
    NotifierProvider<RuleSubNotifier, RuleSubState>(RuleSubNotifier.new);
