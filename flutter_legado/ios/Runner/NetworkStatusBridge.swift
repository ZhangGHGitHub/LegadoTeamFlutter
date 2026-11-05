import Flutter
import Network
import UIKit

/// [设置批6b-1] 网络状态桥——对齐 Android `NetworkStatusBridge.kt` 的通道协议：
/// Flutter→Native: `isWifi` → Bool（当前是否 Wi-Fi）。
///
/// iOS 经 NWPathMonitor 监听路径变化：
/// - `.wifi` / `.wiredEthernet` → Wi-Fi；
/// - `.cellular` → 非 Wi-Fi；
/// - 其它（VPN 等 `.other`）→ 以 `path.isExpensive` 判定（按流量计费视为
///   蜂窝，否则按 Wi-Fi；[审查 P2-2] 覆盖「VPN over Wi-Fi / 局域网 Wi-Fi」）。
/// 首帧路径未就绪 / 监听异常一律 fail-open 返回 true（宁可多加载，不误判
/// 蜂窝导致封面整屏空白）。桌面端不注册本通道，由 Dart 侧直接返回 true。
@objc class NetworkStatusBridge: NSObject {
  static let shared = NetworkStatusBridge()

  private var channel: FlutterMethodChannel?
  private let monitor = NWPathMonitor()
  private let monitorQueue = DispatchQueue(label: "io.legado.flutter.network_status")
  /// 监听未就绪前默认 true（fail-open）
  private var isWifi = true

  private override init() {
    super.init()
  }

  /// 在 AppDelegate 的引擎初始化回调中调用（进程内仅一次）
  func attach(messenger: FlutterBinaryMessenger) {
    guard channel == nil else { return }
    monitor.pathUpdateHandler = { [weak self] path in
      guard let self = self else { return }
      guard path.status == .satisfied else {
        // 无可用路径：保持 fail-open，避免离线时把封面误判为蜂窝
        self.isWifi = true
        return
      }
      if path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet) {
        self.isWifi = true
      } else if path.usesInterfaceType(.cellular) || path.isExpensive {
        // 蜂窝或按流量计费的 VPN/热点 → 非 Wi-Fi
        self.isWifi = false
      } else {
        // 其它非昂贵路径（如 VPN over Wi-Fi、局域网）按 Wi-Fi 处理
        self.isWifi = true
      }
    }
    monitor.start(queue: monitorQueue)

    let ch = FlutterMethodChannel(
      name: "legado/network_status",
      binaryMessenger: messenger
    )
    ch.setMethodCallHandler { [weak self] call, result in
      guard let self = self else {
        result(true)
        return
      }
      switch call.method {
      case "isWifi":
        // 主线程应答，避免监控队列与 Flutter 平台线程交叉
        DispatchQueue.main.async {
          result(self.isWifi)
        }
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    channel = ch
  }
}
