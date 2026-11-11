import 'dart:async';

import 'package:flutter/services.dart';

/// 音频焦点事件类型
enum AudioFocusEvent {
  /// 获得焦点
  gain,

  /// 永久丢失焦点
  loss,

  /// 暂时丢失焦点（需要暂停，之后会恢复）
  lossTransient,

  /// 短暂丢失焦点（可降低音量）
  lossTransientCanDuck,
}

/// 媒体按钮事件类型
enum MediaButtonEvent {
  /// 播放
  play,

  /// 暂停
  pause,

  /// 下一首
  skipToNext,

  /// 上一首
  skipToPrevious,

  /// 停止
  stop,
}

/// 音频服务 — 后台媒体按钮 + 焦点管理
///
/// 通过 Platform Channel 与 Android MediaSession 通信，
/// 复刻原版 BaseReadAloudService 中的媒体会话和焦点管理逻辑。
///
/// 功能：
/// - 初始化/释放 MediaSession
/// - 请求/放弃音频焦点
/// - 更新播放状态和元数据
/// - 监听媒体按钮事件（播放/暂停/上一首/下一首/停止）
/// - 监听音频焦点变化（获得/丢失/暂时丢失）
class AudioService {
  AudioService._();

  static final AudioService _instance = AudioService._();

  /// 单例实例
  static AudioService get instance => _instance;

  /// 媒体会话通道
  static const MethodChannel _channel = MethodChannel('legado/media_session');

  /// 音频焦点事件流控制器
  final StreamController<AudioFocusEvent> _audioFocusController =
      StreamController<AudioFocusEvent>.broadcast();

  /// 媒体按钮事件流控制器
  final StreamController<MediaButtonEvent> _mediaButtonController =
      StreamController<MediaButtonEvent>.broadcast();

  /// 是否已初始化
  bool _initialized = false;

  /// 是否已注册通道回调
  bool _handlerRegistered = false;

  /// 真实音频（听书/TTS）播放态广播流控制器
  ///
  /// [iOS Web 服务保活 | 2026-10-07] Web 服务运行期间 iOS 用近静音音轨维持
  /// 后台存活；真实音频播放时静音音轨应暂停（音频会话本身即保活），停止后
  /// 恢复。播放态经 notifyPlaying / notifyPaused / notifyStopped 汇聚
  /// （audio_notifier 的全部播放态变更都走这三个便捷方法），此处以广播流
  /// 暴露，供 WebKeepAliveService 决策，与平台通道是否初始化无关。
  final StreamController<bool> _playbackActiveController =
      StreamController<bool>.broadcast();

  bool _playbackActive = false;

  // ===== 公开属性 =====

  /// 音频焦点事件流
  Stream<AudioFocusEvent> get audioFocusStream => _audioFocusController.stream;

  /// 媒体按钮事件流
  Stream<MediaButtonEvent> get mediaButtonStream =>
      _mediaButtonController.stream;

  /// 是否已初始化
  bool get isInitialized => _initialized;

  /// 真实音频（听书/TTS）播放态流（Web 服务保活共存判断用）
  Stream<bool> get playbackActiveStream => _playbackActiveController.stream;

  /// 真实音频（听书/TTS）当前是否正在播放
  bool get playbackActive => _playbackActive;

  // ===== 生命周期方法 =====
  //
  // [TTS P3 回修 | 2026-11-11] init/release 串行化：
  // - release 在途时 init 必须等待（否则旧 release 完成后原生已释放，
  //   Dart 却因 `_initialized` 早置 true 而误判就绪，通知/耳机键失效）；
  // - init 在途时 release 先落 `_initialized=false` 并用代际号使旧 init
  //   的结果失效（否则 release 空转后旧 init 重新把服务标为就绪，
  //   MediaSession 残留为 STOPPED 记录）。
  // 最终状态只可能收敛到「已释放」或「已就绪」，不存在半状态。
  /// 在途 init（并发调用共享同一 Future）
  Future<void>? _initFuture;

