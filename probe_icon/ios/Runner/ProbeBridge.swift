import Flutter
import UIKit

/// 探针桥：单一备选图标 probe 的切换 + 全量错误回传。
///
/// 与主 app LauncherIconBridge 的差异（本探针刻意做减法）：
/// - 只有 1 个备选名 "probe"；
/// - set 只走公开 API（不试私有旁路——探针目的是判定结构/语境，不是绕过）；
/// - status 只保留归因必需的字段。
@objc class ProbeBridge: NSObject {
  static let shared = ProbeBridge()

  private var channel: FlutterMethodChannel?

  /// 唯一备选图标名（= Info.plist CFBundleAlternateIcons 键）。
  static let probeName = "probe"

  func attach(messenger: FlutterBinaryMessenger) {
    guard channel == nil else { return }
    let ch = FlutterMethodChannel(name: "probe/icon", binaryMessenger: messenger)
    ch.setMethodCallHandler { [weak self] call, result in
      self?.handle(call: call, result: result)
    }
    channel = ch
  }

  private func handle(call: FlutterMethodCall, result: @escaping FlutterResult) {
    if call.method == "status" {
      DispatchQueue.main.async {
        let bundle = Bundle.main
        var diskHasProbe = false
        var loosePresent = 0
        let fm = FileManager.default
        let root = bundle.bundlePath as NSString
        // 磁盘 Info.plist：CFBundleAlternateIcons.probe 是否存在（set 的直接前提）。
        if let p = bundle.path(forResource: "Info", ofType: "plist"),
           let data = fm.contents(atPath: p),
           let obj = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
           let d = obj as? [AnyHashable: Any],
           let icons = d["CFBundleIcons"] as? [AnyHashable: Any],
           let alt = icons["CFBundleAlternateIcons"] as? [AnyHashable: Any] {
          diskHasProbe = alt.keys.contains(self.probeName)
        }
        // bundle 根散文件：probe60x60 @2x / @3x（纯 legacy 路径的落盘图像）。
        for suffix in ["@2x", "@3x"] where fm.fileExists(atPath: root.appendingPathComponent("probe60x60\(suffix).png")) {
          loosePresent += 1
        }
        result([
          "systemVersion": UIDevice.current.systemVersion,
          "supportsAlt": UIApplication.shared.supportsAlternateIcons,
          "diskHasProbe": diskHasProbe,
          "looseFiles": "\(loosePresent)/2",
          "bundlePath": bundle.bundlePath,
        ])
      }
      return
    }
    guard call.method == "set" || call.method == "reset" else {
      result(FlutterMethodNotImplemented)
      return
    }
    let isSet = call.method == "set"
    DispatchQueue.main.async {
      guard UIApplication.shared.supportsAlternateIcons else {
        self.reply(result, NSError(domain: "ProbeBridge", code: -1, userInfo: [NSLocalizedDescriptionKey: "系统不支持备选图标"]))
        return
      }
      let name: String? = isSet ? Self.probeName : nil
      UIApplication.shared.setAlternateIconName(name, completionHandler: { error in
        if let error = error {
          self.reply(result, error)
        } else {
          result(nil)
        }
      })
    }
  }

  /// 全量错误回传（domain/code/userInfo/underlyingError），用于精确归因 -54。
  private func reply(_ result: @escaping FlutterResult, _ error: Error) {
    let ns = error as NSError
    var details: [String: Any] = ["domain": ns.domain, "code": ns.code]
    for (k, v) in ns.userInfo { details["userInfo.\(k)"] = "\(v)" }
    if let u = ns.userInfo[NSUnderlyingErrorKey] as? Error {
      let un = u as NSError
      details["underlyingDomain"] = un.domain
      details["underlyingCode"] = un.code
    }
    result(FlutterError(code: "PROBE_ICON_ERROR", message: error.localizedDescription, details: details))
  }
}
