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
      // 同步应答（Bundle/文件读取，无 UIKit 异步）：集成测试回归门禁。
      // canSet = 已安装 bundle 磁盘 Info.plist 的 CFBundleAlternateIcons 声明 launcher1~6
      // （setAlternateIconName 的直接前提；UIKit 无公开同步查询 API，
      // set 的 completion 在模拟器上不回调，故门禁不用 set）。
      // altIconNames = 各条目「键=CFBundleIconName」对：系统按 Assets.car 中
      // appiconset 名（launcher1.appiconset…）解析图标——与主图标
      // AppIcon.appiconset 同一条已验证可用的解析路径；值不等于键、或
      // appiconset 未编入资产目录，真机 setAlternateIconName 将失败（-54）。
      let bundle = Bundle.main
      let names = ["launcher1", "launcher2", "launcher3", "launcher4", "launcher5", "launcher6"]
      // 证据 A：磁盘 Info.plist（安装副本的真实状态）——直接读原始字节并解析。
      var diskAltKeys: [String] = []
      var altIconNames: [String] = []
      var diskBytes = -1
      if let p = bundle.path(forResource: "Info", ofType: "plist"),
         let data = FileManager.default.contents(atPath: p) {
        diskBytes = data.count
        // PropertyListSerialization 可解析文本与二进制（bplist00）两种格式。
        // Apple 标准结构：CFBundleAlternateIcons 嵌套在 CFBundleIcons 之内。
        if let obj = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
           let d = obj as? [AnyHashable: Any],
           let icons = d["CFBundleIcons"] as? [AnyHashable: Any],
           let alt = icons["CFBundleAlternateIcons"] as? [AnyHashable: Any] {
          diskAltKeys = alt.keys.map { "\($0)" }.sorted()
          // 每个条目的 CFBundleIconName 必须等于键名（appiconset 名），否则真机解析失败。
          var pairs: [String] = []
          for (key, entry) in alt {
            if let e = entry as? [AnyHashable: Any], let n = iconName(e) {
              pairs.append("\(key)=\(n)")
            } else {
              pairs.append("\(key)=<none>")
            }
          }
          altIconNames = pairs.sorted()
        }
      }
      // 证据 B：infoDictionary（Foundation 运行时读取）——保留为诊断字段。
      let dict = bundle.infoDictionary ?? [:]
      let iconsNS = (dict["CFBundleIcons"] as? [AnyHashable: Any]) ?? [:]
      let altNS = (iconsNS["CFBundleAlternateIcons"] as? [AnyHashable: Any]) ?? [:]
      result([
        "canSet": names.allSatisfy { diskAltKeys.contains($0) },
        "altIconNames": altIconNames,
        "diskAltKeys": diskAltKeys,
        "diskBytes": diskBytes,
        "infoDictKeyCount": dict.count,
        "hasBundleId": dict["CFBundleIdentifier"] != nil,
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

  /// 从 CFBundleAlternateIcons 条目提取 CFBundleIconName（String 或 [String]）。
  private func iconName(_ entry: [AnyHashable: Any]) -> String? {
    if let s = entry["CFBundleIconName"] as? String { return s }
    if let a = entry["CFBundleIconName"] as? [Any] {
      return a.map { "\($0)" }.joined(separator: ",")
    }
    return nil
  }

  private func reply(_ result: @escaping FlutterResult, _ error: Error?) {
    if let error = error {
      result(FlutterError(code: "LAUNCHER_ICON_ERROR", message: error.localizedDescription, details: nil))
    } else {
      result(nil)
    }
  }
}
