import Flutter
import LocalAuthentication
import Security

/// 生物识别快捷解锁桥（契约 §2.53 批9d）——通道协议与 Android
/// `PrivacyBiometricBridge.kt` 对齐：`getStatus` / `enable` / `unlock` /
/// `deleteKey`，错误码逐字一致。
///
/// 安全模型：平台只封装 **32B 随机令牌**（Dart 生成），绝不封装密码。
/// iOS 侧用 `LAContext` 认证 + Keychain `kSecAccessControlBiometryCurrentSet`
/// 保护令牌（`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`）；新增/变更
/// 指纹或面容后系统自动使 Keychain item 失效（读取返回 itemNotFound），
/// 本桥统一映射为 `key_invalidated`，由 Dart 清理 Rust 凭据并关闭开关。
///
/// 跨平台契约说明：Rust 需要 envelope/iv 三元组才能跨平台表达「已配置」。
/// iOS 的“信封”就是受生物 ACL 保护的 Keychain item 本身，因此 `enable`
/// 返回固定标记 envelope 与随机 12B iv 仅用于满足 Rust 长度校验，
/// **不参与 iOS 解密**；`unlock` 忽略入参 envelope/iv，直接读取 Keychain。
///
/// 注意：本文件在 Windows 环境无法编译验证；实现保持保守、只使用公开 API。
///
/// 编写：全栈工程师（批9d） ｜ 2026-11-10
@objc class PrivacyBiometricBridge: NSObject {
  static let shared = PrivacyBiometricBridge()

  private static let channelName = "legado/privacy_biometric"
  private static let keychainService = "io.legado.flutter.privacy_biometric"
  private static let keychainAccount = "token"
  private static let tokenBytes = 32
  private static let ivBytes = 12
  /// iOS Keychain 信封占位标记（Rust 只校验 1..4096B）
  private static let envelopeMarker = "keychain-v1"

  private var channel: FlutterMethodChannel?

  private override init() {
    super.init()
  }

  /// 在 AppDelegate 的引擎初始化回调中调用（进程内仅一次）
  func attach(messenger: FlutterBinaryMessenger) {
    guard channel == nil else { return }
    let ch = FlutterMethodChannel(
      name: Self.channelName,
      binaryMessenger: messenger
    )
    ch.setMethodCallHandler { [weak self] call, result in
      guard let self = self else {
        result(FlutterError(code: "failed", message: "生物识别桥已释放", details: nil))
        return
      }
      self.handle(call, result: result)
    }
    channel = ch
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "getStatus":
      result(status())
    case "enable":
      enable(call, result: result)
    case "unlock":
      unlock(result: result)
    case "deleteKey":
      deleteKey()
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // MARK: - 状态

  private func status() -> [String: Any] {
    let context = LAContext()
    var authError: NSError?
    let available = context.canEvaluatePolicy(
      .deviceOwnerAuthenticationWithBiometrics,
      error: &authError
    )
    return [
      "available": available,
      "hasKey": hasKey(),
      "reason": available ? NSNull() : mapAuthError(authError as Error?),
    ]
  }

  // MARK: - 开启：认证后写入 Keychain

  private func enable(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard
      let args = call.arguments as? [String: Any],
      let tokenBase64 = args["token"] as? String,
      let tokenData = Data(base64Encoded: tokenBase64),
      tokenData.count == Self.tokenBytes
    else {
      result(FlutterError(code: "failed", message: "令牌必须为 32 字节 Base64", details: nil))
      return
    }

    let context = LAContext()
    context.localizedFallbackTitle = ""
    context.evaluatePolicy(
      .deviceOwnerAuthenticationWithBiometrics,
      localizedReason: "开启生物快捷解锁"
    ) { success, error in
      DispatchQueue.main.async {
        guard success else {
          result(FlutterError(
            code: self.mapAuthError(error),
            message: self.authErrorMessage(error),
            details: nil
          ))
          return
        }
        let status = self.storeToken(tokenData)
        guard status == errSecSuccess else {
          result(FlutterError(
            code: self.mapKeychainStatus(status),
            message: "写入生物识别凭据失败（\(status)）",
            details: nil
          ))
          return
        }
        result([
          "envelope": Data(Self.envelopeMarker.utf8).base64EncodedString(),
          "iv": Data(self.randomBytes(Self.ivBytes)).base64EncodedString(),
        ])
      }
    }
  }

  // MARK: - 解锁：认证后读取 Keychain

  /// 入参 envelope/iv 为跨平台占位，iOS 不使用（见文件头说明）。
  private func unlock(result: @escaping FlutterResult) {
    let context = LAContext()
    context.localizedFallbackTitle = ""
    context.evaluatePolicy(
      .deviceOwnerAuthenticationWithBiometrics,
      localizedReason: "使用生物识别解锁"
    ) { success, error in
      DispatchQueue.main.async {
        guard success else {
          result(FlutterError(
            code: self.mapAuthError(error),
            message: self.authErrorMessage(error),
            details: nil
          ))
          return
        }
        let (status, data) = self.loadToken(context: context)
        guard status == errSecSuccess, let token = data else {
          // itemNotFound 通常意味着系统因指纹/面容变更使 item 失效
          result(FlutterError(
            code: self.mapKeychainStatus(status),
            message: "读取生物识别凭据失败（\(status)）",
            details: nil
          ))
          return
        }
        guard token.count == Self.tokenBytes else {
          result(FlutterError(code: "failed", message: "令牌长度异常", details: nil))
          return
        }
        result(token.base64EncodedString())
      }
    }
  }

  // MARK: - 删除

  private func deleteKey() {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: Self.keychainService,
      kSecAttrAccount as String: Self.keychainAccount,
    ]
    SecItemDelete(query as CFDictionary)
  }

