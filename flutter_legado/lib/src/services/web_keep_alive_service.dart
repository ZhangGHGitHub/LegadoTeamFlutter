import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'audio_service.dart';

/// Web 服务后台保活结果（面向调用方 / UI 的轻量状态）
enum WebKeepAliveStatus {
  /// 非 iOS 平台：无此问题
  ///
  /// Android 侧无此缺陷（原版靠前台服务保进程，本仓库 Android 未接保活
  /// 属已登记差距），本批按红线不做 Android 实现。
  notApplicable,

  /// 未启用（stop 之后）
  idle,

  /// 静音音轨运行中：App 退后台/锁屏后的存活由本保活维持
  active,

  /// Web 服务在跑，但真实音频（听书/TTS）正在播放：
  /// 音频会话本身即维持进程存活，静音音轨让位（不叠加、不争会话）
  deferredByRealAudio,

  /// 平台保活启动失败（会话激活失败等）→ 回退「仅前台可用」
  /// （不阻断 Web 服务启动，仅记日志并可经 [WebKeepAliveService.status] 提示）
  failed,
}

/// iOS Web 服务后台保活接线（方案 C + A 兜底，2026-10-07 用户已批准）
///
/// ## 目的对应原版 Android
/// 原版 `WebService.kt:76` 的 `useWakeLock`（默认关）用 `PARTIAL_WAKE_LOCK`
/// 防 CPU/Wi-Fi 睡眠；iOS 无前台服务/WakeLock，平台等价物是
/// `UIBackgroundModes: audio`（Info.plist 已声明）+ 后台播放近静音音频：
/// Web 服务运行期间循环播放一段近静音 PCM，系统因音频后台模式不挂起进程，
/// 局域网浏览器可持续访问。
///
/// ## 生命周期（无独立开关，对齐原版语义）
/// - Web 服务启动成功（`settings_screen.dart` 的 `startServer` 成功后）→ [start]
/// - Web 服务停止成功（`stopServer` 成功后）→ [stop]
/// - iOS 退后台/回前台无需特殊处理：audio 后台模式本身就维持进程；
///   服务停止时必须停止保活（本类唯一职责边界）。
///
/// ## 与听书/TTS 共存（必须策略）
/// App 正在播真实音频时，保活静音音轨**暂停**（真实音频自己就在维持存活）；
/// 真实音频停止（含用户暂停朗读）且服务仍运行 → 恢复保活。
/// 依据来自 [AudioService.playbackActiveStream]（听书/TTS 的播放态全部经
/// `notifyPlaying` / `notifyPaused` / `notifyStopped` 汇聚）。
///
/// ## A 兜底
/// 保活启动失败不抛异常、不阻断 Web 服务：[start] 返回
/// [WebKeepAliveStatus.failed]，调用方（设置页卡片副题）据此提示
/// 「仅前台可用」；其余形态不变。
///
/// — 全栈工程师 ｜ 2026-10-07
class WebKeepAliveService {
  WebKeepAliveService._();

  /// 进程内单例（保活生命周期 = Web 服务生命周期，跨页面存活）
  static final WebKeepAliveService instance = WebKeepAliveService._();

  /// 与 iOS `WebKeepAlive.swift` 的通道
  ///
  /// 不复用 `legado/media_session` 的 `setWakeLock`：该空壳已被听书
  /// 「播放唤醒锁」接线（audio_screen.dart → AudioNotifier.setWakeLockEnabled，
  /// 语义是 audioPlayWakeLock 偏好），复用之会与 Web 保活互相踩停；
  /// 且其 Dart 封装带 `_initialized` 门控（未初始化会触发 MediaSession init），
  /// 语义不符。故新建轻量通道（报告已说明）。
  @visibleForTesting
  static const MethodChannel channel = MethodChannel('legado/web_keepalive');

  /// 平台标志（测试缝隙，对齐 `SystemBrightness.platformIsIOS` 既有做法）
  @visibleForTesting
  static bool Function() platformIsIOS = () => Platform.isIOS;

  /// Web 服务是否在运行（用户意图，start 后为 true、stop 后为 false）
  bool _serviceRunning = false;

  /// 真实音频（听书/TTS）是否正在播放
  bool _realAudioActive = false;

  /// 平台静音音轨是否正在运行
  bool _keepAliveActive = false;

  /// 订阅真实音频播放态（懒订阅，只订一次；广播流不持有生命周期）
  StreamSubscription<bool>? _audioSub;

  WebKeepAliveStatus _status = WebKeepAliveStatus.idle;

  /// 当前保活状态（UI 可读；非 iOS 平台为 [WebKeepAliveStatus.notApplicable]）
  WebKeepAliveStatus get status => _status;

  /// 平台是否适用（仅 iOS 需要本保活）
  bool get isSupported => platformIsIOS();

