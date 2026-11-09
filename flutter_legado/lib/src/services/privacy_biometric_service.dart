// 生物识别快捷解锁平台通道（契约 §2.53 批9d）
//
// 安全模型：平台只认证并解封 **32B 随机令牌**（Dart 生成），不封装密码；
// 令牌摘要由 Rust 保存，平台加密信封写入 Rust 配置表。通道协议：
// - `getStatus` → `{available: bool, hasKey: bool, reason: String?}`；
// - `enable(tokenBase64)` → `{envelope: String, iv: String}`；
// - `unlock({envelope, iv})` → `String`（令牌 Base64）；
// - `deleteKey()` → void。
// enable/unlock 由 Dart 侧 45s 超时保护（可注入），超时映射 `timeout`。
// 错误统一经 `PlatformException.code` 返回，取值与 Android/iOS 原生对齐。
//
// 编写：全栈工程师（批9d） ｜ 2026-11-10
import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 生成 32 字节随机解锁令牌（标准 Base64）
///
/// 推送进平台 Keystore/Keychain 加密的只有这个令牌，**不是密码**；
/// Rust 只保存其 SHA-256 摘要。
String generatePrivacyBiometricToken() {
  final random = Random.secure();
  return base64Encode(List<int>.generate(32, (_) => random.nextInt(256)));
}

/// 生物识别平台错误码（与 Android `BiometricBridge` / iOS `BiometricBridge`
/// 返回的 `PlatformException.code` 逐字对齐）
enum PrivacyBiometricErrorCode {
  /// 系统版本过低或平台未实现（桌面端 / Android API < 30）
  unsupported('unsupported'),

  /// 设备没有可用的生物识别硬件
  noHardware('no_hardware'),

  /// 尚未录入指纹/面容
  notEnrolled('not_enrolled'),

  /// 生物识别暂时锁定（尝试次数过多/硬件不可用）
  lockedOut('locked_out'),

  /// 生物识别被系统永久锁定（需改用密码）
  permanentlyLockedOut('permanently_locked_out'),

  /// Keystore/Keychain 密钥因指纹/面容变更而失效
  keyInvalidated('key_invalidated'),

  /// 用户取消认证
  cancelled('cancelled'),

  /// 平台认证/通道超时（Dart 侧超时保护，原生不返回该码）
  timeout('timeout'),

  /// 其他失败（认证失败/加解密失败/通道异常）
  failed('failed');

  const PrivacyBiometricErrorCode(this.code);

  /// 与原生约定的错误码字符串
  final String code;

  /// 宽容解析：未知/空码一律归为 [failed]
  static PrivacyBiometricErrorCode fromCode(String? code) {
    for (final value in PrivacyBiometricErrorCode.values) {
      if (value.code == code) return value;
    }
    return PrivacyBiometricErrorCode.failed;
  }
}

/// 生物识别命令失败分类（Notifier 状态机 / UI 文案使用，含 Dart 侧前置校验）
enum PrivacyBiometricCommandError {
  /// 尚未设置隐私密码（Dart 前置校验，不允许开启）
  noPassword,

  /// 未配置或已失效（Dart 前置校验 / Rust 状态与内存不一致）
  notConfigured,

  unsupported,
  noHardware,
  notEnrolled,
  lockedOut,
  permanentlyLockedOut,
  keyInvalidated,
  cancelled,
  timeout,
  failed;

  /// 从平台错误码映射
  static PrivacyBiometricCommandError fromCode(
    PrivacyBiometricErrorCode code,
  ) => switch (code) {
    PrivacyBiometricErrorCode.unsupported => unsupported,
    PrivacyBiometricErrorCode.noHardware => noHardware,
    PrivacyBiometricErrorCode.notEnrolled => notEnrolled,
    PrivacyBiometricErrorCode.lockedOut => lockedOut,
    PrivacyBiometricErrorCode.permanentlyLockedOut => permanentlyLockedOut,
    PrivacyBiometricErrorCode.keyInvalidated => keyInvalidated,
    PrivacyBiometricErrorCode.cancelled => cancelled,
    PrivacyBiometricErrorCode.timeout => timeout,
    PrivacyBiometricErrorCode.failed => failed,
  };

  /// 中文提示文案
  String get message => switch (this) {
    noPassword => '请先设置隐私密码',
    notConfigured => '生物快捷解锁未开启或已失效，请改用密码',
    unsupported => '当前系统不支持生物识别',
    noHardware => '设备不支持指纹或面容识别',
    notEnrolled => '尚未录入指纹或面容，请先在系统设置中添加',
    lockedOut => '生物识别暂时锁定，请稍后重试或改用密码',
    permanentlyLockedOut => '生物识别已被系统锁定，请改用密码，并在解锁后重新开启快捷解锁',
    keyInvalidated => '指纹或面容已变更，生物快捷解锁已关闭，请改用密码并重新开启',
    cancelled => '已取消生物识别',
    timeout => '生物识别超时，请重试或改用密码',
    failed => '生物识别失败，请重试或改用密码',
  };
}

