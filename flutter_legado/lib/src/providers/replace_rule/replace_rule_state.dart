import 'package:freezed_annotation/freezed_annotation.dart';

import '../../models/models.dart';

part 'replace_rule_state.freezed.dart';

/// 替换规则页 UI 状态（immutable）
///
/// 职责边界（对齐旧 ReplaceRuleProvider）：
/// - [rules]：Rust API 返回的替换规则列表
/// - [loading]：列表加载状态
/// - [error]：错误信息（null 表示无错误）
@freezed
class ReplaceRuleState with _$ReplaceRuleState {
  const factory ReplaceRuleState({
    /// 替换规则列表
    @Default([]) List<ReplaceRule> rules,

    /// 是否正在加载规则列表
    @Default(false) bool loading,

    /// 错误信息（null 表示无错误）
    String? error,
  }) = _ReplaceRuleState;
}
