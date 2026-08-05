/// 高亮规则状态与类型化模型
///
/// [审计修复 §4.3 第二批] JSON 解析下沉：UI 层不再触碰 raw map，
/// 仅消费本文件的 [HighlightRule] 类型化数据 — Qoder
library;

import 'dart:convert';

/// 高亮规则类型化模型（字段名与 Rust HighlightRule serde 契约一致）
///
/// 对标 Android 原版 data class HighlightRule：
/// id / name / pattern / isRegex / applyToTitle / scope / isEnabled / style。
class HighlightRule {
  const HighlightRule({
    this.id = 0,
    this.name = '',
    this.pattern = '',
    this.isRegex = false,
    this.applyToTitle = false,
    this.scope,
    this.isEnabled = true,
    this.style = '',
  });

  final int id;
  final String name;
  final String pattern;
  final bool isRegex;
  final bool applyToTitle;
  final String? scope;
  final bool isEnabled;
  final String style;

  /// 容错解析：字段缺失/类型不符时回退默认值（对齐 AppLogEntry.fromJson 风格）
  factory HighlightRule.fromJson(Map<String, dynamic> json) {
    return HighlightRule(
      id: (json['id'] as num?)?.toInt() ?? 0,
      name: (json['name'] as String?) ?? '',
      pattern: (json['pattern'] as String?) ?? '',
      isRegex: (json['isRegex'] as bool?) ?? false,
      applyToTitle: (json['applyToTitle'] as bool?) ?? false,
      scope: json['scope'] as String?,
      isEnabled: (json['isEnabled'] as bool?) ?? true,
      style: (json['style'] as String?) ?? '',
    );
  }

  /// 序列化为 Rust 侧契约 JSON（保存用）
  Map<String, dynamic> toJson() => {
        if (id > 0) 'id': id,
        'name': name,
        'pattern': pattern,
        'isRegex': isRegex,
        'applyToTitle': applyToTitle,
        'scope': scope,
        'isEnabled': isEnabled,
        'style': style,
      };

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
    String? name,
    String? pattern,
    bool? isRegex,
    bool? applyToTitle,
    String? scope,
    bool? isEnabled,
    String? style,
  }) {
    return HighlightRule(
      id: id ?? this.id,
      name: name ?? this.name,
      pattern: pattern ?? this.pattern,
      isRegex: isRegex ?? this.isRegex,
      applyToTitle: applyToTitle ?? this.applyToTitle,
      scope: scope ?? this.scope,
      isEnabled: isEnabled ?? this.isEnabled,
      style: style ?? this.style,
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