  // MARK: - Keychain

  /// 写入受生物 ACL 保护的令牌（覆盖旧 item）
  private func storeToken(_ data: Data) -> OSStatus {
    deleteKey()
    var accessError: Unmanaged<CFError>?
    guard
      let access = SecAccessControlCreateWithFlags(
        nil,
        kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        .biometryCurrentSet,
        &accessError
      )
    else {
      return errSecParam
    }
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: Self.keychainService,
      kSecAttrAccount as String: Self.keychainAccount,
      kSecValueData as String: data,
      kSecAttrAccessControl as String: access,
    ]
    return SecItemAdd(query as CFDictionary, nil)
  }

  /// 认证成功后读取令牌（复用 LAContext，避免二次弹窗）
  private func loadToken(context: LAContext) -> (OSStatus, Data?) {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: Self.keychainService,
      kSecAttrAccount as String: Self.keychainAccount,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
      kSecUseAuthenticationContext as String: context,
    ]
    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    return (status, item as? Data)
  }

  /// 仅查询是否存在（禁止交互，避免启动时弹生物识别框）
  private func hasKey() -> Bool {
    let context = LAContext()
    context.interactionNotAllowed = true
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: Self.keychainService,
      kSecAttrAccount as String: Self.keychainAccount,
      kSecReturnAttributes as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
      kSecUseAuthenticationContext as String: context,
    ]
    var item: CFTypeRef?
    return SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess
  }

  private func randomBytes(_ count: Int) -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: count)
    let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
    if status != errSecSuccess {
      // 兜底：系统 CSPRNG 不可用时返回全零 IV（仅占位，不参与解密）
      return [UInt8](repeating: 0, count: count)
    }
    return bytes
  }

  // MARK: - 错误码映射

  private func mapAuthError(_ error: Error?) -> String {
    guard let laError = error as? LAError else { return "failed" }
    switch laError.code {
    case .biometryNotAvailable:
      return "no_hardware"
    case .biometryNotEnrolled, .passcodeNotSet:
      return "not_enrolled"
    case .biometryLockout:
      return "locked_out"
    case .biometryDisallowed:
      // 策略禁用生物识别：系统层面不可恢复，明确按 failed 处理
      return "failed"
    case .userCancel, .appCancel, .systemCancel:
      return "cancelled"
    case .authenticationFailed:
      return "failed"
    default:
      return "failed"
    }
  }

  private func authErrorMessage(_ error: Error?) -> String {
    return (error as NSError?)?.localizedDescription ?? "生物识别失败"
  }

  private func mapKeychainStatus(_ status: OSStatus) -> String {
    switch status {
    case errSecSuccess:
      return "failed"
    case errSecItemNotFound:
      // 指纹/面容变更或 item 被系统失效
      return "key_invalidated"
    case errSecUserCanceled:
      return "cancelled"
    case errSecAuthFailed:
      return "failed"
    case errSecInteractionNotAllowed:
      return "locked_out"
    default:
      return "failed"
    }
  }
}
