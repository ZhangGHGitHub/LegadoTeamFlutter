import 'dart:convert';

import 'package:flutter/foundation.dart';

/// 生物识别快捷解锁状态（契约 §2.53 批9d）
///
/// 对应 Rust `privacyBiometricStateGet` 裸 JSON；**不含令牌摘要/令牌**，
/// 信封与 IV 仅在 [configured] 为 true 时有值。
@immutable
class PrivacyBiometricState {
  const PrivacyBiometricState({
    required this.configured,
    this.envelope,
    this.iv,
  });

  /// 三键齐备且摘要可解码为 32 字节
  final bool configured;

  /// 平台 Keystore/Keychain AES-GCM 密文（Base64）
  final String? envelope;

  /// AES-GCM IV（12 字节，Base64）
  final String? iv;

  @override
  bool operator ==(Object other) =>
      other is PrivacyBiometricState &&
      other.configured == configured &&
      other.envelope == envelope &&
      other.iv == iv;

  @override
  int get hashCode => Object.hash(configured, envelope, iv);

  @override
  String toString() =>
      'PrivacyBiometricState(configured: $configured, '
      'envelope: ${envelope == null ? null : '<redacted>'}, '
      'iv: ${iv == null ? null : '<redacted>'})';
}

/// 私密列表 JSON 解码（契约 §2.53，批9a）
///
/// Rust FFI 返回**裸 JSON 数组**；这里显式校验数组与元素类型，
/// 形态不符抛 [FormatException]（不静默跳过），让契约漂移尽早暴露。
/// 抽成纯函数便于单测，RustApi 仅做 FFI 调用 + 委托解码。
class PrivacyApiJson {
  const PrivacyApiJson._();

  /// 解码 `getPrivateBookUrls` 返回值（JSON 字符串数组）
  static List<String> decodeBookUrls(String json) {
    final list = _decodeList(json, 'getPrivateBookUrls');
    return list
        .map((item) {
          if (item is! String) {
            throw FormatException(
              'getPrivateBookUrls: 数组元素应为字符串，实际为 ${item.runtimeType}',
            );
          }
          return item;
        })
        .toList(growable: false);
  }

  /// 解码 `getPrivateGroupIds` 返回值（JSON 整数数组）
  static List<int> decodeGroupIds(String json) {
    final list = _decodeList(json, 'getPrivateGroupIds');
    return list
        .map((item) {
          if (item is! int) {
            throw FormatException(
              'getPrivateGroupIds: 数组元素应为整数，实际为 ${item.runtimeType}',
            );
          }
          return item;
        })
        .toList(growable: false);
  }

  static List<dynamic> _decodeList(String json, String method) {
    final dynamic decoded = jsonDecode(json);
    if (decoded is List<dynamic>) return decoded;
    throw FormatException('$method: 期望 JSON 数组，实际为 ${decoded.runtimeType}');
  }

  /// 解码 `privacyBiometricStateGet` 返回值
  ///
  /// 严格校验：必须是 JSON 对象；`configured` 必须为 bool；`envelope` / `iv`
  /// 必须为 String 或 null；configured 为 true 时两者都必须有值。
  static PrivacyBiometricState decodeBiometricState(String json) {
    final dynamic decoded = jsonDecode(json);
    if (decoded is! Map<String, dynamic>) {
      throw FormatException(
        'privacyBiometricStateGet: 期望 JSON 对象，实际为 ${decoded.runtimeType}',
      );
    }
    final configured = decoded['configured'];
    if (configured is! bool) {
      throw FormatException(
        'privacyBiometricStateGet: configured 应为 bool，实际为 '
        '${configured.runtimeType}',
      );
    }
    final envelope = decoded['envelope'];
    final iv = decoded['iv'];
    if (envelope != null && envelope is! String) {
      throw FormatException(
        'privacyBiometricStateGet: envelope 应为字符串或 null，实际为 '
        '${envelope.runtimeType}',
      );
    }
    if (iv != null && iv is! String) {
      throw FormatException(
        'privacyBiometricStateGet: iv 应为字符串或 null，实际为 '
        '${iv.runtimeType}',
      );
    }
    if (configured && (envelope == null || iv == null)) {
      throw const FormatException(
        'privacyBiometricStateGet: configured=true 时必须同时返回 envelope 与 iv',
      );
    }
    return PrivacyBiometricState(
      configured: configured,
      envelope: envelope as String?,
      iv: iv as String?,
    );
  }
}
