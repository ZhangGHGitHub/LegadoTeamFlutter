import 'package:flutter/material.dart';

import '../models/models.dart';
import '../services/rust_api.dart';

/// 替换规则状态管理
class ReplaceRuleProvider extends ChangeNotifier {
  final RustApi _api;

  ReplaceRuleProvider(this._api);

  List<ReplaceRule> _rules = [];
  bool _loading = false;
  String? _error;

  List<ReplaceRule> get rules => _rules;
  bool get loading => _loading;
  String? get error => _error;

  /// 加载所有替换规则
  Future<void> load() async {
    _loading = true;
    _error = null;
    notifyListeners();
    try {
      _rules = await _api.getReplaceRules();
    } catch (e) {
      _error = e.toString();
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  /// 添加替换规则
  Future<ReplaceRule> addRule(ReplaceRule rule) async {
    final added = await _api.addReplaceRule(rule);
    _rules.add(added);
    notifyListeners();
    return added;
  }

  /// 更新替换规则
  Future<void> updateRule(ReplaceRule rule) async {
    await _api.updateReplaceRule(rule);
    final idx = _rules.indexWhere((r) => r.id == rule.id);
    if (idx >= 0) {
      _rules[idx] = rule;
      notifyListeners();
    }
  }

  /// 删除替换规则
  Future<void> deleteRule(int id) async {
    await _api.deleteReplaceRule(id);
    _rules.removeWhere((r) => r.id == id);
    notifyListeners();
  }

  /// 启用/禁用替换规则
  Future<void> setEnabled(int id, bool enabled) async {
    await _api.setReplaceRuleEnabled(id, enabled);
    final idx = _rules.indexWhere((r) => r.id == id);
    if (idx >= 0) {
      _rules[idx] = _rules[idx].copyWith(isEnabled: enabled);
      notifyListeners();
    }
  }

  /// 上移规则
  void moveUp(int index) {
    if (index <= 0 || index >= _rules.length) return;
    final current = _rules[index];
    final prev = _rules[index - 1];
    _rules[index] = prev.copyWith(order: current.order);
    _rules[index - 1] = current.copyWith(order: prev.order);
    _rules.sort((a, b) => a.order.compareTo(b.order));
    notifyListeners();
  }

  /// 下移规则
  void moveDown(int index) {
    if (index < 0 || index >= _rules.length - 1) return;
    final current = _rules[index];
    final next = _rules[index + 1];
    _rules[index] = next.copyWith(order: current.order);
    _rules[index + 1] = current.copyWith(order: next.order);
    _rules.sort((a, b) => a.order.compareTo(b.order));
    notifyListeners();
  }
}
