import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// Android「Web 服务唤醒锁」接线（批9b-6）
///
/// ## 语义基准（原版 / 参考版一致）
/// `legado-upstream/.../service/WebService.kt`
/// - `:76-78`：偏好 `webServiceWakeLock`（默认 false）→ `PowerManager`
///   `PARTIAL_WAKE_LOCK`，tag `legado:WebService`，`setReferenceCounted(false)`；
/// - `:104` / `:139`：服务创建 / 唤醒请求时 `acquire()`（不带超时）；
/// - `:159`：服务 `onDestroy` 时 `release()`。
///
/// 参考版 `legado-with-MD3/.../service/WebService.kt:68-74,91-92,132-135,144-145`
/// 为同一实现（仅多一层设置持久化网关，电源语义无差异）。
///
/// ## 本仓库接线
/// - Web 服务启动成功（`settings_screen.dart` 的 `startServer` 之后）→
///   [onServiceStarted]（`keepAwake` 取偏好 `webServiceWakeLock`）；
/// - 服务停止成功 → [onServiceStopped]（无条件释放，即使偏好已改）；
/// - 运行中切换偏好（其他设置页 `onChanged`）→ [onPreferenceChanged] 即时生效；
/// - Activity/引擎销毁 → 原生侧 `MainActivity.onDestroy` 释放；
///   Dart 侧另经 [attachLifecycleFallback] 在 detached 时补一次
///   [releaseOnProcessDetach]（引擎卸载后进程仍存活的兜底，幂等）。
///
/// ## 平台边界（如实登记，不做假 no-op）
/// 仅 Android 适用；iOS 由 `WebKeepAliveService`（静音音轨保活）负责，
/// 桌面/其他平台无对应机制。非 Android 时本类不触碰平台通道，[isSupported]
/// 供调用方判断（设置页「仅 Android 生效」副题已复用既有 `_androidOnly`）。
///
/// ## 生命周期差异（与 Android 原版）
/// 原版 WakeLock 依附前台服务，服务在 App 退后台/进程存活期间持续持有；
/// 本仓库 Web 服务是进程内 Rust server，无对应前台服务，App 进程被系统
/// 回收时唤醒锁随进程消失（不存在可复刻的后台服务语义，故不硬造），
/// 因此本类只在「进程存活且有 Activity / 引擎」期间生效。
///
/// — 全栈工程师 ｜ 2026-11-01
class WebServiceWakeLockService {
  WebServiceWakeLockService._();

  /// 进程内单例：锁生命周期 = Web 服务生命周期，跨页面复用
  static final WebServiceWakeLockService instance =
      WebServiceWakeLockService._();

  /// 与 Kotlin `WebServiceWakeLockBridge.CHANNEL` 同名
  ///
  /// 不复用 `legado/media_session` 的 `setWakeLock`：那是听书
  /// `audioPlayWakeLock` 语义（播放态驱动，tag 不同），共用会互相踩停。
  @visibleForTesting
  static const MethodChannel channel = MethodChannel(
    'legado/web_service_wakelock',
  );

  /// 平台门控（测试缝隙，对齐 `WebKeepAliveService.platformIsIOS` 既有做法）
  @visibleForTesting
  static bool Function() platformIsAndroid = () => Platform.isAndroid;

  /// Web 服务（进程内 Rust server）是否在运行
  bool _serviceRunning = false;

  /// 偏好 `webServiceWakeLock` 的运行期镜像（启动时由调用方传入）
  bool _preferenceEnabled = false;

  /// 平台侧当前是否持有唤醒锁
  bool _held = false;

  /// detached 兜底监听（懒注册，仅 Android 且只注册一次）
  AppLifecycleListener? _lifecycleFallback;

  /// 平台是否适用（仅 Android）
  bool get isSupported => platformIsAndroid();

  /// 平台侧当前是否持有唤醒锁（供诊断/测试）
  bool get isHeld => _held;

  /// Web 服务意图是否在运行
  bool get isServiceRunning => _serviceRunning;

  /// Web 服务启动成功后调用（幂等；非 Android 不触通道）
  ///
  /// [keepAwake] 为启动时刻的偏好值（`PrefKeys.webServiceWakeLock`）。
  /// 偏好为 false / 服务未启动时保持不持有；重复调用不重复 acquire。
  Future<void> onServiceStarted({required bool keepAwake}) async {
    _serviceRunning = true;
    _preferenceEnabled = keepAwake;
    await _sync();
  }

  /// Web 服务停止成功后调用（幂等；无条件释放，偏好是否仍开都不再持锁）
  Future<void> onServiceStopped() async {
    _serviceRunning = false;
    await _sync();
  }

  /// 偏好运行中切换后调用（其他设置页 onChanged）
  ///
  /// 服务未运行：只更新镜像值，不触平台（下次启动时以调用方传入值为准）；
  /// 服务运行中：true → acquire、false → release，即时生效。
  Future<void> onPreferenceChanged(bool enabled) async {
    _preferenceEnabled = enabled;
    if (!_serviceRunning) return;
    await _sync();
  }

  /// 注册 detached 兜底（App 入口调用一次；非 Android 直接跳过）
  ///
  /// 进程被杀时唤醒锁由系统随进程回收，无需处理；本兜底只覆盖
  /// 「引擎卸载但进程仍存活」时锁未释放的窗口。
  void attachLifecycleFallback() {
    if (_lifecycleFallback != null || !isSupported) return;
    try {
      _lifecycleFallback = AppLifecycleListener(
        onDetach: () {
          unawaited(releaseOnProcessDetach());
        },
      );
    } catch (error) {
      // binding 未初始化等异常（如极早期调用）：放弃兜底，不影响主流程
      debugPrint('[WebWakeLock] detached 兜底注册失败（忽略）: $error');
    }
  }

  /// 引擎/应用 dispose 兜底释放（幂等；未持有时不触通道）
  Future<void> releaseOnProcessDetach() async {
    _serviceRunning = false;
    if (!isSupported || !_held) return;
    await _send(false);
    _held = false;
  }

  /// 期望态与平台态对齐：仅在「该持有 ≠ 已持有」时下发一次通道调用
  Future<void> _sync() async {
    if (!isSupported) return;
    final shouldHold = _serviceRunning && _preferenceEnabled;
    if (shouldHold == _held) return;
    final applied = await _send(shouldHold);
    // 平台调用失败保持原状态（下次状态变化/启动时重试），不抛异常上抛
    if (applied) _held = shouldHold;
  }

  /// 唯一平台出口：成功返回 true；缺失通道/平台异常静默降级
  Future<bool> _send(bool enabled) async {
    try {
      await channel.invokeMethod<void>('setEnabled', {'enabled': enabled});
      return true;
    } on MissingPluginException {
      // 非 Android 构建 / 测试环境未注册：静默（可预期）
      return false;
    } on PlatformException catch (error) {
      debugPrint('[WebWakeLock] 平台通道异常（忽略）: $error');
      return false;
    } catch (error) {
      debugPrint('[WebWakeLock] 唤醒锁调用异常（忽略）: $error');
      return false;
    }
  }

  /// 测试缝隙：复位内存态（不触碰平台通道，监听保留）
  @visibleForTesting
  void debugReset() {
    _serviceRunning = false;
    _preferenceEnabled = false;
    _held = false;
  }
}