  /// Web 服务意图是否在运行
  bool get isRunning => _serviceRunning;

  /// 静音音轨当前是否运行
  bool get isActive => _keepAliveActive;

  /// Web 服务启动成功后调用（幂等；非 iOS 为 no-op）
  Future<WebKeepAliveStatus> start() async {
    _serviceRunning = true;
    if (!isSupported) {
      _status = WebKeepAliveStatus.notApplicable;
      return _status;
    }
    _subscribeRealAudioState();
    // 真实音频播放中：音频会话已保活，静音音轨暂缓（TTS 停止后自动恢复）
    if (_realAudioActive) {
      _status = WebKeepAliveStatus.deferredByRealAudio;
      return _status;
    }
    // 幂等：已激活则不重复下发音轨命令（服务重复 start / 页面重进）
    if (_keepAliveActive) {
      _status = WebKeepAliveStatus.active;
      return _status;
    }
    return _applyPlatform(true);
  }

  /// Web 服务停止成功后调用（幂等；非 iOS 为 no-op）
  Future<WebKeepAliveStatus> stop() async {
    _serviceRunning = false;
    if (!isSupported) {
      _status = WebKeepAliveStatus.notApplicable;
      return _status;
    }
    if (_keepAliveActive) {
      await _applyPlatform(false);
    }
    _status = WebKeepAliveStatus.idle;
    return _status;
  }

  /// 订阅真实音频播放态（懒订阅，只订一次；订阅建立时读一次当前值兜底
  /// 「订阅前已在播放」，此后只以流事件更新，避免覆盖更新的状态）
  void _subscribeRealAudioState() {
    if (_audioSub != null) return;
    _realAudioActive = AudioService.instance.playbackActive;
    _audioSub = AudioService.instance.playbackActiveStream.listen(
      _onRealAudioStateChanged,
      onError: (Object error) {
        debugPrint('[WebKeepAlive] 真实音频状态流异常（忽略）: $error');
      },
    );
  }

  /// 真实音频播放态变化：启停静音音轨（仅服务运行中响应）
  Future<void> _onRealAudioStateChanged(bool playing) async {
    _realAudioActive = playing;
    if (!_serviceRunning || !isSupported) return;
    if (playing) {
      // 让位：真实音频自己维持存活（会话不切换，仅停静音音轨）
      if (_keepAliveActive) await _applyPlatform(false);
      _status = WebKeepAliveStatus.deferredByRealAudio;
    } else if (!_keepAliveActive) {
      // 真实音频停止（含暂停）且服务仍在运行 → 恢复保活
      await _applyPlatform(true);
    }
  }

  /// 平台调用（唯一出口）：
  /// - 成功 → [WebKeepAliveStatus.active] / [WebKeepAliveStatus.idle]
  /// - 失败 → [WebKeepAliveStatus.failed]（仅日志，不抛）
  Future<WebKeepAliveStatus> _applyPlatform(bool enabled) async {
    try {
      final ok = await channel.invokeMethod<bool>('setEnabled', {
        'enabled': enabled,
      });
      if (!enabled) {
        _keepAliveActive = false;
        return WebKeepAliveStatus.idle;
      }
      _keepAliveActive = ok == true;
      if (!_keepAliveActive) {
        debugPrint('[WebKeepAlive] 平台保活启动失败：回退仅前台可用');
        _status = WebKeepAliveStatus.failed;
        return _status;
      }
      _status = WebKeepAliveStatus.active;
      return _status;
    } on MissingPluginException {
      // 未注册（测试环境 / 非 iOS 构建）——不抛，按失败降级
      _keepAliveActive = false;
      if (enabled) {
        _status = WebKeepAliveStatus.failed;
        return _status;
      }
      return WebKeepAliveStatus.idle;
    } on PlatformException catch (error) {
      _keepAliveActive = false;
      debugPrint('[WebKeepAlive] 平台通道异常（忽略）: $error');
      if (enabled) {
        _status = WebKeepAliveStatus.failed;
        return _status;
      }
      return WebKeepAliveStatus.idle;
    } catch (error) {
      // 兜底：任何未预期异常都不得上抛阻断 Web 服务开关
      _keepAliveActive = false;
      debugPrint('[WebKeepAlive] 保活调用异常（忽略）: $error');
      if (enabled) {
        _status = WebKeepAliveStatus.failed;
        return _status;
      }
      return WebKeepAliveStatus.idle;
    }
  }

  /// 测试缝隙：复位为初始态（不触碰平台通道；订阅保留，
  /// 由测试侧经 AudioService 播放态复位保证一致性）
  @visibleForTesting
  void debugReset() {
    _serviceRunning = false;
    _realAudioActive = AudioService.instance.playbackActive;
    _keepAliveActive = false;
    _status = WebKeepAliveStatus.idle;
  }
}
