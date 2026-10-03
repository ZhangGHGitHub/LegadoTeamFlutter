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
  void Function()? onCompleted;
  void Function(Duration position, Duration duration)? onProgress;

  bool get isInitialized => _controller?.value.isInitialized ?? false;
  bool get isPlaying => _controller?.value.isPlaying ?? false;
  Duration get position => _controller?.value.position ?? Duration.zero;
  Duration get duration => _controller?.value.duration ?? Duration.zero;
  String? get currentUrl => _currentUrl;
  String? _currentUrl;
  bool _completionFired = false;

  /// 加载并播放网络媒体 URL（http/https）
  Future<void> playUrl(String url, {double speed = 1.0}) async {
    final trimmed = url.trim();
    if (trimmed.isEmpty) {
      throw ArgumentError('播放地址为空');
    }
    await stop();
    _currentUrl = trimmed;
    _completionFired = false;
    final c = VideoPlayerController.networkUrl(Uri.parse(trimmed));
    await _start(c, speed);
  }

  /// 加载并播放本地音频文件（TTS 合成产物 audioPath）
  ///
  /// 支持绝对路径与 `file://` URI（平台差异见局部导入的
  /// `local_media_source_io.dart` / `_web.dart`）。
  /// [speed] 默认 1.0：TTS 语速已由合成侧（engineUrl 模板 speakSpeed）
  /// 应用，播放侧不再二次变速。
  Future<void> playLocalFile(String path, {double speed = 1.0}) async {
    final trimmed = path.trim();
    if (trimmed.isEmpty) {
      throw ArgumentError('本地播放路径为空');
    }
    await stop();
    _currentUrl = trimmed;
    _completionFired = false;
    final c = createLocalFileController(trimmed);
    await _start(c, speed);
  }

  /// 初始化控制器 → 挂完成监听 → 开始播放（网络/本地共用）
  Future<void> _start(VideoPlayerController c, double speed) async {
    _controller = c;
    await c.initialize();
    await c.setPlaybackSpeed(speed <= 0 ? 1.0 : speed);
    _listener = () {
      if (_controller != c) return;
      final v = c.value;
      onProgress?.call(v.position, v.duration);
      if (!_completionFired &&
          v.isInitialized &&
          v.duration > Duration.zero &&
          (v.isCompleted ||
              v.position >= v.duration - const Duration(milliseconds: 200)) &&
          !v.isPlaying) {
        _completionFired = true;
        onCompleted?.call();
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
