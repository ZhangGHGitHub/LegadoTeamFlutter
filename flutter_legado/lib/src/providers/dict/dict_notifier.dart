import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;

import '../../bridge/ffi.dart';
import '../../models/models.dart';
import '../providers.dart';
import 'dict_state.dart';

export 'dict_state.dart';

/// 字典查询页 Riverpod Notifier
///
/// 职责严格限定（对齐 UI_RESTRUCTURE_PLAN.md §0.2 铁律）：
/// - 在线词典规则经 BookApi.getConfig/setConfig 持久化到 Rust 配置库，键 `dict_rules`，
///   不再使用 SharedPreferences。
/// - 词典释义查询经 `BookApi.dictLookup` 委托 Rust（字段对齐 [DictEntry]：
///   `word`/`phonetic`/`definitions`，未收录词返回空 `definitions`，
///   契约见 API_CONTRACT.md §3 需求 4）。
/// - 在线跳转仅为 URL 构造，规则 CRUD 透传。
class DictNotifier extends Notifier<DictState> {
  /// 配置键
  static const _configKey = 'dict_rules';

  /// 默认在线词典（首次使用时写入）
  static const _defaultRules = [
    DictRule(
      name: '有道词典',
      urlRule: 'https://dict.youdao.com/w/{{key}}',
    ),
    DictRule(
      name: '剑桥词典',
      urlRule:
          'https://dictionary.cambridge.org/dictionary/english-chinese-simplified/{{key}}',
    ),
  ];

  @override
  DictState build() => const DictState();

  /// 加载在线词典规则；无持久化数据时写入默认规则
  Future<void> loadRules() async {
    state = state.copyWith(isLoading: true, error: null);
    try {
      final api = ref.read(bookApiProvider);
      final raw = await api.getConfig(_configKey);
      List<DictRule> rules;
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
  ///
  /// 空字符串 / 纯空白被忽略；未收录词返回空 `definitions`（非异常）。
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

  /// 持久化全量规则到 Rust 配置库
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

  /// 统一错误映射
  String _mapError(Object e) {
    if (e is BridgeError) return e.message;
    return e.toString();
  }
}

/// 字典查询 Notifier 全局 Provider
///
/// 使用方式：
/// ```dart
/// final state = ref.watch(dictNotifierProvider);
/// ref.read(dictNotifierProvider.notifier).loadRules();
/// ```
final dictNotifierProvider = NotifierProvider<DictNotifier, DictState>(
  DictNotifier.new,
);
