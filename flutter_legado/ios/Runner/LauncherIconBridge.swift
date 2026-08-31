import Flutter
import UIKit

/// 运行时更换桌面图标（对齐原版 LauncherIconHelp.changeIcon）。
///
/// iOS 经 UIApplication.setAlternateIconName 在 Info.plist
/// CFBundleIcons/CFBundleAlternateIcons 声明的变体间切换；传 nil
/// 恢复默认图标。系统限制：每次启动仅可切换一次，且下次启动生效
/// （由 Dart 侧提示）。
@objc class LauncherIconBridge: NSObject {
  static let shared = LauncherIconBridge()

  private var channel: FlutterMethodChannel?

  private override init() {
    super.init()
  }

  /// 在 AppDelegate 的引擎初始化回调中调用（进程内仅一次）
  func attach(messenger: FlutterBinaryMessenger) {
    guard channel == nil else { return }
    let ch = FlutterMethodChannel(name: "legado/launcher_icon", binaryMessenger: messenger)
    ch.setMethodCallHandler { [weak self] call, result in
      self?.handle(call: call, result: result)
    }
    channel = ch
  }

  private func handle(call: FlutterMethodCall, result: @escaping FlutterResult) {
    if call.method == "status" {
      // 同步应答（纯 Bundle 读取，无 UIKit 异步）：集成测试回归门禁。
      // 能收到此方法 = AppDelegate 通道接线完好；canSet=true = Info.plist
      // CFBundleAlternateIcons 声明 launcher1~6（setAlternateIconName 的前提）。
      // （UIKit 无公开的同步查询 API；set 的 completion 在模拟器上不回调，
      // 故门禁不用 set。）
      let bundle = Bundle.main
      let dict = bundle.infoDictionary ?? [:]
      // [AnyHashable: Any] 是 NSDictionary 的保底桥接类型（[String: Any]
      // 强转存在失败风险）；altKeys/bundlePath 为 CI 诊断证据字段。
      let altNS = (dict["CFBundleAlternateIcons"] as? [AnyHashable: Any]) ?? [:]
      let names = ["launcher1", "launcher2", "launcher3", "launcher4", "launcher5", "launcher6"]
      result([
        "canSet": names.allSatisfy { altNS[$0] != nil },
        "altKeys": altNS.keys.map { "\($0)" }.sorted(),
        "bundlePath": bundle.bundlePath,
      ])
      return
    }
    guard call.method == "set" else {
      result(FlutterMethodNotImplemented)
      return
    }
    let args = call.arguments as? [String: Any] ?? [:]
    let icon = args["icon"] as? String ?? "iconMain"
    // UIKit 须在主线程调用；method channel 回调运行在后台平台线程
    DispatchQueue.main.async {
      if icon == "iconMain" {
        // 传 nil 恢复默认图标
        UIApplication.shared.setAlternateIconName(nil, completionHandler: { error in
          self.reply(result, error)
        })
      } else {
        // icon1~icon6 -> launcher1~launcher6（Info.plist CFBundleAlternateIcons 键）
        let name = "launcher" + icon.replacingOccurrences(of: "icon", with: "")
        UIApplication.shared.setAlternateIconName(name, completionHandler: { error in
          self.reply(result, error)
        })
      }
    }
  }

  private func reply(_ result: @escaping FlutterResult, _ error: Error?) {
    if let error = error {
      result(FlutterError(code: "LAUNCHER_ICON_ERROR", message: error.localizedDescription, details: nil))
    } else {
      result(nil)
    }
  }
}
