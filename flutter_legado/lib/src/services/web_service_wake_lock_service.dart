import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// Android「Web 服务唤醒锁」接线（批9b-6）
///
/// ## 语义基准（原版 / 参考版一致）
/// `legado-upstream/.../service/WebService.kt`
/// - `:76-78` 偏好 `webServiceWakeLock`（默认 false）+ CPU 唤醒锁创建，
///   `:83-89` 同 tag `WifiLock` 创建
///   （`WIFI_MODE_FULL_HIGH_PERF`，`legado:WebService`，
///   `setReferenceCounted(false)`）；
/// - `:105-106` / `:140-141`：服务创建 / 唤醒请求时成对 `acquire()`（不带超时）；
/// - `:160-161`：服务 `onDestroy` 时成对 `release()`。
/// 参考版 `legado-with-MD3/.../service/WebService.kt:68-74,75-81,92-93,133-134,145-146`
/// 电源语义一致（仅多一层设置持久化网关）。
///
/// ## 生命周期（进程级，审查回修）
/// 原生锁由 Application Context 创建并挂在进程级单例上（Kotlin `object`）：
/// Activity 重建 / 引擎重建 / Launcher1-6 变体切换都不释放，只有
/// [onServiceStopped] / 偏好关（即 `setEnabled(false)`）才释放；进程被系统
/// 回收时锁随进程消失。因此本类**不**在 Flutter detached 时释放
/// （Flutter 无法可靠判断「进程退出」与「引擎重建」，宁可保留）。
///
/// 新引擎的 Dart 状态归零后，[_reconcileOnce] 先经原生 `isHeld` 查询对账
/// （设置页 `_initServiceStates` 无论配置真假都按实际运行态对账），
/// 避免误丢锁或误持有。
///
/// ## 本仓库接线
/// - Web 服务启动成功（`settings_screen.dart` 的 `startServer` 之后）→
///   [onServiceStarted]（`keepAwake` 取偏好 `webServiceWakeLock`）；
/// - 服务停止成功 → [onServiceStopped]（无条件释放，即使偏好仍开）；
/// - 运行中切换偏好（其他设置页 `onChanged`）→ [onPreferenceChanged] 即时生效；
/// - 设置页初始化按 `getServerStatus` 运行态对账（新引擎可恢复持有）。
///
/// ## 平台边界
/// 仅 Android 适用；iOS 由 `WebKeepAliveService`（静音音轨保活）负责，
/// 桌面/其他平台无对应机制。非 Android 时本类不触碰平台通道，[isSupported]
/// 供调用方判断（其他设置页在非 Android 下置灰该开关）。
///
/// ## 生命周期差异（与 Android 原版，如实登记）
/// 原版唤醒锁依附 `WebService` 前台服务，退后台期间持续持有；本仓库 Web
/// 服务是进程内 Rust server、无对应前台服务，进程被系统回收时锁随进程消失，
/// 后台存活不作保证（不硬造后台服务）。
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

  /// 平台侧当前是否持有唤醒锁（最后一次成功同步后的镜像）
  bool _held = false;

  /// 原生持有态是否已确认（新引擎 / 首次同步时为 false，先查询再下发）
  bool _nativeStateKnown = false;

  /// 串行化同步链：快速连续切换时后一次不会读取到旧 [_held]（审查回修）
  Future<void>? _syncChain;

  /// 平台是否适用（仅 Android）
  bool get isSupported => platformIsAndroid();

  /// 平台侧最后一次确认的持有状态（供诊断/测试）
  bool get isHeld => _held;

  /// Web 服务意图是否在运行
  bool get isServiceRunning => _serviceRunning;

  /// Web 服务启动成功后调用（幂等；非 Android 不触通道）
  ///
  /// [keepAwake] 为启动时刻的偏好值（`PrefKeys.webServiceWakeLock`）。
  /// 偏好为 false / 服务未启动时保持不持有；重复调用不重复 acquire。
  Future<void> onServiceStarted({required bool keepAwake}) {
    _serviceRunning = true;
    _preferenceEnabled = keepAwake;
    return _sync();
  }

  /// Web 服务停止成功后调用（幂等；无条件释放，偏好是否仍开都不再持锁）
  Future<void> onServiceStopped() {
    _serviceRunning = false;
    return _sync();
  }

  /// 偏好运行中切换后调用（其他设置页 onChanged）
  ///
  /// 服务运行中：true → acquire、false → release，即时生效。
  /// 服务未运行：期望态恒为 false，不 acquire；但原生态未知（新引擎 Dart
  /// 状态归零）或上次 release 失败（[_held] 仍 true）时仍要 `_sync`，
  /// 否则「关开关」无法释放原生遗留锁（审查边界 1）。
  Future<void> onPreferenceChanged(bool enabled) {
    _preferenceEnabled = enabled;
    if (!_serviceRunning && _nativeStateKnown && !_held) {
      return Future<void>.value();
    }
    return _sync();
  }

  /// 同步串行化：所有状态变化都排进同一条链，按「执行时刻的最新期望态」对账
  ///
  /// 修复审查 P2：快速 true→false 时，若两次 [_reconcileOnce] 并发执行，
  /// 第二次会因第一次尚未回写 [_held] 而误判「不需要释放」；串行化后第二次
  /// 一定在第一次完成（含 [_held] 回写）之后按最新期望态补发 release。
  Future<void> _sync() {
    if (!isSupported) return Future<void>.value();
    final previous = _syncChain ?? Future<void>.value();
    final next = previous.then((_) => _reconcileOnce());
    // 链上异常不得阻断后续同步（_send/_query 内部已吞异常，这里再兜一层）
    _syncChain = next.catchError((Object error) {
      debugPrint('[WebWakeLock] 同步链异常（忽略）: $error');
    });
    return _syncChain!;
  }

  /// 一次对账：先确认原生态（新引擎状态归零），再按期望态下发
  ///
  /// 下发结果以原生 `setEnabled` 回传的 `isHeld` 为准（审查边界 4）：
  /// - 回传 null（通道/原生失败）→ 原生态未知，下次先查询再重试；
  /// - 回传值与期望不一致（部分失败，如 Wi-Fi 锁降级）→ 镜像按回传值更新，
  ///   但保持「未知」，下次同步先查询实际状态再决定是否补发。
  Future<void> _reconcileOnce() async {
    if (!isSupported) return;
    if (!_nativeStateKnown) {
      final nativeHeld = await _queryNativeHeld();
      if (nativeHeld != null) {
        _held = nativeHeld;
        _nativeStateKnown = true;
      }
    }
    final desired = _serviceRunning && _preferenceEnabled;
    // 已确认原生态且与期望一致 → 无需下发；未知时即使镜像碰巧相同也要
    // 强制下发一次（原生幂等），避免引擎重建后遗留锁无法释放。
    if (_nativeStateKnown && desired == _held) return;
    final nativeHeld = await _send(desired);
    if (nativeHeld == null) {
      // 通道/原生失败：回到未知，下次同步先查询后重试
      _nativeStateKnown = false;
      return;
    }
    _held = nativeHeld;
    _nativeStateKnown = nativeHeld == desired;
  }

  /// 查询原生持有态（`isHeld`）：无法确认时返回 null
  Future<bool?> _queryNativeHeld() async {
    try {
      return await channel.invokeMethod<bool>('isHeld');
    } on MissingPluginException {
      return null;
    } on PlatformException catch (error) {
      debugPrint('[WebWakeLock] 查询唤醒锁状态失败（忽略）: $error');
      return null;
    } catch (error) {
      debugPrint('[WebWakeLock] 查询唤醒锁状态异常（忽略）: $error');
      return null;
    }
  }

  /// 唯一平台出口：返回原生 `setEnabled` 回传的实际持有态；失败返回 null
  ///
  /// 原生回传 `isHeld`（审查边界 4）：Dart 不再假定「调用成功=达到期望」，
  /// 由 `_reconcileOnce` 比较回传与期望后决定是否保持未知并重试。
  Future<bool?> _send(bool enabled) async {
    try {
      return await channel.invokeMethod<bool>('setEnabled', {
        'enabled': enabled,
      });
    } on MissingPluginException {
      // 非 Android 构建 / 测试环境未注册：静默（可预期）
      return null;
    } on PlatformException catch (error) {
      // 原生 acquire/release 失败（result.error）：回到未知，可重试
      debugPrint('[WebWakeLock] 平台通道异常（忽略）: $error');
      return null;
    } catch (error) {
      debugPrint('[WebWakeLock] 唤醒锁调用异常（忽略）: $error');
      return null;
    }
  }

  /// 测试缝隙：复位内存态（模拟新引擎；不触碰平台通道）
  ///
  /// [_nativeStateKnown] 复位为 false，使下一次同步先查询原生 `isHeld`，
  /// 与真实引擎重建后的行为一致。
  @visibleForTesting
  void debugReset() {
    _serviceRunning = false;
    _preferenceEnabled = false;
    _held = false;
    _nativeStateKnown = false;
    _syncChain = null;
  }
}
