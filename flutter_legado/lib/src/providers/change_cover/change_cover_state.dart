import 'package:freezed_annotation/freezed_annotation.dart';

import '../../models/models.dart';

part 'change_cover_state.freezed.dart';

/// 更换封面页状态
///
/// 由 [ChangeCoverNotifier] 管理：网络封面搜索经 `BookApi.searchCover` 委托 Rust
/// （Rust 轨交付前以 Mock 数据先行驱动），本地选图为纯 UI 编排不经过本状态。
@freezed
class ChangeCoverState with _$ChangeCoverState {
  const factory ChangeCoverState({
    /// 网络封面候选列表
    @Default([]) List<CoverCandidate> candidates,

    /// 正在搜索封面
    @Default(false) bool isSearching,

    /// 错误信息
    String? error,
  }) = _ChangeCoverState;
}
