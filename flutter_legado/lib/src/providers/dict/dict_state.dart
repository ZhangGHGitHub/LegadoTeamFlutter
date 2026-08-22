import 'package:freezed_annotation/freezed_annotation.dart';

import '../../models/models.dart';

part 'dict_state.freezed.dart';

/// 字典查询页状态
///
/// 由 [DictNotifier] 管理：在线词典规则经 BookApi.getConfig/setConfig 持久化，
/// 词典查询经 BookApi.dictLookup 委托 Rust FFI dict_lookup；本状态仅承载规则与查询结果。
@freezed
class DictState with _$DictState {
  const factory DictState({
    /// 在线词典规则列表
    @Default([]) List<DictRule> rules,

    /// 当前查询的单词（null 表示尚未查询）
    String? queriedWord,

    /// 本地词典命中结果（null 表示未查询或未收录）
    DictEntry? result,

    /// 正在加载规则
    @Default(false) bool isLoading,

    /// 错误信息
    String? error,
  }) = _DictState;
}
