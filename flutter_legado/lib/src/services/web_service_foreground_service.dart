import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Android「Web 服务前台服务」接线（批9b-6c）
///
/// ## 为什么需要
/// 批9b-6 设备验收（`docs/DEVICE_ACCEPTANCE_20261101_BATCH9B6.md`）7 PASS /
/// 1 FAIL：双锁（CPU 唤醒锁 + Wi-Fi 锁）已持有，但息屏后宿主 curl 全部超时，
/// `netpolicy` 显示 UID 后台 `effective=APP_BACKGROUND`。唤醒锁只影响 CPU/
/// 屏幕休眠，**不能改变网络策略**；Android 原版靠 `WebService` 前台服务把
/// 进程提升为可见前台来维持局域网可达。
///
/// ## 语义基准（原版 `legado-upstream/app/src/main/java/io/legado/app/service/WebService.kt`）
/// - `:50-57` `start` / `startForeground`（后者经 `startForegroundServiceCompat`）；
/// - `:101-132` `onCreate` 建通知；`:135-152` `onStartCommand` 处理
///   stop / serve / 默认；`:154-169` `onDestroy` 清理；`:254-257`
///   `startForeground(id, notification)`；`:259-295` 常驻通知
///   （`setOngoing(true)`、公开可见）；
/// - `BaseService.kt:67-71` `onTaskRemoved` → `stopSelf()`；
/// - manifest `:554-556` `foregroundServiceType="dataSync"`。
/// 参考版 `legado-with-MD3/.../service/WebService.kt:52-55,89-94` 与
/// `legado-with-MD3/app/src/main/AndroidManifest.xml:408-410` 同构。
///
/// 本仓库差异（详见 Kotlin `WebServerForegroundService` 注释）：Rust server
/// 在 Flutter 进程内、由 Dart 启停，前台服务只负责提升进程优先级；因此原生
/// 返回 `START_NOT_STICKY`、通知点击只打开 App（不提供原版复制地址/停止按钮），
/// 类型用 `specialUse` 而非原版 `dataSync`（规避 Android 15 dataSync 6 小时
/// 累计时限）。
///
/// ## 与唤醒锁解耦
/// 前台服务**随 Web 服务启停**（`startServer` 成功 → start、`stopServer`
/// 成功 → stop、启动回滚 → stop），与偏好 `webServiceWakeLock` 无关；唤醒锁
/// 仍由 [WebServiceWakeLockService] 按原开关独立控制。
///
/// ## 失败语义
/// 启动/停止失败一律静默（仅 [debugPrint]）：Android 12+ 后台启动限制、
/// 通知权限缺失（原生降级记录）、通道未注册（非 Android / 测试环境）都不
/// 不得阻断 Web 服务开关。
///
/// ## 平台边界
/// 仅 Android；iOS 由 `WebKeepAliveService`（静音音轨）负责，桌面无对应机制。
/// 非 Android 时本类不触平台通道。
///
/// — 全栈工程师 ｜ 2026-11-01
class WebServiceForegroundService {
  WebServiceForegroundService._();

  /// 进程内单例：生命周期 = Web 服务生命周期，跨页面复用
  static final WebServiceForegroundService instance =
      WebServiceForegroundService._();

  /// 与 Kotlin `WebServiceForegroundBridge.CHANNEL` 同名
  @visibleForTesting
  static const MethodChannel channel = MethodChannel(
    'legado/web_service_foreground',
  );

  /// 平台门控（测试缝隙，对齐 `WebServiceWakeLockService.platformIsAndroid`）
  @visibleForTesting
  static bool Function() platformIsAndroid = () => Platform.isAndroid;

  /// 原生服务运行态镜像：null=未知（新引擎/上次下发失败），true/false=已确认
  ///
  /// 新引擎 Dart 状态归零后先经 [isRunning] 查询对账，避免重复拉起。
  bool? _running;

  /// 平台是否适用（仅 Android）
  bool get isSupported => platformIsAndroid();

  /// 最后一次确认的服务运行态（供诊断/测试）
  bool get isRunningMirror => _running == true;

  /// 启动前台服务（幂等；非 Android no-op）
  ///
  /// 返回 true 表示「已确认/已下发启动」；失败返回 false 且不抛异常。
  /// 已确认运行时不重复触通道（原生重复 start 只会刷新通知）。
  Future<bool> start() async {
    if (!isSupported) return false;
    if (_running == true) return true;
    final ok = await _invoke('start');
    if (ok) {
      _running = true;
    }
    return ok;
  }

  /// 停止前台服务（幂等；非 Android no-op）
  ///
  /// 停机是明确的用户意图：即使镜像未知（引擎重建）也下发一次原生 stop，
  /// 清理可能遗留的前台服务。
  Future<bool> stop() async {
    if (!isSupported) return false;
    if (_running == false) return true;
    final ok = await _invoke('stop');
    if (ok) {
      _running = false;
    }
    return ok;
  }

  /// 设置页初始化对账：服务已在运行则确保前台服务也运行（幂等）
  ///
  /// 先查询原生 `isRunning` 再决定是否下发 start：Activity/引擎重建后 Dart
  /// 镜像归零，不能凭镜像直接拉起（会重复 startForeground，虽幂等但多余）。
  Future<void> ensureStarted() async {
    if (!isSupported) return;
    if (_running == true) return;
    final running = await isRunning();
    if (!running) {
      await start();
    }
  }

  /// 查询原生服务运行态（失败按 false 处理，不回写镜像）
  Future<bool> isRunning() async {
    if (!isSupported) return false;
    try {
      final running = await channel.invokeMethod<bool>('isRunning') ?? false;
      _running = running;
      return running;
    } on MissingPluginException {
      // 非 Android 构建 / 测试环境未注册：可预期
      debugPrint('[WebServiceFgs] 前台服务通道未注册（忽略）');
      _running = null;
      return false;
    } on PlatformException catch (error) {
      debugPrint('[WebServiceFgs] 查询前台服务状态失败（忽略）: $error');
      _running = null;
      return false;
    } catch (error) {
      debugPrint('[WebServiceFgs] 查询前台服务状态异常（忽略）: $error');
      _running = null;
      return false;
    }
  }

  /// 唯一原生出口：成功（含原生返回空值）返回 true；任何异常静默返回 false
  Future<bool> _invoke(String method) async {
    try {
      await channel.invokeMethod<bool>(method);
      return true;
    } on MissingPluginException {
      debugPrint('[WebServiceFgs] 前台服务通道未注册（忽略）: $method');
      return false;
    } on PlatformException catch (error) {
      // Android 12+ 后台启动限制 / startForeground 失败：降级为仅前台可用
      debugPrint('[WebServiceFgs] 平台通道异常（忽略）: $method $error');
      return false;
    } catch (error) {
      debugPrint('[WebServiceFgs] 前台服务调用异常（忽略）: $method $error');
      return false;
    }
  }

  /// 测试缝隙：复位内存态（模拟新引擎；不触碰平台通道）
  @visibleForTesting
  void debugReset() {
    _running = null;
  }
}
