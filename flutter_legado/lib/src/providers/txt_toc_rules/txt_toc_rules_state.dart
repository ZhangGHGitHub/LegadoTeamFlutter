import 'package:freezed_annotation/freezed_annotation.dart';

import '../../models/models.dart';

part 'txt_toc_rules_state.freezed.dart';

/// TXT 目录规则页状态
///
/// 由 [TxtTocRulesNotifier] 经 BookApi.getConfig/setConfig 持久化到 Rust 配置库。
@freezed
class TxtTocRulesState with _$TxtTocRulesState {
  const factory TxtTocRulesState({
    /// 规则列表（按 serialNumber 语义排序）
    @Default([]) List<TxtTocRule> rules,

    /// 正在加载
    @Default(false) bool isLoading,

    /// 错误信息
    String? error,
  }) = _TxtTocRulesState;
}
