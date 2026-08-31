import Flutter
import UIKit

/// 运行时更换桌面图标（对齐原版 LauncherIconHelp.changeIcon）。
///
/// iOS 经 UIApplication.setAlternateIconName 在 Info.plist
/// CFBundleIcons/CFBundleAlternateIcons 声明的变体间切换；选 iconMain
/// 时 cancelAlternateIconSwitch 恢复默认。系统限制：每次启动仅可切换
/// 一次，且下次启动生效（由 Dart 侧提示）。
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
    guard call.method == "set" else {
      result(FlutterMethodNotImplemented)
      return
    }
    let args = call.arguments as? [String: Any] ?? [:]
    let icon = args["icon"] as? String ?? "iconMain"
    if icon == "iconMain" {
      UIApplication.shared.cancelAlternateIconSwitch(completionHandler: { error in
        reply(result, error)
      })
    } else {
      // icon1~icon6 -> launcher1~launcher6（Info.plist CFBundleAlternateIcons 键）
      let name = "launcher" + icon.replacingOccurrences(of: "icon", with: "")
      UIApplication.shared.setAlternateIconName(name, completionHandler: { error in
        reply(result, error)
      })
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