/// 生物识别命令结果（`error == null` 表示成功）
@immutable
class PrivacyBiometricOutcome {
  const PrivacyBiometricOutcome.success() : error = null, detail = null;

  const PrivacyBiometricOutcome.failure(this.error, {this.detail});

  /// 失败分类；成功为 null
  final PrivacyBiometricCommandError? error;

  /// 附加细节（仅日志/测试使用，不直接展示）
  final String? detail;

  bool get isSuccess => error == null;

  /// 面向用户的中文提示（成功为空串）
  String get userMessage => error?.message ?? '';

  @override
  String toString() => isSuccess
      ? 'PrivacyBiometricOutcome.success()'
      : 'PrivacyBiometricOutcome.failure($error, detail: $detail)';
}

/// 平台生物识别能力状态（`getStatus` 结果）
@immutable
class PrivacyBiometricStatus {
  const PrivacyBiometricStatus({
    required this.available,
    this.hasKey = false,
    this.reason,
  });

  /// 当前是否可用（硬件存在、已录入、未被锁定）
  final bool available;

  /// Keystore/Keychain 中是否存在本应用的生物密钥
  final bool hasKey;

  /// 不可用原因（available 为 true 时为 null）
  final PrivacyBiometricErrorCode? reason;

  /// 仅可用于展示的中文说明
  String get unavailableMessage => reason == null
      ? ''
      : PrivacyBiometricCommandError.fromCode(reason!).message;

