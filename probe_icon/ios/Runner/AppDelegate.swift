import Flutter
import UIKit

/// 最小探针 App：判定「旁载语境下任意 app 能否切换桌面图标」。
///
/// 与主 app（flutter_legado）刻意保持的结构差异（逐一隔离变量）：
/// - iPhone-only（TARGETED_DEVICE_FAMILY=1，无 CFBundleIcons~ipad / universal）；
/// - 仅 1 个备选图标 probe（非 6 个）；
/// - 纯 legacy 声明：CFBundleIconFiles + bundle 根散文件，**无 CFBundleIconName**
///   （对齐 tastelessjolt/flutter_dynamic_icon 等社区实证结构）。
///
/// 探针结果判读：
/// - set 成功（桌面图标变为 probe）→ 主 app 的失败源于残留结构差异（universal/iPad、多备选），可继续二分；
/// - set 仍 -54 → 旁载签名/LaunchServices 注册语境问题，与本 app 具体结构无关。
@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    // 通道注入方式与主 app 完全一致（proven on this CI/Flutter）。
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "ProbeBridge") {
      ProbeBridge.shared.attach(messenger: registrar.messenger())
    }
  }
}
