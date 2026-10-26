/// 高亮规则状态与类型化模型
///
/// [审计修复 §4.3 第二批] JSON 解析下沉：UI 层不再触碰 raw map，
/// 仅消费本文件的 [HighlightRule] 类型化数据 — Qoder
library;

import 'dart:convert';

/// 高亮规则类型化模型（字段名与 Rust HighlightRule serde 契约一致）
///
/// 对标 Android 原版 data class HighlightRule：
/// id / uuid / name / pattern / isRegex / applyToTitle / scope / isEnabled /
/// style / order(sortOrder) / timeoutMillisecond / applyToBody。
///
/// [uuid]/[sortOrder]/[timeoutMillisecond]/[applyToBody] 为批16e 回修补齐：
/// 导出与保存都必须保留这些字段，否则关联导入会因 uuid 缺失报
/// 「uuid 非法」，用户设置的正文开关/匹配超时也会丢失。
class HighlightRule {
  const HighlightRule({
    this.id = 0,
    this.uuid = '',
    this.name = '',
    this.pattern = '',
    this.isRegex = false,
    this.applyToTitle = false,
    this.scope,
    this.isEnabled = true,
    this.style = '',
    this.sortOrder = 0,
    this.timeoutMillisecond = defaultTimeoutMilliseconds,
    this.applyToBody = true,
  });

  /// 默认匹配超时（对齐原版 `DEFAULT_TIMEOUT_MILLISECONDS = 3000L`）
  static const int defaultTimeoutMilliseconds = 3000;

  final int id;

  /// 规则身份 UUID（Rust 侧唯一索引；导出/导入均按其去重）
  ///
  /// 为空表示后端未返回（不凭空生成）：保存时 Rust 会补随机 UUID。
  final String uuid;

  final String name;
  final String pattern;
  final bool isRegex;
  final bool applyToTitle;
  final String? scope;
  final bool isEnabled;
  final String style;

  /// 排序值（Rust serde 字段 `sortOrder`；原版实体字段为 `order`）
  final int sortOrder;

  /// 匹配超时毫秒数
  final int timeoutMillisecond;

  /// 是否应用到正文（原版实体字段 `applyToBody`，默认 true）
  final bool applyToBody;

  /// 容错解析：字段缺失/类型不符时回退默认值（对齐 AppLogEntry.fromJson 风格）
  ///
  /// `sortOrder` 兼容 Rust 契约字段与原版备份的 `order` 字段。
  factory HighlightRule.fromJson(Map<String, dynamic> json) {
    return HighlightRule(
      id: (json['id'] as num?)?.toInt() ?? 0,
      uuid: (json['uuid'] as String?) ?? '',
      name: (json['name'] as String?) ?? '',
      pattern: (json['pattern'] as String?) ?? '',
      isRegex: (json['isRegex'] as bool?) ?? false,
      applyToTitle: (json['applyToTitle'] as bool?) ?? false,
      scope: json['scope'] as String?,
      isEnabled: (json['isEnabled'] as bool?) ?? true,
      style: (json['style'] as String?) ?? '',
      sortOrder: (json['sortOrder'] as num?)?.toInt() ??
          (json['order'] as num?)?.toInt() ??
          0,
      timeoutMillisecond: (json['timeoutMillisecond'] as num?)?.toInt() ??
          defaultTimeoutMilliseconds,
      applyToBody: (json['applyToBody'] as bool?) ?? true,
    );
  }

  /// 序列化为 Rust 侧契约 JSON（保存用）
  ///
  /// uuid 为空时不写入，由 Rust serde 补随机 UUID（不在 Dart 侧凭空生成）。
  Map<String, dynamic> toJson() => {
        if (id > 0) 'id': id,
        if (uuid.isNotEmpty) 'uuid': uuid,
        'name': name,
        'pattern': pattern,
        'isRegex': isRegex,
        'applyToTitle': applyToTitle,
        'scope': scope,
        'isEnabled': isEnabled,
        'style': style,
        'sortOrder': sortOrder,
        'timeoutMillisecond': timeoutMillisecond,
        'applyToBody': applyToBody,
      };

  /// 序列化为导出/备份 JSON（字段名对齐原版实体）
  ///
  /// 原版 `HighlightRule` 的排序字段名为 `order`（Room 列名才是
  /// `sortOrder`），关联导入器按原版备份格式识别 `order` 并在合并阶段
  /// 转写为 Rust 契约字段；此处与保存路径分开，避免污染 FFI 入参。
  Map<String, dynamic> toExportJson() {
    final json = toJson();
    json.remove('sortOrder');
    json['order'] = sortOrder;
    return json;
  }

  /// 规则显示名（对标 Kotlin getDisplayName：name 为空时回退 pattern）
  String get displayName => name.isNotEmpty ? name : pattern;

  /// 从 style JSON 解析 textColor（ARGB int），非法/缺失返回 null
  int? get styleTextColor {
    if (style.isEmpty) return null;
    try {
      final decoded = jsonDecode(style);
      if (decoded is Map<String, dynamic>) {
        final v = decoded['textColor'];
        if (v is num) return v.toInt();
      }
    } catch (_) {
      // 非法 style 静默回退默认色（UI 层 debugPrint 留痕由调用方决定）
    }
    return null;
  }

  HighlightRule copyWith({
    int? id,
    String? uuid,
    String? name,
    String? pattern,
    bool? isRegex,
    bool? applyToTitle,
    String? scope,
    bool? isEnabled,
    String? style,
    int? sortOrder,
    int? timeoutMillisecond,
    bool? applyToBody,
  }) {
    return HighlightRule(
      id: id ?? this.id,
      uuid: uuid ?? this.uuid,
      name: name ?? this.name,
      pattern: pattern ?? this.pattern,
      isRegex: isRegex ?? this.isRegex,
      applyToTitle: applyToTitle ?? this.applyToTitle,
      scope: scope ?? this.scope,
      isEnabled: isEnabled ?? this.isEnabled,
      style: style ?? this.style,
      sortOrder: sortOrder ?? this.sortOrder,
      timeoutMillisecond: timeoutMillisecond ?? this.timeoutMillisecond,
      applyToBody: applyToBody ?? this.applyToBody,
    );
  }
}

/// 高亮规则列表页状态
class HighlightRulesState {
  const HighlightRulesState({
    this.rules = const [],
    this.isLoading = true,
    this.error,
  });

  final List<HighlightRule> rules;
  final bool isLoading;
  final String? error;

  HighlightRulesState copyWith({
    List<HighlightRule>? rules,
    bool? isLoading,
    String? error,
    bool clearError = false,
  }) {
    return HighlightRulesState(
      rules: rules ?? this.rules,
      isLoading: isLoading ?? this.isLoading,
      error: clearError ? null : (error ?? this.error),
    );
  }
}
