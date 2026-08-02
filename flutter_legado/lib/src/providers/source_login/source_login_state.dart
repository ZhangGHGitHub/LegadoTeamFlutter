import 'package:freezed_annotation/freezed_annotation.dart';

import '../../models/models.dart';

part 'source_login_state.freezed.dart';

/// 书源登录页状态
///
/// 持有当前书源的登录凭据（Token / Cookies / Headers），
/// 由 [SourceLoginNotifier] 经 BookApi.getConfig/setConfig 持久化到 Rust 配置库。
@freezed
class SourceLoginState with _$SourceLoginState {
  const factory SourceLoginState({
    /// Bearer Token / API Key（可选）
    @Default('') String token,

    /// Cookie 键值对列表
    @Default([]) List<LoginKeyValue> cookies,

    /// Header 键值对列表
    @Default([]) List<LoginKeyValue> headers,

    /// 正在加载已保存的登录信息
    @Default(false) bool isLoading,

    /// 正在保存
    @Default(false) bool isSaving,

    /// 错误信息
    String? error,
  }) = _SourceLoginState;
}
