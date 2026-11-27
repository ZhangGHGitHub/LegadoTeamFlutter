import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;

import '../../bridge/ffi.dart';
import '../../l10n/app_strings.dart';
import '../../models/models.dart';
import '../../services/book_api.dart';
import '../providers.dart';
import 'txt_toc_rules_state.dart';

export 'txt_toc_rules_state.dart';

/// 默认 TXT 目录规则（对齐 `app/src/main/assets/defaultData/txtTocRule.json`）
const kDefaultTxtTocRulesAsset = 'assets/default_data/txtTocRule.json';

/// 历史配置键（B8 迁移来源，迁移后删除）
///
/// 早期实现把 TXT 目录规则序列化进 `caches` 的 `config:txt_toc_rules`，
/// 而备份导出/恢复与目录解析读的是 `txtTocRules` 表——用户自建规则既不
/// 进备份（换机即丢），也不在真正的规则库里。现在唯一存储是
/// `txtTocRules` 表（FFI `txtTocRule*`），本键只作一次性迁移来源。
const kLegacyTxtTocRulesConfigKey = 'txt_toc_rules';

/// 对齐 Android `DefaultData.importDefaultTocRules`：删除默认 id(<0) 后灌入原版规则。
///
/// 走 FFI `txtTocRuleImportDefault`（Rust 侧内置同源 JSON），保留用户自建
/// 规则（id > 0）。[jsonOverride] 非空时改走导入面（REPLACE by name），
/// 供迁移/测试注入自定义内容。
Future<int> syncDefaultTxtTocRules(BookApi api, {String? jsonOverride}) async {
  if (jsonOverride == null) {
    return api.txtTocRuleImportDefault();
  }
  return api.txtTocRuleImport(jsonOrUrl: jsonOverride, kind: 'text');
}

/// TXT 目录规则 Riverpod Notifier
///
/// 规则库**唯一存储**为 `txtTocRules` 表（FFI `txtTocRule*`）：备份
/// 导出/恢复、目录解析、UI 编辑读写同一张表（B8 修复）。
class TxtTocRulesNotifier extends Notifier<TxtTocRulesState> {
  @override
  TxtTocRulesState build() => const TxtTocRulesState();

  /// 加载规则列表（按 serialNumber 升序）
  Future<void> load() async {
    state = state.copyWith(isLoading: true, error: null);
    try {
      final api = ref.read(bookApiProvider);
      await _migrateLegacyConfig(api);
      final rows = await api.txtTocRuleList();
      state = state.copyWith(rules: _decodeRows(rows), isLoading: false);
    } catch (e) {
      state = state.copyWith(error: _mapError(e), isLoading: false);
    }
  }

  /// 菜单「导入默认」：删除默认行后重灌原版规则（保留用户自建）
  Future<int> importDefaultRules() async {
    final api = ref.read(bookApiProvider);
    final n = await syncDefaultTxtTocRules(api);
    await _reload(api);
    return n;
  }

  /// 新增规则（追加到末尾）
  Future<void> addRule(TxtTocRule rule) async {
    final api = ref.read(bookApiProvider);
    try {
      await api.txtTocRuleAdd(
        name: rule.name,
        rule: rule.rule,
        replacement: rule.replacement,
        enable: rule.enable,
        example: rule.example,
        serialNumber: state.rules.length,
      );
      await _reload(api);
    } catch (e) {
      state = state.copyWith(error: _mapError(e));
      rethrow;
    }
  }

  /// 更新规则（按 id）
  Future<void> updateRule(TxtTocRule rule) async {
    final api = ref.read(bookApiProvider);
    try {
      await api.txtTocRuleUpdate(
        id: rule.id,
        name: rule.name,
        rule: rule.rule,
        replacement: rule.replacement,
        enable: rule.enable,
        example: rule.example,
        serialNumber: rule.serialNumber,
      );
      await _reload(api);
    } catch (e) {
      state = state.copyWith(error: _mapError(e));
      rethrow;
    }
  }

  /// 删除规则（按 id）
  Future<void> deleteRule(int id) async {
    final api = ref.read(bookApiProvider);
    try {
      await api.txtTocRuleDelete(id);
      await _reload(api);
    } catch (e) {
      state = state.copyWith(error: _mapError(e));
      rethrow;
    }
  }

  /// 启用/禁用（按 id）
  Future<void> setEnabled(int id, bool enable) async {
    final api = ref.read(bookApiProvider);
    try {
      await api.txtTocRuleSetEnabled(id: id, enabled: enable);
      await _reload(api);
    } catch (e) {
      state = state.copyWith(error: _mapError(e));
      rethrow;
    }
  }

  /// 一次性迁移：把历史 `config:txt_toc_rules` 导入表并清键
  ///
  /// 内容非法时保留原键（不丢用户数据）并记 error，不阻断加载。
  Future<void> _migrateLegacyConfig(BookApi api) async {
    final String? raw;
    try {
      raw = await api.getConfig(kLegacyTxtTocRulesConfigKey);
    } catch (_) {
      return;
    }
    if (raw == null || raw.trim().isEmpty) {
      return;
    }
    try {
      await api.txtTocRuleImport(jsonOrUrl: raw, kind: 'text');
    } catch (e) {
      state = state.copyWith(
        error: AppStrings.txtTocRulesMigrateFailed(_mapError(e)),
      );
      return;
    }
    try {
      await api.deleteConfig(kLegacyTxtTocRulesConfigKey);
    } catch (_) {
      // 清键失败最多导致下次重复导入（REPLACE by name 幂等）
    }
  }

  Future<void> _reload(BookApi api) async {
    final rows = await api.txtTocRuleList();
    state = state.copyWith(rules: _decodeRows(rows), error: null);
  }

  /// FFI 行 → `TxtTocRule` 模型
  ///
  /// 行字段为 `{id, name, rule, replacement, serialNumber, enable, example}`，
  /// 与 Dart 模型 JSON 键一致，直接复用 `fromJson`。
  List<TxtTocRule> _decodeRows(List<Map<String, dynamic>> rows) =>
      [for (final row in rows) TxtTocRule.fromJson(row)];

  String _mapError(Object e) {
    if (e is BridgeError) return e.message;
    return e.toString();
  }
}

final txtTocRulesNotifierProvider =
    NotifierProvider<TxtTocRulesNotifier, TxtTocRulesState>(
  TxtTocRulesNotifier.new,
);

/// 供迁移/测试使用的旧配置键编码（保留以兼容既有调用点）
String encodeTxtTocRulesForLegacyConfig(List<TxtTocRule> rules) =>
    jsonEncode(rules.map((r) => r.toJson()).toList());

/// 读取内置默认规则资产（供 UI 预览/测试用，不再用于持久化）
Future<String> loadDefaultTxtTocRulesAsset() =>
    rootBundle.loadString(kDefaultTxtTocRulesAsset);