  PrivacyBiometricStatus copyWith({
    bool? available,
    bool? hasKey,
    PrivacyBiometricErrorCode? reason,
    bool clearReason = false,
  }) {
    return PrivacyBiometricStatus(
      available: available ?? this.available,
      hasKey: hasKey ?? this.hasKey,
      reason: clearReason ? null : (reason ?? this.reason),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is PrivacyBiometricStatus &&
      other.available == available &&
      other.hasKey == hasKey &&
      other.reason == reason;

  @override
  int get hashCode => Object.hash(available, hasKey, reason);

  @override
  String toString() =>
      'PrivacyBiometricStatus(available: $available, hasKey: $hasKey, '
      'reason: ${reason?.code})';
}

/// 平台加密信封（enable 结果）
@immutable
class PrivacyBiometricEnvelope {
  const PrivacyBiometricEnvelope({required this.envelope, required this.iv});

  /// AES-GCM 密文（Base64）
  final String envelope;

  /// AES-GCM IV（12 字节，Base64）
  final String iv;
}

/// 平台异常（保留原始错误码供调用方分类）
class PrivacyBiometricException implements Exception {
  const PrivacyBiometricException(this.code, [this.message]);

  final PrivacyBiometricErrorCode code;
  final String? message;

  @override
  String toString() =>
      'PrivacyBiometricException(${code.code}'
      '${message == null ? '' : ': $message'})';
}

/// 生物识别平台服务（可注入 Fake）
abstract class PrivacyBiometricService {
  /// 查询能力与密钥状态
  Future<PrivacyBiometricStatus> getStatus();

  /// 认证后加密 [tokenBase64]，返回信封/IV
  Future<PrivacyBiometricEnvelope> enable(String tokenBase64);

  /// 认证后解封 [envelope]（IV 为 [iv]），返回令牌 Base64
  ///
  /// Android 用 Keystore 密钥解密；iOS 的 Keychain item 本身受生物 ACL
  /// 保护，envelope/iv 仅作跨平台占位（见 iOS 桥文件头说明）。
  Future<String> unlock({required String envelope, required String iv});

  /// 删除 Keystore/Keychain 密钥（不存在为 no-op）
  Future<void> deleteKey();
}

/// MethodChannel 实现（Android `legado/privacy_biometric`，iOS 同通道）
///
/// 桌面端（Windows/Linux/macOS）与 Web 无原生实现：直接返回
/// `unsupported`，不发起必然悬挂的通道调用。测试可显式传入
/// [platformSupported] 以在任意宿主上验证通道协议。
class MethodChannelPrivacyBiometricService implements PrivacyBiometricService {
  const MethodChannelPrivacyBiometricService({
    bool? platformSupported,
    this.authTimeout = defaultAuthTimeout,
  }) : _platformSupported = platformSupported;

  /// 认证类通道（enable/unlock）默认超时：覆盖用户输入指纹/面容的时间，
  /// 避免启动锁或解锁弹窗的 busy 状态永久常驻。
  static const Duration defaultAuthTimeout = Duration(seconds: 45);

  /// enable/unlock 超时（测试可注入短时长）
  final Duration authTimeout;

  /// null = 按运行平台判定（仅 Android/iOS 可用）
  final bool? _platformSupported;

  /// 通道名（Android `MainActivity` / iOS `AppDelegate` 注册同名通道）
  static const String channelName = 'legado/privacy_biometric';

  static const MethodChannel _channel = MethodChannel(channelName);

  bool get _supported =>
      _platformSupported ??
      (!kIsWeb &&
          (defaultTargetPlatform == TargetPlatform.android ||
              defaultTargetPlatform == TargetPlatform.iOS));

  @override
  Future<PrivacyBiometricStatus> getStatus() async {
    if (!_supported) {
      return const PrivacyBiometricStatus(
        available: false,
        reason: PrivacyBiometricErrorCode.unsupported,
      );
    }
    try {
      final raw = await _channel.invokeMapMethod<String, Object?>('getStatus');
      if (raw == null) {
        return const PrivacyBiometricStatus(
          available: false,
          reason: PrivacyBiometricErrorCode.unsupported,
        );
      }
      final available = raw['available'] == true;
      final hasKey = raw['hasKey'] == true;
      final reasonCode = raw['reason'];
      return PrivacyBiometricStatus(
        available: available,
        hasKey: hasKey,
        reason: available
            ? null
            : PrivacyBiometricErrorCode.fromCode(
                reasonCode is String ? reasonCode : null,
              ),
      );
    } on MissingPluginException {
      // 桌面端（Windows/Linux/macOS）未注册通道：按不支持处理，不阻塞 UI
      return const PrivacyBiometricStatus(
        available: false,
        reason: PrivacyBiometricErrorCode.unsupported,
      );
    } on PlatformException catch (e) {
      return PrivacyBiometricStatus(
        available: false,
        reason: PrivacyBiometricErrorCode.fromCode(e.code),
      );
    }
  }

  @override
  Future<PrivacyBiometricEnvelope> enable(String tokenBase64) async {
    if (!_supported) {
      throw const PrivacyBiometricException(
        PrivacyBiometricErrorCode.unsupported,
      );
    }
    try {
      final raw = await _channel
          .invokeMapMethod<String, Object?>('enable', <String, Object?>{
            'token': tokenBase64,
          })
          .timeout(authTimeout);
      final envelope = raw?['envelope'];
      final iv = raw?['iv'];
      if (envelope is! String ||
          iv is! String ||
          envelope.isEmpty ||
          iv.isEmpty) {
        throw const PrivacyBiometricException(
          PrivacyBiometricErrorCode.failed,
          '原生 enable 返回缺少 envelope/iv',
        );
      }
      return PrivacyBiometricEnvelope(envelope: envelope, iv: iv);
    } on TimeoutException {
      throw const PrivacyBiometricException(
        PrivacyBiometricErrorCode.timeout,
        '原生 enable 超时',
      );
    } on MissingPluginException {
      throw const PrivacyBiometricException(
        PrivacyBiometricErrorCode.unsupported,
      );
    } on PlatformException catch (e) {
      throw PrivacyBiometricException(
        PrivacyBiometricErrorCode.fromCode(e.code),
        e.message,
      );
    }
  }

  @override
  Future<String> unlock({required String envelope, required String iv}) async {
    if (!_supported) {
      throw const PrivacyBiometricException(
        PrivacyBiometricErrorCode.unsupported,
      );
    }
    try {
      final token = await _channel
          .invokeMethod<String>('unlock', <String, Object?>{
            'envelope': envelope,
            'iv': iv,
          })
          .timeout(authTimeout);
      if (token == null || token.isEmpty) {
        throw const PrivacyBiometricException(
          PrivacyBiometricErrorCode.failed,
          '原生 unlock 未返回令牌',
        );
      }
      return token;
    } on TimeoutException {
      throw const PrivacyBiometricException(
        PrivacyBiometricErrorCode.timeout,
        '原生 unlock 超时',
      );
    } on MissingPluginException {
      throw const PrivacyBiometricException(
        PrivacyBiometricErrorCode.unsupported,
      );
    } on PlatformException catch (e) {
      throw PrivacyBiometricException(
        PrivacyBiometricErrorCode.fromCode(e.code),
        e.message,
      );
    }
  }

  @override
  Future<void> deleteKey() async {
    if (!_supported) {
      throw const PrivacyBiometricException(
        PrivacyBiometricErrorCode.unsupported,
      );
    }
    try {
      // 删除密钥是清理动作，不允许平台无响应拖住改密/清密流程
      await _channel
          .invokeMethod<void>('deleteKey')
          .timeout(const Duration(seconds: 1));
    } on TimeoutException {
      throw const PrivacyBiometricException(
        PrivacyBiometricErrorCode.timeout,
        '原生 deleteKey 超时',
      );
    } on MissingPluginException {
      throw const PrivacyBiometricException(
        PrivacyBiometricErrorCode.unsupported,
      );
    } on PlatformException catch (e) {
      throw PrivacyBiometricException(
        PrivacyBiometricErrorCode.fromCode(e.code),
        e.message,
      );
    }
  }
}
