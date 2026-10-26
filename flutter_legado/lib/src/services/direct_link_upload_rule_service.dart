// 直链上传规则服务（批16b）
//
// 对齐参考版 `DirectLinkUpload`（legado-with-MD3）与 Android 原版同名对象，
// 字段集已按用户裁决 2026-10-27 冻结为 4 字段：uploadUrl / downloadUrlRule /
// summary / compress（参考版口径，不含 expiryDate）。
//
// 职责：
// 1. 读取内置默认规则资产 `assets/default_data/directLinkUpload.json`（索引 0 为默认）；
// 2. 经既有 BookApi.getConfig/setConfig/deleteConfig 持久化规则（键
//    `directLinkUploadRule`，零 FFI 契约变更）；
// 3. 规则校验、测试上传（契约 §2.51 directLinkUpload）。
//
// 消费方：16b 设置 Sheet；16c 通用导出目标 Sheet 通过 getEffectiveRule() 取规则。
import 'dart:convert';

import 'package:flutter/foundation.dart' show debugPrint, immutable;
import 'package:flutter/services.dart' show rootBundle;

import 'book_api.dart';

/// 直链上传规则非法（JSON 形态 / 必填字段 / 字段类型）
///
/// [message] 为可直接展示给用户的中文文案。
class DirectLinkUploadRuleException implements Exception {
  const DirectLinkUploadRuleException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 直链上传规则（4 字段，序列化 camelCase，读取兼容 snake_case）
@immutable
class DirectLinkUploadRule {
  const DirectLinkUploadRule({
    required this.uploadUrl,
    required this.downloadUrlRule,
    required this.summary,
    this.compress = false,
  });

  /// 解析规则 JSON 对象；缺失字段按空值处理，类型不符抛
  /// [DirectLinkUploadRuleException]（未知键如原版 `expiryDate` 忽略）。
  factory DirectLinkUploadRule.fromJson(Map<String, dynamic> json) {
    String readString(String camel, [String? snake]) {
      final value = json[camel] ?? (snake == null ? null : json[snake]);
      if (value == null) return '';
      if (value is! String) {
        throw DirectLinkUploadRuleException('字段 $camel 必须是字符串');
      }
      return value;
    }

    final compress = json['compress'];
    if (compress != null && compress is! bool) {
      throw const DirectLinkUploadRuleException('字段 compress 必须是布尔值');
    }
    return DirectLinkUploadRule(
      uploadUrl: readString('uploadUrl', 'upload_url'),
      downloadUrlRule: readString('downloadUrlRule', 'download_url_rule'),
      summary: readString('summary'),
      compress: compress as bool? ?? false,
    );
  }

  /// 创建分享链接的上传 URL（支持 `url,{options}` 逗号选项）
  final String uploadUrl;

  /// 下载链接规则（JSONPath / 正则 / `@js:` 级联）
  final String downloadUrlRule;

  /// 注释（必填，对齐原版 `summary.isNullOrBlank()` 校验）
  final String summary;

  /// 上传前是否压缩为 zip
  final bool compress;

  /// 校验必填字段与上传 URL 形态
  ///
  /// 上传 URL 只校验逗号选项前的 URL 部分（对齐 Rust 侧切分规则），
  /// 允许 `http` / `https` 且必须含主机名。
  void validate() {
    final url = uploadUrl.trim();
    if (url.isEmpty) {
      throw const DirectLinkUploadRuleException('上传Url不能为空');
    }
    final comma = url.indexOf(',');
    final urlPart =
        comma >= 0 && url.substring(comma + 1).trimLeft().startsWith('{')
        ? url.substring(0, comma).trim()
        : url;
    final uri = Uri.tryParse(urlPart);
    if (uri == null ||
        (uri.scheme != 'http' && uri.scheme != 'https') ||
        uri.host.isEmpty) {
      throw const DirectLinkUploadRuleException('上传Url不是有效的 http(s) 地址');
    }
    if (downloadUrlRule.trim().isEmpty) {
      throw const DirectLinkUploadRuleException('下载Url规则不能为空');
    }
    if (summary.trim().isEmpty) {
      throw const DirectLinkUploadRuleException('注释不能为空');
    }
  }

  /// 固定 4 字段 camelCase 对象
  Map<String, dynamic> toJson() => <String, dynamic>{
    'uploadUrl': uploadUrl,
    'downloadUrlRule': downloadUrlRule,
    'summary': summary,
    'compress': compress,
  };

  /// 序列化为 JSON 字符串（持久化 / 剪贴板 / 测试上传共用）
  String toJsonString() => jsonEncode(toJson());

  @override
  bool operator ==(Object other) =>
      other is DirectLinkUploadRule &&
      other.uploadUrl == uploadUrl &&
      other.downloadUrlRule == downloadUrlRule &&
      other.summary == summary &&
      other.compress == compress;

  @override
  int get hashCode =>
      Object.hash(uploadUrl, downloadUrlRule, summary, compress);

  @override
  String toString() => summary;
}

/// 生效规则解析结果
///
/// [degraded] 为 true 表示已保存配置存在但无效（JSON 损坏或语义非法），
/// 已回退内置默认规则；调用方可据此给出可感知提示。
@immutable
class EffectiveRuleResult {
  const EffectiveRuleResult({required this.rule, this.degraded = false});

