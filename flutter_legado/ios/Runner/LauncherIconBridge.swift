import Flutter
import UIKit

/// 运行时更换桌面图标（对齐原版 LauncherIconHelp.changeIcon）。
///
/// iOS 经 UIApplication.setAlternateIconName 在 Info.plist
/// CFBundleIcons/CFBundleAlternateIcons 声明的变体间切换；传 nil
/// 恢复默认图标。系统限制：每次启动仅可切换一次，且下次启动生效
/// （由 Dart 侧提示）。
///
/// 第五轮（-54 复发）增强：
/// - status 增加真机自检：systemVersion / supportsAlt /
///   carHasAllLaunchers（Assets.car 字节级扫描 launcher1~6 名）——
///   区分「旁载签名后落盘 bundle 丢失声明/资产」（唯一未验证环节）
///   与「iOS 26+ 系统回归」（capacitor-community/app-icon#73：
///   iOS 26.1+ 公开 API 回归，LSIconAlertManager Code=35）；
/// - 公开路径失败后尝试私有 API _setAlternateIconName 一次
///   （capacitor 量产模式，绕过 iOS 26 alert 路径）；
/// - 错误回传 domain/code（FlutterError.details），Dart 侧附带
///   自检结果一次性回报。
///
/// 第六轮（-54 仍复发，iOS 17.5 真机、声明✓/car 6/6）增强：
/// - status 增加 looseIcons 字段——逐 CFBundleIconFiles base name
///   校验 bundle 根散文件可解析性（"" / @2x / @3x 任一存在）。
///   universal app 的 76x76 变体只有 iPad idiom 散文件，iPhone 下
///   legacy 路径缺口是 -54 的最后具体嫌疑（CI 侧已补非 ipad 散文件）。
///
/// 第七轮（真机实证：声明✓/car 6/6/散文件12/12 仍 -54 → H2 证伪）增强：
/// - status 增加 carReadable——用常规 imageset（probe_image）做
///   UIImage(named:) 读取探针。car 由 Xcode 16.4/SDK 18 actool 编译，
///   本地取证发现其内无 PNG 签名（图像记录为非 PNG 编码）；若本系统
///   （iOS 17.5）读不了该 car，则 CFBundleIconName→car 的变体校验必然
///   fNotFoundErr（-54），与散文件是否齐全无关（H3 判定探针）。
/// - reply 错误回传增加 userInfo 全量 + underlyingError 转储。
///
/// 第八轮（GitHub 调研：社区实证结构为纯 legacy——无 CFBundleIconName）增强：
/// - CI 打包前从所有 CFBundleAlternateIcons 条目剥离 CFBundleIconName，强制走
///   纯 legacy 解析路径（CFBundleIconFiles + bundle 根散文件），与
///   tastelessjolt/flutter_dynamic_icon 等社区实证应用结构对齐；
/// - status 增加 altModernDecl——仍携带 CFBundleIconName 的备选条目数
///   （剥离后应为 0；>0 说明所装构建未经剥离步，用于归属判定）。
///   set 路径功能不变。
@objc class LauncherIconBridge: NSObject {
  static let shared = LauncherIconBridge()

  private var channel: FlutterMethodChannel?