  /// 在途 release（并发释放合并等待）
  Future<void>? _releaseFuture;

  /// 生命周期代际号：dispose 自增使在途 init 的完成回调失效
  int _lifecycleGeneration = 0;

  /// 初始化媒体会话
  ///
  /// 在听书页面 initState 时调用，创建 Android MediaSession 实例
  /// 并注册媒体按钮回调。
  Future<void> init() async {
    // release 在途：等待其完成后再决定是否初始化，避免与新 init 交错
    final release = _releaseFuture;
    if (release != null) await release;

    if (_initialized) return;
    final pending = _initFuture;
    if (pending != null) return pending;

    final generation = ++_lifecycleGeneration;
    // 注册原生 → Flutter 的回调处理
    _registerHandler();

    final future = _initialize(generation);
    _initFuture = future;
    try {
      await future;
    } finally {
      if (identical(_initFuture, future)) _initFuture = null;
    }
  }

  Future<void> _initialize(int generation) async {
    try {
      await _channel.invokeMethod<bool>('init');
      // 仅在期间没有 dispose 发生时标记就绪（旧 init 不得覆盖新 release）
      if (generation == _lifecycleGeneration) _initialized = true;
    } on PlatformException {
      // 非 Android 平台或初始化失败，静默处理
      if (generation == _lifecycleGeneration) _initialized = false;
    } on MissingPluginException {
      // 插件未注册（如测试环境），静默处理
      if (generation == _lifecycleGeneration) _initialized = false;
    }
  }

  /// 释放资源
  ///
  /// 在听书页面 dispose 时调用，释放 MediaSession 和音频焦点。
  Future<void> dispose() async {
    // 在途 init 视为本次释放的会话；清空引用使随后的重播 init 能在
    // release 完成后真正重建，而不是复用已失效的旧 init Future。
    final initInFlight = _initFuture;
    _initFuture = null;

    // 已有 release 在途：合并等待，不重复发送 release
    final inFlight = _releaseFuture;
    if (inFlight != null) {
      await inFlight;
      return;
    }

    // 先落未初始化态 + 使在途 init 失效，再等待原生 release（关键顺序：
    // 旧实现在 await 之后才置 false，期间 init 会误判仍已初始化而空转）。
    _lifecycleGeneration++;
    final hadSession = _initialized || initInFlight != null;
    _initialized = false;
    if (!hadSession) return;

    final future = _releaseNative();
    _releaseFuture = future;
    try {
      await future;
    } finally {
      if (identical(_releaseFuture, future)) _releaseFuture = null;
    }
  }

  Future<void> _releaseNative() async {
    try {
      await _channel.invokeMethod<void>('release');
    } on PlatformException {
      // 静默处理
    } on MissingPluginException {
      // 静默处理
    }
  }

  // ===== 音频焦点方法 =====