  /// 当前生效规则（已保存配置或内置第 1 条）
  final DirectLinkUploadRule rule;

  /// 是否发生了坏配置回落
  final bool degraded;
}

/// 直链上传规则读写服务（配置优先，缺省回落内置第 1 条规则）
class DirectLinkUploadRuleService {
  DirectLinkUploadRuleService(
    this._api, {
    Future<String> Function(String path)? assetLoader,
  }) : _assetLoader = assetLoader ?? rootBundle.loadString;

  /// caches 表配置键（对齐原版 `directLinkUploadRule.json` 语义）
  static const String configKey = 'directLinkUploadRule';

  /// 内置默认规则资产路径
  static const String defaultRulesAsset =
      'assets/default_data/directLinkUpload.json';

  final BookApi _api;
  final Future<String> Function(String path) _assetLoader;

  List<DirectLinkUploadRule>? _defaultRulesCache;

  /// 读取内置默认规则（索引 0 为默认）；结果在实例内缓存
  Future<List<DirectLinkUploadRule>> loadDefaultRules({
    bool refresh = false,
  }) async {
    final cached = _defaultRulesCache;
    if (!refresh && cached != null) return cached;

    final raw = await _assetLoader(defaultRulesAsset);
    final dynamic decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      throw const DirectLinkUploadRuleException('内置直链上传规则不是有效的 JSON');
    }
    final list = switch (decoded) {
      List<dynamic> value => value,
      _ => throw const DirectLinkUploadRuleException('内置直链上传规则必须是 JSON 数组'),
    };
    final rules = <DirectLinkUploadRule>[];
    for (final item in list) {
      final map = switch (item) {
        Map<String, dynamic> value => value,
        _ => throw const DirectLinkUploadRuleException('内置直链上传规则条目必须是 JSON 对象'),
      };
      final rule = DirectLinkUploadRule.fromJson(map)..validate();
      rules.add(rule);
    }
    if (rules.isEmpty) {
      throw const DirectLinkUploadRuleException('内置直链上传规则为空');
    }
    _defaultRulesCache = List.unmodifiable(rules);
    return _defaultRulesCache!;
  }

  /// 解析规则 JSON 字符串（兼容 snake_case，未知键忽略）
  DirectLinkUploadRule parseRule(String ruleJson) {
    final trimmed = ruleJson.trim();
    if (trimmed.isEmpty) {
      throw const DirectLinkUploadRuleException('规则内容为空');
    }
    final dynamic decoded;
    try {
      decoded = jsonDecode(trimmed);
    } on FormatException {
      throw const DirectLinkUploadRuleException('规则不是有效的 JSON');
    }
    final map = switch (decoded) {
      Map<String, dynamic> value => value,
      _ => throw const DirectLinkUploadRuleException('规则必须是 JSON 对象'),
    };
    return DirectLinkUploadRule.fromJson(map);
  }

  /// 读取已保存规则；未配置返回 null，配置损坏抛
  /// [DirectLinkUploadRuleException]（由调用方决定是否回退）。
  Future<DirectLinkUploadRule?> loadSavedRule() async {
    final raw = await _api.getConfig(configKey);
    if (raw == null || raw.trim().isEmpty) return null;
    return parseRule(raw);
  }

  /// 生效规则解析：已保存配置优先，否则内置第 1 条
  ///
  /// 已保存配置在解析后还会再做一次 [DirectLinkUploadRule.validate]，因此
  /// 可解析但语义非法的配置（如 `{}`、必填字段为空）同样回退默认规则，
  /// 并在结果中标记 [EffectiveRuleResult.degraded]，供界面提示用户。
  Future<EffectiveRuleResult> resolveEffectiveRule() async {
    try {
      final saved = await loadSavedRule();
      if (saved != null) {
        saved.validate();
        return EffectiveRuleResult(rule: saved);
      }
    } on DirectLinkUploadRuleException catch (e) {
      debugPrint('直链上传规则配置无效，回退默认规则：${e.message}');
      final defaults = await loadDefaultRules();
      return EffectiveRuleResult(rule: defaults.first, degraded: true);
    }
    final defaults = await loadDefaultRules();
    return EffectiveRuleResult(rule: defaults.first);
  }

  /// 生效规则（简化入口）：已保存配置优先，否则内置第 1 条
  ///
  /// 坏配置静默回退默认规则，保证导出链不中断；需要感知回落时改用
  /// [resolveEffectiveRule]。
  Future<DirectLinkUploadRule> getEffectiveRule() async =>
      (await resolveEffectiveRule()).rule;

  /// 校验并保存规则（仅持久化 4 字段 camelCase）
  Future<void> saveRule(String ruleJson) async {
    final rule = parseRule(ruleJson)..validate();
    await _api.setConfig(configKey, rule.toJsonString());
  }

  /// 清除已保存规则（回落内置默认）
  Future<void> clearRule() => _api.deleteConfig(configKey);

  /// 测试规则：上传 `test.json`（内容 `{}`）并返回直链 URL
  ///
  /// 对齐原版「测试」语义；校验失败不发起网络请求，上传/求值错误上抛。
  Future<String> testRule(String ruleJson) async {
    final rule = parseRule(ruleJson)..validate();
    return _api.directLinkUpload(
      ruleJson: rule.toJsonString(),
      fileName: 'test.json',
      contentType: 'application/json',
      content: '{}',
    );
  }
}
