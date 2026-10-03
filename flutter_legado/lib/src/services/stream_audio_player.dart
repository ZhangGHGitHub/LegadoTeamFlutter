import 'package:flutter/foundation.dart';
import 'package:video_player/video_player.dart';

import 'local_media_source.dart';

/// 流媒体音频播放器（复用项目已有 `video_player`，可播纯音频 URL/本地文件）
///
/// 对齐原版 ExoPlayer 播 `AudioPlay.durMediaUrl` 的最小路径：
/// setUrl → prepare → play；完成回调用于自动下一章。
/// TTS 朗读路径（A1 批）：`playLocalFile` 播 Rust 合成产物（audioPath），
/// 完成回调驱动段落推进。
///
/// — Auto + UI｜2026-08-12（本地文件播放接线 2026-10-03）
class StreamAudioPlayer {
  VideoPlayerController? _controller;
  VoidCallback? _listener;

  /// 播放完成回调，携带本次装载绑定的归属标识 [tag]（原样回传，播放器不解释）
  void Function(Object? tag)? onCompleted;

  /// 进度回调，携带本次装载绑定的归属标识 [tag]（原样回传，播放器不解释）
  ///
  /// [tag] 用途见 [playUrl]：听书路径传 (bookUrl, chapterIndex)，调用方据此
  /// 丢弃切章后迟到的旧章事件（P1 竞态修复）。
  void Function(Duration position, Duration duration, Object? tag)? onProgress;

  /// 底层 media3 播放器选项：关闭其自带音频焦点处理（单应用单焦点所有者）。
  ///
  /// [D1 | 2026-10-03 真机] 音频焦点唯一所有者是 MediaSessionBridge
  /// （对齐原版：BaseReadAloudService 负责 requestFocus，ExoPlayerHelper
  /// 构建的 ExoPlayer 未调用 setAudioAttributes，即 media3 默认
  /// `handleAudioFocus=false`）。若底层播放器也请求焦点，同一应用两个焦点
  /// 客户端互相抢占：后请求的播放器获胜，先请求的桥收到
  /// onAudioFocusChange(-1)[LOSS] → Dart 焦点监听误判为外部抢占并立即
  /// pause（真机播放 20ms 即被暂停）。
  ///
  /// video_player Android 实现把 `mixWithOthers=true` 映射为
  /// `ExoPlayer.setAudioAttributes(attrs, handleAudioFocus=false)`：
  /// 播放器不请求焦点、也不因焦点变化自行暂停；外部应用抢占焦点仍会送达
  /// 桥，Dart 侧 pause 语义不变（听书流模式与 TTS 路径同源受益）。
  @visibleForTesting
  static final VideoPlayerOptions playbackOptions =
      VideoPlayerOptions(mixWithOthers: true);

  bool get isInitialized => _controller?.value.isInitialized ?? false;
  bool get isPlaying => _controller?.value.isPlaying ?? false;
  Duration get position => _controller?.value.position ?? Duration.zero;
  Duration get duration => _controller?.value.duration ?? Duration.zero;
  String? get currentUrl => _currentUrl;
  String? _currentUrl;
  bool _completionFired = false;

  /// 加载并播放网络媒体 URL（http/https）
  ///
  /// [tag] 为本次装载的归属标识（听书路径传 (bookUrl, chapterIndex)），播放器
  /// 不做任何解释，仅在 [onProgress]/[onCompleted] 中原样回传；调用方据此校验
  /// 事件归属——切章后旧播放器 stop 前迟到的回调不会再被误认为新章事件
  /// （P1 竞态修复：旧章最终位置不得写入新章进度键）。
  Future<void> playUrl(String url, {double speed = 1.0, Object? tag}) async {
    final trimmed = url.trim();
    if (trimmed.isEmpty) {
      throw ArgumentError('播放地址为空');
    }
    await stop();
    _currentUrl = trimmed;
    _completionFired = false;
    final c = VideoPlayerController.networkUrl(
      Uri.parse(trimmed),
      videoPlayerOptions: playbackOptions,
    );
    await _start(c, speed, tag);
  }

  /// 加载并播放本地音频文件（TTS 合成产物 audioPath）
  ///
  /// 支持绝对路径与 `file://` URI（平台差异见局部导入的
  /// `local_media_source_io.dart` / `_web.dart`）。
  /// [speed] 默认 1.0：TTS 语速已由合成侧（engineUrl 模板 speakSpeed）
  /// 应用，播放侧不再二次变速。[tag] 语义同 [playUrl]（TTS 路径一般为 null）。
  Future<void> playLocalFile(
    String path, {
    double speed = 1.0,
    Object? tag,
  }) async {
    final trimmed = path.trim();
    if (trimmed.isEmpty) {
      throw ArgumentError('本地播放路径为空');
    }
    await stop();
    _currentUrl = trimmed;
    _completionFired = false;
    final c = createLocalFileController(
      trimmed,
      videoPlayerOptions: playbackOptions,
    );
    await _start(c, speed, tag);
  }

  /// 初始化控制器 → 挂完成监听 → 开始播放（网络/本地共用）
  Future<void> _start(
    VideoPlayerController c,
    double speed,
    Object? tag,
  ) async {
    _controller = c;
    await c.initialize();
    await c.setPlaybackSpeed(speed <= 0 ? 1.0 : speed);
    _listener = () {
      if (_controller != c) return;
      final v = c.value;
      // tag 随本次装载的监听闭包捕获：旧控制器的事件带旧归属
      onProgress?.call(v.position, v.duration, tag);
      if (!_completionFired &&
          v.isInitialized &&
          v.duration > Duration.zero &&
          (v.isCompleted ||
              v.position >= v.duration - const Duration(milliseconds: 200)) &&
          !v.isPlaying) {
        _completionFired = true;
        onCompleted?.call(tag);
      }
    };
    c.addListener(_listener!);
    await c.play();
  }

  Future<void> pause() async {
    await _controller?.pause();
  }

  Future<void> resume() async {
    _completionFired = false;
    await _controller?.play();
  }

  Future<void> setSpeed(double speed) async {
    final s = speed <= 0 ? 1.0 : speed;
    await _controller?.setPlaybackSpeed(s);
  }

  Future<void> seek(Duration position) async {
    await _controller?.seekTo(position);
  }

  Future<void> stop() async {
    final c = _controller;
    final l = _listener;
    _controller = null;
    _listener = null;
    _currentUrl = null;
    _completionFired = false;
    if (c != null) {
      if (l != null) c.removeListener(l);
      try {
        await c.pause();
      } catch (e) {
        debugPrint('StreamAudioPlayer pause: $e');
      }
      await c.dispose();
    }
  }

  Future<void> dispose() => stop();
}
