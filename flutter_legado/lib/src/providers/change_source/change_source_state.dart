import 'package:freezed_annotation/freezed_annotation.dart';

import '../../models/models.dart';

part 'change_source_state.freezed.dart';

/// 换源页不可变状态
///
/// 由 [ChangeSourceNotifier] 维护，对标原 change_source_screen 内部字段
/// （_results/_isSearching/_error/_applyingUrl）迁移至 Riverpod 后的表达。
@freezed
class ChangeSourceState with _$ChangeSourceState {
  const factory ChangeSourceState({
    /// 匹配到的候选书源列表（Rust 已按评分降序排序，UI 直接渲染）
    @Default([]) List<SourceMatch> results,

    /// 是否正在搜索
    @Default(false) bool isLoading,

    /// 错误信息
    String? error,

    /// 正在应用切换的书源 URL（null 表示无切换进行中）
    String? applyingUrl,
  }) = _ChangeSourceState;
}

/// 展示层派生属性
extension ChangeSourceStateDisplay on ChangeSourceState {
  /// 是否有匹配结果
  bool get hasResults => results.isNotEmpty;

  /// 是否正在切换书源
  bool get isApplying => applyingUrl != null;
}