  /// Info.plist CFBundleAlternateIcons 声明的变体名（= Assets.car appiconset 名）
  static let launcherNames = ["launcher1", "launcher2", "launcher3", "launcher4", "launcher5", "launcher6"]

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
      // 异步应答（UIKit 读取须主线程）：集成测试回归门禁。
      // canSet = 已安装 bundle 磁盘 Info.plist 的 CFBundleAlternateIcons
      // 声明 launcher1~6（setAlternateIconName 的直接前提；UIKit 无公开
      // 同步查询 API，set 的 completion 在模拟器上不回调，故门禁不用 set）。
      // carHasAllLaunchers = Assets.car 字节级扫描变体 appiconset 名——
      // 验证「变体资产真实存在于已安装 bundle」（第五轮：旁载签名链路
      // 是唯一未取证的环节，CI 产物完整性已在第四轮证实）。
      DispatchQueue.main.async {
        let names = Self.launcherNames
        let bundle = Bundle.main
        var diskAltKeys: [String] = []
        var altIconNames: [String] = []
        var diskBytes = -1
        // 第八轮自检：备选条目中仍携带 CFBundleIconName 的计数。
        // CI 剥离后应为 0；>0 说明所装构建未经剥离步（归属判定）。
        var altModern = -1
        // 第六轮自检：legacy 路径（CFBundleIconFiles）散文件可解析性。
        // Xcode 只为 universal app 的 76x76 变体编 iPad idiom 散文件，iPhone
        // idiom 下 base name 可能解析不到任何文件 → LaunchServices 校验/回退
        // legacy 路径时 setAlternateIconName 报 -54（fNotFoundErr）。
        var looseResolved = 0
        var looseTotal = 0
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
            altModern = alt.values.filter { ($0 as? [AnyHashable: Any])?["CFBundleIconName"] != nil }.count
            // 每个条目的 CFBundleIconName 必须等于键名（appiconset 名），否则真机解析失败。
            var pairs: [String] = []
            let fm = FileManager.default
            let root = bundle.bundlePath as NSString
            for (key, entry) in alt {
              if let e = entry as? [AnyHashable: Any], let n = self.iconName(e) {
                pairs.append("\(key)=\(n)")
              } else {
                pairs.append("\(key)=<none>")
              }
              // 逐 base name 校验 bundle 根散文件（"" / @2x / @3x 任一存在即算可解析）。
              if let e = entry as? [AnyHashable: Any], let files = e["CFBundleIconFiles"] as? [Any] {
                for f in files {
                  looseTotal += 1
                  let base = "\(f)"
                  for suffix in ["", "@2x", "@3x"] where
                    fm.fileExists(atPath: root.appendingPathComponent("\(base)\(suffix).png")) {
                    looseResolved += 1
                    break
                  }
                }
              }
            }
            altIconNames = pairs.sorted()
          }
        }
        // 第五轮真机自检：系统版本 / 平台能力 / car 内变体资产。
        let sysVer = UIDevice.current.systemVersion
        let supportsAlt = UIApplication.shared.supportsAlternateIcons
        var carFound: [String] = []
        if let carPath = bundle.path(forResource: "Assets", ofType: "car"),
           let carData = FileManager.default.contents(atPath: carPath) {
          for name in names where Self.containsASCII(carData, name) {
            carFound.append(name)
          }
        }
        // 第七轮 H3 判定探针：本系统能否真正从 Assets.car 读图像。
        // carHasAllLaunchers 只证明 appiconset 名在字节流里出现；但
        // Xcode 16.4/SDK 18 actool 编出的 car 内无 PNG 签名（非 PNG 编码），
        // iOS 17.5 的 LaunchServices/UIKit 可能解不开图像记录——那 CFBundleIconName
        // →car 的变体校验必然 fNotFoundErr(-54)，与散文件是否齐全无关。
        // UIImage(named:) 走同一 car 读取路径，nil 即 H3 成立。
        let carReadable = UIImage(named: "probe_image") != nil
        // infoDictionary（Foundation 运行时读取）——保留为诊断字段。
        let dict = bundle.infoDictionary ?? [:]
        let iconsNS = (dict["CFBundleIcons"] as? [AnyHashable: Any]) ?? [:]
        let altNS = (iconsNS["CFBundleAlternateIcons"] as? [AnyHashable: Any]) ?? [:]
        result([
          "canSet": names.allSatisfy { diskAltKeys.contains($0) },
          "altIconNames": altIconNames,
          "diskAltKeys": diskAltKeys,
          "diskBytes": diskBytes,
          "systemVersion": sysVer,
          "supportsAlt": supportsAlt,
          "carHasAllLaunchers": carFound,
          "carReadable": carReadable,
          "altModernDecl": altModern,
          "looseIcons": "\(looseResolved)/\(looseTotal)",
          "infoDictKeyCount": dict.count,
          "hasBundleId": dict["CFBundleIdentifier"] != nil,
          "altKeys": altNS.keys.map { "\($0)" }.sorted(),
          "bundlePath": bundle.bundlePath,
        ])
      }
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
      // 平台能力预检（比 -54 更明确的失败原因）
      guard UIApplication.shared.supportsAlternateIcons else {
        self.reply(result, NSError(domain: "LauncherIconBridge", code: -1, userInfo: [NSLocalizedDescriptionKey: "系统不支持备选图标（supportsAlternateIcons=false）"]))
        return
      }
      let name: String? = icon == "iconMain" ? nil : ("launcher" + icon.replacingOccurrences(of: "icon", with: ""))
      UIApplication.shared.setAlternateIconName(name, completionHandler: { error in
        if let error = error {
          // 公开路径失败 → 尝试私有 API 旁路一次（iOS 26 alert 路径回归绕行）
          self.tryPrivateSet(name: name, result: result, publicError: error)
        } else {
          result(nil)
        }
      })
    }
  }

  /// 私有 API 旁路：_setAlternateIconName:completionHandler:
  /// （capacitor-community/app-icon 量产模式，iOS 26 alert 路径回归绕行）。
  /// selector 不存在（系统已移除）时按公开路径错误原样回报。
  /// 私有 completion 的 NSError 语义不明确（capacitor 生产实践为忽略），
  /// 故采用 fire-and-forget：触发后统一回报公开路径错误并注明旁路已尝试——
  /// 若重启后桌面图标已变更，即为旁路生效。
  private func tryPrivateSet(name: String?, result: @escaping FlutterResult, publicError: Error) {
    let sel = NSSelectorFromString("_setAlternateIconName:completionHandler:")
    guard UIApplication.shared.responds(to: sel) else {
      reply(result, publicError)
      return
    }
    typealias PrivateSetFn = @convention(c) (NSObject, Selector, NSString?, @escaping (NSError) -> Void) -> Void
    let imp = UIApplication.shared.method(for: sel)
    let fn = unsafeBitCast(imp, to: PrivateSetFn.self)
    fn(UIApplication.shared, sel, name as NSString?, { _ in })
    reply(result, publicError, note: "已尝试私有 API 旁路，重启后若桌面图标已变更即为旁路生效")
  }

  /// 从 CFBundleAlternateIcons 条目提取 CFBundleIconName（String 或 [String]）。
  private func iconName(_ entry: [AnyHashable: Any]) -> String? {
    if let s = entry["CFBundleIconName"] as? String { return s }
    if let a = entry["CFBundleIconName"] as? [Any] {
      return a.map { "\($0)" }.joined(separator: ",")
    }
    return nil
  }

  /// ASCII 子串字节级扫描（Assets.car 为二进制，NSString 式检索不可靠）。
  private static func containsASCII(_ data: Data, _ needle: String) -> Bool {
    guard let nd = needle.data(using: .utf8), !nd.isEmpty else { return false }
    let n = Array(nd)
    let h = Array(data)
    guard n.count <= h.count else { return false }
    for i in 0...(h.count - n.count) where h[i] == n[0] {
      var ok = true
      for j in 1..<n.count where h[i + j] != n[j] {
        ok = false
        break
      }
      if ok { return true }
    }
    return false
  }

  private func reply(_ result: @escaping FlutterResult, _ error: Error, note: String? = nil) {
    let nsError = error as NSError
    var details: [String: Any] = [
      "domain": nsError.domain,
      "code": nsError.code,
    ]
    // 第七轮取证：userInfo 全量 + underlyingError 转储。通用 OSStatus 错误
    // 通常无附加信息，但 UIKit 若挂了 NSRecoverySuggestion / 底层错误
    // （例如真正的查找失败来源），一次回报即可见。
    for (k, v) in nsError.userInfo {
      details["userInfo.\(k)"] = "\(v)"
    }
    if let u = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
      let un = u as NSError
      details["underlyingDomain"] = un.domain
      details["underlyingCode"] = un.code
    }
    if let note = note { details["note"] = note }
    result(FlutterError(code: "LAUNCHER_ICON_ERROR", message: error.localizedDescription, details: details))
  }
}
