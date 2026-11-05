// 网络状态服务（设置批6b-1）
//
// 「仅 WiFi 加载封面」需要区分 Wi-Fi 与蜂窝网络。项目不引入
// connectivity_plus（用户裁决），统一走自建平台通道
// `legado/network_status` / `isWifi`：
// - Android：ConnectivityManager + NetworkCapabilities（ACCESS_NETWORK_STATE，
//   manifest 已声明）；
// - iOS：NWPathMonitor（AppDelegate 注册 NetworkStatusBridge）；
// - Windows/Linux/macOS/Web：桌面桩直接返回 true（不阻塞封面加载）。
//
// 原生侧异常一律 fail-open 返回 true（宁可多加载，不误把封面判成蜂窝而
// 整屏空白）。结果做短时缓存（[cacheTtl]），避免列表里每张封面都打一次
// 通道；「仅 WiFi」阻塞期间由 BookCover 定时 forceRefresh 重试，恢复 WiFi
// 后自动加载。
//
// 测试可用 [NetworkStatusService.instance] 替换为假实现（测试后还原）。
//
// 编写：全栈工程师（设置批6b-1） ｜ 2026-11-06
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 网络状态服务（可替换实例，便于测试注入）
class NetworkStatusService {
  static const MethodChannel _channel = MethodChannel('legado/network_status');

  /// 全局实例（测试可替换为假实现）
  static NetworkStatusService instance = NetworkStatusService();

  /// 结果缓存时长：列表首屏几十张封面共用一次通道调用
  static const Duration cacheTtl = Duration(seconds: 3);

  bool? _cached;
  DateTime? _cachedAt;
  Future<bool>? _pending;

  /// 当前是否 Wi-Fi 网络
  ///
  /// [forceRefresh] 为 true 时忽略缓存（阻塞重试场景）；并发调用合并为
  /// 同一次通道请求。
  Future<bool> isWifi({bool forceRefresh = false}) {
    if (!_usesChannel) return Future<bool>.value(true);
    final now = DateTime.now();
    if (!forceRefresh &&
        _cached != null &&
        _cachedAt != null &&
        now.difference(_cachedAt!) < cacheTtl) {
      return Future<bool>.value(_cached);
    }
    final pending = _pending;
    if (pending != null) return pending;
    final future = _probe()
        .then((value) {
          _cached = value;
          _cachedAt = DateTime.now();
          return value;
        })
        .whenComplete(() {
          _pending = null;
        });
    _pending = future;
    return future;
  }

  /// 仅 Android/iOS 有原生实现；其余平台返回 true（桌面桩）
  bool get _usesChannel {
    if (kIsWeb) return false;
    return defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS;
  }

  Future<bool> _probe() async {
    try {
      final value = await _channel.invokeMethod<bool>('isWifi');
      return value ?? true;
    } catch (e) {
      // 原生异常/通道未注册：fail-open，避免误判蜂窝导致封面空白
      debugPrint('[NetworkStatusService] isWifi 调用失败，按 Wi-Fi 处理: $e');
      return true;
    }
  }

  /// 清空缓存（测试/调试用）
  @visibleForTesting
  void reset() {
    _cached = null;
    _cachedAt = null;
    _pending = null;
  }
}
