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
/// 本仓库差异（详见 Kotlin `WebServerForegroundService` 注释）：
/// - Rust server 在 Flutter 进程内、由 Dart 启停，前台服务只负责进程提权；
/// - `START_NOT_STICKY`、通知点击只打开 App（不提供原版复制地址/停止按钮）；
/// - **最近任务划掉不停止 FGS/server**（审查回修 P2）：server 不随 Activity
///   销毁停止，撤 FGS 会留下「server 在跑但进程退后台」的孤儿态；与原版
///   `BaseService.onTaskRemoved → stopSelf` 的差异已在 Kotlin 侧登记；
/// - 类型用 `specialUse` 而非原版 `dataSync`（规避 Android 15 dataSync 6 小时
///   累计时限；上架 Google Play 的 specialUse 申报义务登记在 Kotlin 注释）。
///
/// ## 与唤醒锁解耦
/// 前台服务**随 Web 服务启停**（`startServer` 成功 → start、`stopServer`
/// 成功 → stop、启动回滚 → stop），与偏好 `webServiceWakeLock` 无关；唤醒锁
/// 仍由 [WebServiceWakeLockService] 按原开关独立控制。
///
/// ## 通知权限（Android 13+）
/// 用户开启 Web 服务时经 [ensureNotificationPermission] 请求
/// `POST_NOTIFICATIONS`：已授予不弹框；拒绝时 FGS 照常运行（网络优先级不受
/// 影响），仅通知不可见，由设置页提示。非 Android 无该权限概念，恒视为已授予。
///
/// ## 失败语义
/// 启动/停止/权限失败一律静默（仅 [debugPrint]）：Android 12+ 后台启动限制、
/// 通道未注册（非 Android / 测试环境）都不得阻断 Web 服务开关。
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

  /// 启动后确认延时（审查回修 P3；测试置零避免挂起计时器）
  ///
  /// `startForegroundService` 只代表系统受理，服务建实例/前台化是异步的：
  /// 短延时后查询 `isRunning` 才能确认真正生效（失败时原生 `stopSelf`）。
  @visibleForTesting
  static Duration startConfirmDelay = const Duration(milliseconds: 200);

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
  /// 返回 true 表示「下发成功且短延时后确认原生在运行」；失败返回 false 且
  /// 不抛异常。已确认运行时不重复触通道（原生重复 start 只会刷新通知）。
  Future<bool> start() async {
    if (!isSupported) return false;
    if (_running == true) return true;
    final accepted = await _invoke('start');
    if (!accepted) {
      // 下发失败：原生态未知（可能从未启动，也可能已受理但回传异常）
      _running = null;
      return false;
    }
    _running = true;
    if (startConfirmDelay > Duration.zero) {
      await Future<void>.delayed(startConfirmDelay);
    }
    // 短延时确认：服务若未能前台化会在原生侧 stopSelf，此处得到 false
    final confirmed = await isRunning();
    if (!confirmed) {
      debugPrint('[WebServiceFgs] 启动后确认失败：原生前台服务未运行（降级）');
    }
    return confirmed;
  }

  /// 停止前台服务（非 Android no-op）
  ///
  /// **始终下发一次原生 stop**（审查回修）：`stopService` 原生幂等，不能因
  /// Dart 镜像为 false 就跳过——`start()` 确认失败时原生 `onCreate` 仍可能
  /// 晚到，跳过会留下无主的前台通知。失败时镜像置未知（保持可重试）。
  Future<bool> stop() async {
    if (!isSupported) return false;
    final ok = await _invoke('stop');
    if (ok) {
      _running = false;
    } else {
      // 未确认停止：原生态未知，下次对账先查询再决定
      _running = null;
    }
    return ok;
  }

  /// 设置页初始化/恢复前台对账：服务已在运行则确保前台服务也运行（幂等）
  ///
  /// 先查询原生 `isRunning` 再决定是否下发 start：Activity/引擎重建后 Dart
  /// 镜像归零，不能凭镜像直接拉起（会重复 startForeground，虽幂等但多余）。
  /// [forceQuery] 用于 App 回到前台时强制查询——系统可能已停止 FGS，而
  /// Dart 镜像仍是 true（审查回修 P3）。
  Future<void> ensureStarted({bool forceQuery = false}) async {
    if (!isSupported) return;
    if (!forceQuery && _running == true) return;
    final running = await isRunning();
    if (!running) {
      await start();
    }
  }

  /// 查询原生服务运行态（失败按 false 处理，镜像置未知）
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

  /// 当前是否已授予通知权限（Android 13 以下 / 非 Android 恒 true）
  ///
  /// 失败按 false 处理：宁可提示「通知不可见」，不误报已授予。
  Future<bool> hasNotificationPermission() async {
    if (!isSupported) return true;
    try {
      return await channel.invokeMethod<bool>('hasNotificationPermission') ??
          false;
    } on MissingPluginException {
      debugPrint('[WebServiceFgs] 通知权限查询通道未注册（忽略）');
      return false;
    } on PlatformException catch (error) {
      debugPrint('[WebServiceFgs] 查询通知权限失败（忽略）: $error');
      return false;
    } catch (error) {
      debugPrint('[WebServiceFgs] 查询通知权限异常（忽略）: $error');
      return false;
    }
  }

  /// 请求通知权限（Android 13+ 弹系统对话框；其他平台恒 true）
  ///
  /// 拒绝不阻断 FGS：返回 false 供调用方提示「前台通知不可见」。
  Future<bool> requestNotificationPermission() async {
    if (!isSupported) return true;
    try {
      return await channel.invokeMethod<bool>(
            'requestNotificationPermission',
          ) ??
          false;
    } on MissingPluginException {
      debugPrint('[WebServiceFgs] 通知权限请求通道未注册（忽略）');
      return false;
    } on PlatformException catch (error) {
      debugPrint('[WebServiceFgs] 请求通知权限失败（忽略）: $error');
      return false;
    } catch (error) {
      debugPrint('[WebServiceFgs] 请求通知权限异常（忽略）: $error');
      return false;
    }
  }

  /// 确保通知权限：已授予不弹框；未授予才请求（开启 Web 服务时调用）
  Future<bool> ensureNotificationPermission() async {
    if (!isSupported) return true;
    if (await hasNotificationPermission()) return true;
    return requestNotificationPermission();
  }

  /// 唯一原生出口：仅原生明确回 true 视为成功（审查回修 P3）
  ///
  /// 原生返回 null/false（实现异常）同样按失败处理，不假定「调用没抛错即成功」。
  Future<bool> _invoke(String method) async {
    try {
      final accepted = await channel.invokeMethod<bool>(method);
      if (accepted != true) {
        debugPrint('[WebServiceFgs] 原生未确认 $method（按失败处理）');
        return false;
      }
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