  /// 请求音频焦点
  ///
  /// 复刻原版 requestFocus()，在播放前调用。
  /// 返回 true 表示成功获取焦点。
  Future<bool> requestAudioFocus() async {
    if (!_initialized) return false;

    try {
      final result = await _channel.invokeMethod<bool>('requestAudioFocus');
      return result ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// 放弃音频焦点
  ///
  /// 复刻原版 abandonFocus()，在停止播放或页面销毁时调用。
  Future<void> abandonAudioFocus() async {
    if (!_initialized) return;

    try {
      await _channel.invokeMethod<void>('abandonAudioFocus');
    } on PlatformException {
      // 静默处理
    } on MissingPluginException {
      // 静默处理
    }
  }

  // ===== 播放状态方法 =====

  /// 更新播放状态
  ///
  /// 复刻原版 upMediaSessionPlaybackState()。
  /// [state] 可选值: "playing", "paused", "stopped", "buffering"
  /// [position] 当前播放位置（毫秒）
  Future<void> updatePlaybackState({
    required String state,
    int position = 0,
  }) async {
    if (!_initialized) return;

    try {
      await _channel.invokeMethod<void>('updatePlaybackState', {
        'state': state,
        'position': position,
      });
    } on PlatformException {
      // 静默处理
    } on MissingPluginException {
      // 静默处理
    }
  }

  /// 更新媒体元数据
  ///
  /// 复刻原版 upMediaMetadata()。
  /// [title] 章节标题
  /// [artist] 显示为"正在朗读: 书名"
  /// [album] 作者
  Future<void> updateMetadata({
    required String title,
    String artist = '',
    String album = '',
  }) async {
    if (!_initialized) return;

    try {
      await _channel.invokeMethod<void>('updateMetadata', {
        'title': title,
        'artist': artist,
        'album': album,
      });
    } on PlatformException {
      // 静默处理
    } on MissingPluginException {
      // 静默处理
    }
  }

  /// 设置当前播放状态（用于焦点恢复判断）
  Future<void> setPlaying(bool playing) async {
    if (!_initialized) return;

    try {
      await _channel.invokeMethod<void>('setPlaying', {'playing': playing});
    } on PlatformException {
      // 静默处理
    } on MissingPluginException {
      // 静默处理
    }
  }

  /// 听书 PARTIAL_WAKE_LOCK（对齐 PreferKey.audioPlayWakeLock / AudioPlayService）
  Future<void> setWakeLock(bool enabled) async {
    if (!_initialized) {
      await init();
    }
    try {
      await _channel.invokeMethod<void>('setWakeLock', {'enabled': enabled});
    } on PlatformException {
      // 静默处理
    } on MissingPluginException {
      // 静默处理
    }
  }

  // ===== 便捷方法 =====

  /// 通知系统当前正在播放
  Future<void> notifyPlaying({int position = 0}) async {
    _setPlaybackActive(true);
    await setPlaying(true);
    await updatePlaybackState(state: 'playing', position: position);
  }

  /// 通知系统当前已暂停
  Future<void> notifyPaused({int position = 0}) async {
    _setPlaybackActive(false);
    await setPlaying(false);
    await updatePlaybackState(state: 'paused', position: position);
  }

  /// 通知系统当前已停止
  Future<void> notifyStopped() async {
    _setPlaybackActive(false);
    await setPlaying(false);
    await updatePlaybackState(state: 'stopped');
  }

  /// 更新真实音频播放态（值变化才广播；供 Web 保活共存的启停判断）
  void _setPlaybackActive(bool active) {
    if (_playbackActive == active) return;
    _playbackActive = active;
    _playbackActiveController.add(active);
  }

  // ===== 内部方法 =====

  /// 注册原生 → Flutter 的方法调用处理器
  void _registerHandler() {
    if (_handlerRegistered) return;
    _handlerRegistered = true;

    _channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'onPlay':
          _mediaButtonController.add(MediaButtonEvent.play);
        case 'onPause':
          _mediaButtonController.add(MediaButtonEvent.pause);
        case 'onSkipToNext':
          _mediaButtonController.add(MediaButtonEvent.skipToNext);
        case 'onSkipToPrevious':
          _mediaButtonController.add(MediaButtonEvent.skipToPrevious);
        case 'onStop':
          _mediaButtonController.add(MediaButtonEvent.stop);
        case 'onAudioFocusChange':
          final event = _parseFocusEvent(call.arguments as String?);
          if (event != null) {
            _audioFocusController.add(event);
          }
      }
    });
  }

  /// 解析焦点事件字符串为枚举
  AudioFocusEvent? _parseFocusEvent(String? value) {
    switch (value) {
      case 'gain':
        return AudioFocusEvent.gain;
      case 'loss':
        return AudioFocusEvent.loss;
      case 'lossTransient':
        return AudioFocusEvent.lossTransient;
      case 'lossTransientCanDuck':
        return AudioFocusEvent.lossTransientCanDuck;
      default:
        return null;
    }
  }
}
