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
    this.group,
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

  /// 规则分组（原版实体字段 `group`，DB 列 `"group" TEXT DEFAULT ''`）
  ///
  /// 批28：只在编辑/导入/导出往返中透传，当前无分组 UI（列表仍平铺展示）；
  /// 为空表示未分组（原版 `normalizeForRestore` 把空白规整为 null）。
  final String? group;

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
      group: json['group'] as String?,
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
        // 批28：分组随保存往返（原版实体字段 `group`）
        'group': group,
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
    final value = styleMap?['textColor'];
    return value is num ? value.toInt() : null;
  }

  /// style JSON 解析后的原始映射（非法/空返回 null）
  ///
  /// [批33 | 高亮字段保真] style 是原版 `HighlightStyle` 的完整 JSON
  /// （fill/fillShape/textColor/bold/italic/underline/strike/box/emphasis/
  /// shadow/fontPath/fontSize/letterSpacing 等）。编辑表单只改颜色，
  /// 保存时必须保留未编辑键——解析结果同时供列表/预览展示基础字段。
  Map<String, dynamic>? get styleMap {
    if (style.isEmpty) return null;
    try {
      final decoded = jsonDecode(style);
      if (decoded is Map<String, dynamic>) return decoded;
    } catch (_) {
      // 非法 style 静默回退（UI 层按无样式展示）
    }
    return null;
  }

  /// 背景填充色（ARGB int，0=无填充）
  int get styleFill {
    final value = styleMap?['fill'];
    return value is num ? value.toInt() : 0;
  }

  /// 是否加粗（原版 HighlightStyle.bold）
  bool get styleBold => styleMap?['bold'] == true;

  /// 是否斜体（原版 HighlightStyle.italic）
  bool get styleItalic => styleMap?['italic'] == true;

  /// 是否有下划线（原版 HighlightStyle.underline 是对象，非 null 即启用）
  ///
  /// [批33b] 按「对象/映射」判定而非仅非 null：原版 JSON 里
  /// `"underline": null/false` 都表示未启用，只有 `{kind, color, ...}`
  /// 形态才是启用态；仅判 `!= null` 会把 false 误当启用。
  bool get styleUnderline => styleMap?['underline'] is Map;

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
    String? group,
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
      group: group ?? this.group,
      applyToBody: applyToBody ?? this.applyToBody,
    );
  }
}

/// 仅覆盖 style JSON 的 textColor，保留其余键（批33 高亮字段保真）
///
/// 兼容入口：委托 [mergeHighlightStyleFields]，既有调用与测试语义不变。
String mergeHighlightStyleTextColor(String? rawStyle, int textColor) {
  return mergeHighlightStyleFields(rawStyle, textColor: textColor);
}

/// 通用 style JSON 补丁（批7a：富样式编辑，保留未知键）
///
/// 语义：
/// - 原 style 合法对象 → 以解码结果为底（jsonDecode 天然产生独立深拷贝，
///   嵌套键不会与入参共享引用）后按参数增删；未知键原样保留；
/// - 原 style 为空/非法/非对象 → 从空对象开始（不抛错）；
/// - 输出紧凑 JSON 字符串（与既有存储形态一致）。
///
/// 参数优先级（删除标志优先于同组写入值）：
/// - `removeTextColor=true` 删除 `textColor`；否则 `textColor!=null` 时写入；
/// - `fill!=null` 写入 `fill`（调用方传 0 表示关闭填充）；
/// - `removeUnderline=true` 删除 `underline`；否则 `underline!=null` 时写入；
/// - `removeStrike=true` 删除 `strike`；否则 `strike!=null` 时写入。
///
/// 未触碰的属性不要传参（保留原键/原缺省）——例如编辑面板未选文字色时
/// 不传 `textColor`，原 style 的 `textColor:0` 不会被改写（批33b 语义）。
String mergeHighlightStyleFields(
  String? rawStyle, {
  int? fill,
  int? textColor,
  bool removeTextColor = false,
  Map<String, dynamic>? underline,
  bool removeUnderline = false,
  Map<String, dynamic>? strike,
  bool removeStrike = false,
}) {
  final merged = <String, dynamic>{};
  if (rawStyle != null && rawStyle.trim().isNotEmpty) {
    try {
      final decoded = jsonDecode(rawStyle);
      if (decoded is Map<String, dynamic>) {
        // jsonDecode 已返回独立对象树，addAll 不会与入参共享可变引用
        merged.addAll(decoded);
      }
    } catch (_) {
      // 非法 style：按无样式处理，只写本次编辑的属性
    }
  }
  if (fill != null) {
    merged['fill'] = fill;
  }
  if (removeTextColor) {
    merged.remove('textColor');
  } else if (textColor != null) {
    merged['textColor'] = textColor;
  }
  if (removeUnderline) {
    merged.remove('underline');
  } else if (underline != null) {
    merged['underline'] = underline;
  }
  if (removeStrike) {
    merged.remove('strike');
  } else if (strike != null) {
    merged['strike'] = strike;
  }
  return jsonEncode(merged);
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
