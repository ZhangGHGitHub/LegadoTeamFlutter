// 隐私/应用锁状态模型（设置批9b）
//
// 语义对齐参考版 `PrivateConfigScreen.kt:65-205` 与
// `PrivateAppStartGate.kt:64-137`：
// - 凭据：`private_enabled`（默认 false）、密码由 Rust PBKDF2 保存
//   （salt/verifier 在 caches，不进 SharedPreferences/备份）；
// - 验证时机：进入私密分组（默认 true）、打开私密书籍（默认 true）、
//   启动应用（默认 false）；
// - 验证频率：EveryTime / AppSession（默认）/ UntilBackground；
// - 离开后台宽限：0/30/120/180/300 秒，默认 0，仅 UntilBackground 生效。
//
// 本批（9b）只提供设置页与启动闸门；EveryTime 的实际消费方是 9c 的
// 分组/书籍入口闸门，本批只持久化策略值。
//
// 编写：全栈工程师（设置批9b） ｜ 2026-11-09
import 'package:flutter/foundation.dart';

/// 隐私内容解锁频率（对齐参考版 `PrivateUnlockScope`）
enum PrivacyUnlockScope {
  /// 每次进入私密内容都验证（9c 消费）
  everyTime('every_time', '每次进入'),

  /// 本次应用会话内验证一次（默认）
  appSession('app_session', '应用会话内'),

  /// 验证后进入后台超过宽限时间则失效
  untilBackground('until_background', '离开后台后');

  const PrivacyUnlockScope(this.storageValue, this.label);

  /// SharedPreferences 存储值（同时容忍枚举名/短横线写法）
  final String storageValue;

  /// 设置页展示文案
  final String label;

  /// 宽容解析：未知值回落默认 [appSession]
  static PrivacyUnlockScope fromStorage(Object? value) {
    if (value is! String) return PrivacyUnlockScope.appSession;
    final normalized = value.trim().toLowerCase().replaceAll('-', '_');
    for (final scope in PrivacyUnlockScope.values) {
      if (normalized == scope.storageValue ||
          normalized == scope.name.toLowerCase()) {
        return scope;
      }
    }
    return PrivacyUnlockScope.appSession;
  }
}

/// 离开后台宽限可选秒数（对齐参考版 0/30/120/180/300）
const List<int> kPrivacyBackgroundGraceOptions = <int>[0, 30, 120, 180, 300];

/// 宽限秒数展示文案
String privacyBackgroundGraceLabel(int seconds) => switch (seconds) {
  0 => '不等待',
  30 => '30 秒',
  120 => '2 分钟',
  180 => '3 分钟',
  300 => '5 分钟',
  _ => '$seconds 秒',
};

/// 密码设置/修改结果（UI 据此做内联错误分类）
enum PrivacyPasswordChangeResult {
  /// 成功（已写入新凭据）
  success,

  /// 已有密码时旧密码缺失或错误
  oldPasswordWrong,

  /// 新密码 trim 后为空或超过 128 字符
  invalidPassword,

  /// API 异常或写入失败
  failure,
}

/// 隐私设置与解锁状态（不可变）
@immutable
class PrivacyState {
  const PrivacyState({
    this.enabled = false,
    this.hasPassword = false,
    this.credentialError,
    this.verifyOnEnterGroup = true,
    this.verifyOnOpenBook = true,
    this.verifyOnAppStart = false,
    this.unlockScope = PrivacyUnlockScope.appSession,
    this.backgroundGraceSeconds = 0,
    this.sessionUnlocked = false,
    this.appStartVerified = false,
    this.loaded = false,
  });

  /// 是否启用私密功能（无密码时不可开启）
  final bool enabled;

  /// 本机是否已有隐私密码（来自 Rust `privacyHasPassword`）
  final bool hasPassword;

  /// 凭据读取失败信息（非 null 时启动闸门必须 fail-closed，不放行）
  final String? credentialError;

  /// 进入私密分组时验证（默认开）
  final bool verifyOnEnterGroup;

  /// 打开私密书籍时验证（默认开）
  final bool verifyOnOpenBook;

  /// 启动应用时验证（默认关）
  final bool verifyOnAppStart;

  /// 解锁频率（默认应用会话内）
  final PrivacyUnlockScope unlockScope;

  /// 离开后台宽限秒数（默认 0；仅 [unlockScope] 为 untilBackground 生效）
  final int backgroundGraceSeconds;

  /// 本次应用会话是否已解锁（解锁成功后为 true，[PrivacyNotifier.lock] 清除）
  final bool sessionUnlocked;

  /// 启动闸门是否已通过（解锁成功或已锁定后重新解锁；[lock] 清除）
  final bool appStartVerified;

  /// 偏好/凭据异步加载是否完成（未完成时启动闸门只显示占位，避免闪现主页）
  final bool loaded;

  /// 启动闸门是否应显示全屏锁
  ///
  /// 对齐参考版：enabled && hasPassword && verifyOnAppStart &&
  /// !appStartVerified && !sessionUnlocked。凭据读取错误单独由
  /// [credentialError] 判定（fail-closed）。
  bool get needsAppStartLock =>
      enabled &&
      hasPassword &&
      verifyOnAppStart &&
      !appStartVerified &&
      !sessionUnlocked;

  PrivacyState copyWith({
    bool? enabled,
    bool? hasPassword,
    Object? credentialError = _unset,
    bool? verifyOnEnterGroup,
    bool? verifyOnOpenBook,
    bool? verifyOnAppStart,
    PrivacyUnlockScope? unlockScope,
    int? backgroundGraceSeconds,
    bool? sessionUnlocked,
    bool? appStartVerified,
    bool? loaded,
  }) {
    return PrivacyState(
      enabled: enabled ?? this.enabled,
      hasPassword: hasPassword ?? this.hasPassword,
      credentialError: identical(credentialError, _unset)
          ? this.credentialError
          : credentialError as String?,
      verifyOnEnterGroup: verifyOnEnterGroup ?? this.verifyOnEnterGroup,
      verifyOnOpenBook: verifyOnOpenBook ?? this.verifyOnOpenBook,
      verifyOnAppStart: verifyOnAppStart ?? this.verifyOnAppStart,
      unlockScope: unlockScope ?? this.unlockScope,
      backgroundGraceSeconds:
          backgroundGraceSeconds ?? this.backgroundGraceSeconds,
      sessionUnlocked: sessionUnlocked ?? this.sessionUnlocked,
      appStartVerified: appStartVerified ?? this.appStartVerified,
      loaded: loaded ?? this.loaded,
    );
  }

  static const Object _unset = Object();
}
