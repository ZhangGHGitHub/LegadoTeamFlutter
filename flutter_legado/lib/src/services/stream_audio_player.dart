import 'package:flutter/foundation.dart';
import 'package:video_player/video_player.dart';

/// 流媒体音频播放器（复用项目已有 `video_player`，可播纯音频 URL）
///
/// 对齐原版 ExoPlayer 播 `AudioPlay.durMediaUrl` 的最小路径：
/// setUrl → prepare → play；完成回调用于自动下一章。
///
/// — Auto + UI｜2026-08-12
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
          v.position >= v.duration - const Duration(milliseconds: 200) &&
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
