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
// [批9c] 追加按目标授权（EveryTime）与会话级授权的消费语义：
// - [sessionUnlocked] 仅在 AppSession / UntilBackground 频率下代表
//   “进程内放行全部私密内容”；
// - [grantedBookUrls] / [grantedGroupIds] 仅在 EveryTime 下使用，记录
//   “刚验证过的那一个目标”，离开即撤销（详见 PrivacyNotifier）。
//
// [批9d] 生物识别快捷解锁：
// - [biometricConfigured] 来自 Rust（摘要/信封/IV 三键齐备），只有平台
//   解封令牌并校验摘要通过才可能解锁；
// - [biometricStatus] 来自平台通道（硬件/录入/锁定/密钥状态），null 表示
//   尚未加载或读取失败，此时隐藏快捷入口。
//
// 编写：全栈工程师（设置批9b / 批9c / 批9d） ｜ 2026-11-10
import 'package:flutter/foundation.dart';

import '../../models/models.dart';
import '../../services/privacy_biometric_service.dart';
import '../../utils/book_group_match.dart';

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

/// 密码清除结果（UI 区分旧密错误与 API/写入失败）
enum PrivacyClearPasswordResult {
  /// 已删除凭据
  success,

  /// 当前密码为空或错误
  passwordWrong,

  /// 校验/删除异常
  failure,
}

/// 隐私设置与解锁状态（不可变）
@immutable
class PrivacyState {
  const PrivacyState({
    this.enabled = false,
    this.hasPassword = false,
    this.policyError,
    this.credentialError,
    this.verifyOnEnterGroup = true,
    this.verifyOnOpenBook = true,
    this.verifyOnAppStart = false,
    this.unlockScope = PrivacyUnlockScope.appSession,
    this.backgroundGraceSeconds = 0,
    this.sessionUnlocked = false,
    this.appStartVerified = false,
    this.grantedBookUrls = const <String>{},
    this.grantedGroupIds = const <int>{},
    this.biometricConfigured = false,
    this.biometricStatus,
    this.loaded = false,
  });

  /// 是否启用私密功能（无密码时不可开启）
  final bool enabled;

  /// 本机是否已有隐私密码（来自 Rust `privacyHasPassword`）
  final bool hasPassword;

  /// 策略读取失败信息（非 null 时启动闸门必须 fail-closed，不放行）
  final String? policyError;

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

  /// [批9c] EveryTime 频率下刚验证过的单本目标（离开即撤销）
  final Set<String> grantedBookUrls;

  /// [批9c] EveryTime 频率下刚验证过的分组目标（离开分组即撤销）
  final Set<int> grantedGroupIds;

  /// [批9d] 生物快捷解锁是否已配置（Rust 三键齐备）
  final bool biometricConfigured;

  /// [批9d] 平台生物识别能力状态（null = 尚未加载或读取失败）
  final PrivacyBiometricStatus? biometricStatus;

  /// [批9d] 是否可提供生物快捷解锁入口
  ///
  /// 需要：已有密码 + Rust 已配置凭据 + 平台当前可用（硬件/录入/未锁定）。
  bool get biometricUsable =>
      hasPassword &&
      biometricConfigured &&
      (biometricStatus?.available ?? false);

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

  // ===== [批9c] 内容授权判定 =====

  /// 会话级是否放行全部私密内容
  ///
  /// 只有 AppSession / UntilBackground 两种频率把「会话解锁」当作内容放行；
  /// EveryTime 下即使启动闸门解锁（`sessionUnlocked` 为 true）也只证明
  /// “进得来”，不代表对任何分组/书籍的授权——否则单书/分组验证形同虚设。
  bool get contentSessionUnlocked =>
      enabled && sessionUnlocked && unlockScope != PrivacyUnlockScope.everyTime;

  /// 指定目标是否已获准查看
  ///
  /// - 总开关关闭：恒真（不验证、不脱敏）；
  /// - 会话级解锁：恒真；
  /// - EveryTime：命中「刚验证过的单本 / 分组」才放行。
  bool isTargetGranted({String? bookUrl, int? groupId}) {
    if (!enabled) return true;
    if (contentSessionUnlocked) return true;
    if (bookUrl != null && grantedBookUrls.contains(bookUrl)) return true;
    if (groupId != null && grantedGroupIds.contains(groupId)) return true;
    return false;
  }

  /// 书籍是否已获准查看（所属分组已授权时组内书一并放行）
  bool isBookTargetGranted(Book book) {
    if (!enabled) return true;
    if (contentSessionUnlocked) return true;
    if (grantedBookUrls.contains(book.bookUrl)) return true;
    // 进了私密分组还要逐本再验证会非常吵：任一已授权分组命中即放行。
    // 复用混合语义（2^n 位掩码 / 旧时间戳 exact），不做裸位与。
    for (final groupId in grantedGroupIds) {
      if (bookBelongsToCustomGroup(book, groupId)) return true;
    }
    return false;
  }

  /// 单本是否应脱敏
  ///
  /// - [isPrivate] 由调用方按「单本标记 ∪ 私密分组」判定后传入；
  /// - 「打开书籍时验证」关闭时不脱敏（对齐参考版 `verifyOnOpenBook`）；
  /// - 总开关关闭时 [isBookTargetGranted] 恒真，同样不脱敏。
  bool isBookLocked(Book book, {required bool isPrivate}) {
    if (!enabled || !verifyOnOpenBook) return false;
    return isPrivate && !isBookTargetGranted(book);
  }

  /// 分组内容区是否应整页锁定
  bool isGroupContentLocked(int groupId, {required bool isPrivate}) {
    if (!enabled || !verifyOnEnterGroup) return false;
    return isPrivate && !isTargetGranted(groupId: groupId);
  }

  PrivacyState copyWith({
    bool? enabled,
    bool? hasPassword,
    Object? policyError = _unset,
    Object? credentialError = _unset,
    bool? verifyOnEnterGroup,
    bool? verifyOnOpenBook,
    bool? verifyOnAppStart,
    PrivacyUnlockScope? unlockScope,
    int? backgroundGraceSeconds,
    bool? sessionUnlocked,
    bool? appStartVerified,
    Set<String>? grantedBookUrls,
    Set<int>? grantedGroupIds,
    bool? biometricConfigured,
    Object? biometricStatus = _unset,
    bool? loaded,
  }) {
    return PrivacyState(
      enabled: enabled ?? this.enabled,
      hasPassword: hasPassword ?? this.hasPassword,
      policyError: identical(policyError, _unset)
          ? this.policyError
          : policyError as String?,
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
      grantedBookUrls: grantedBookUrls ?? this.grantedBookUrls,
      grantedGroupIds: grantedGroupIds ?? this.grantedGroupIds,
      biometricConfigured: biometricConfigured ?? this.biometricConfigured,
      biometricStatus: identical(biometricStatus, _unset)
          ? this.biometricStatus
          : biometricStatus as PrivacyBiometricStatus?,
      loaded: loaded ?? this.loaded,
    );
  }

  static const Object _unset = Object();
}
