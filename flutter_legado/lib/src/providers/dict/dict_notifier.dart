import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;

import '../../bridge/ffi.dart';
import '../../models/models.dart';
import '../../services/book_api.dart';
import '../providers.dart';
import 'dict_state.dart';

export 'dict_state.dart';

/// 默认字典规则资源（对齐 `app/src/main/assets/defaultData/dictRules.json`）
const kDefaultDictRulesAsset = 'assets/default_data/dictRules.json';

/// 历史配置键（B7 迁移来源，迁移后删除）
///
/// 早期实现把字典规则序列化进 `caches` 表的 `config:dict_rules`，而词典
/// 查询读的是 `dictRules` 表 → 用户在弹窗里新增的规则「看起来保存了但查询
/// 不用」。现在唯一存储是 `dictRules` 表（契约 §2.45），本键只作为一次性
/// 迁移来源。
const kLegacyDictRulesConfigKey = 'dict_rules';

/// 对齐 Android `DefaultData.importDefaultDictRules`：导入原版默认字典规则。
///
/// 走契约 §2.45 `dictRuleImport`（REPLACE by name：同名覆盖保留 id、异名插入），
/// 与「本地导入」同语义；不再写 `config:dict_rules`。
Future<int> syncDefaultDictRules(
  BookApi api, {
  String? jsonOverride,
}) async {
  final text =
      jsonOverride ?? await rootBundle.loadString(kDefaultDictRulesAsset);
  return api.dictRuleImport(jsonOrUrl: text, kind: 'text');
}

/// 字典查询页 Riverpod Notifier
///
/// 职责严格限定（对齐 UI_RESTRUCTURE_PLAN.md §0.2 铁律）：
/// - 词典规则**唯一存储**为 `dictRules` 表，经契约 §2.45 FFI
///   （`dictRuleList` / `dictRuleAdd` / `dictRuleDelete` / `dictRuleImport`）
///   读写——与 `dict_lookup` 查询使用的数据源是同一张表（B7 修复）。
/// - 旧 `config:dict_rules` 在首次加载时一次性导表并清键。
/// - 词典释义查询经 `BookApi.dictLookup` 委托 Rust。
class DictNotifier extends Notifier<DictState> {
  /// 与 [DictState.rules] 一一对应的行 ID（Dart `DictRule` 模型不含 id，
  /// 删除需按 id 调 FFI，故并行维护）。
  List<int> _ids = const [];

  @override
  DictState build() => const DictState();

  /// 加载词典规则（表为空时 Rust 侧自动注入原版默认 5 源）
  Future<void> loadRules() async {
    state = state.copyWith(isLoading: true, error: null);
    try {
      final api = ref.read(bookApiProvider);
      await _migrateLegacyConfig(api);
      final rows = await api.dictRuleList();
      _applyRows(rows);
      state = state.copyWith(isLoading: false);
    } catch (e) {
      state = state.copyWith(error: _mapError(e), isLoading: false);
    }
  }

  /// 菜单「导入默认」：按 name REPLACE 写回原版默认规则
  Future<int> importDefaultRules() async {
    final api = ref.read(bookApiProvider);
    final n = await syncDefaultDictRules(api);
    await _reload(api);
    return n;
  }

  /// 添加词典规则（enabled=1, sortNumber=0）
  ///
  /// 名称重复时 Rust 侧 UNIQUE 约束报错，此处把错误写入 state.error 并原样
  /// 抛出，供调用方提示（弹窗「保存」失败不再静默）。
  Future<void> addRule(DictRule rule) async {
    final api = ref.read(bookApiProvider);
    try {
      await api.dictRuleAdd(
        name: rule.name,
        urlRule: rule.urlRule,
        showRule: rule.showRule,
      );
      await _reload(api);
    } catch (e) {
      state = state.copyWith(error: _mapError(e));
      rethrow;
    }
  }

  /// 删除指定下标的词典规则（按下标映射到行 ID 走 FFI）
  Future<void> deleteRule(int index) async {
    if (index < 0 || index >= _ids.length) return;
    final api = ref.read(bookApiProvider);
    try {
      await api.dictRuleDelete(_ids[index]);
      await _reload(api);
    } catch (e) {
      state = state.copyWith(error: _mapError(e));
      rethrow;
    }
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

  /// 一次性迁移：把历史 `config:dict_rules` 里的规则导入 `dictRules` 表并清键
  ///
  /// - 内容为空 → 直接清键（历史实现可能写过空串）；
  /// - 内容非法（不是 GSON 数组/对象）→ 保留原键并跳过（不阻断加载，也不
  ///   丢用户数据）；
  /// - 成功 → 删除 `config:dict_rules`，避免下次重复导入。
  Future<void> _migrateLegacyConfig(BookApi api) async {
    final String? raw;
    try {
      raw = await api.getConfig(kLegacyDictRulesConfigKey);
    } catch (_) {
      // 配置读取失败（如键被隐私门禁拒绝）不影响主流程
      return;
    }
    if (raw == null || raw.trim().isEmpty) {
      return;
    }
    try {
      await api.dictRuleImport(jsonOrUrl: raw, kind: 'text');
    } catch (e) {
      // 旧数据损坏：保留原键供人工排查，不阻断词典功能
      state = state.copyWith(error: '词典规则迁移失败：${_mapError(e)}');
      return;
    }
    try {
      await api.deleteConfig(kLegacyDictRulesConfigKey);
    } catch (_) {
      // 清键失败最多导致下次重复导入（REPLACE by name 幂等），不阻断
    }
  }

  Future<void> _reload(BookApi api) async {
    final rows = await api.dictRuleList();
    _applyRows(rows);
    state = state.copyWith(error: null);
  }

  void _applyRows(List<Map<String, dynamic>> rows) {
    _ids = [
      for (final row in rows) (row['id'] as num?)?.toInt() ?? 0,
    ];
    state = state.copyWith(
      rules: [for (final row in rows) DictRule.fromJson(row)],
    );
  }

  String _mapError(Object e) {
    if (e is BridgeError) return e.message;
    return e.toString();
  }
}

final dictNotifierProvider = NotifierProvider<DictNotifier, DictState>(
  DictNotifier.new,
);

/// 供迁移/测试使用的旧配置键编码（保留以兼容既有调用点）
String encodeDictRulesForLegacyConfig(List<DictRule> rules) =>
    jsonEncode(rules.map((r) => r.toJson()).toList());
