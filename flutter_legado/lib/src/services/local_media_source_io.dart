import 'dart:io';

import 'package:video_player/video_player.dart';

/// 由绝对路径或 `file://` URI 构造本地文件播放控制器（io 平台）
///
/// Windows 盘符路径（`C:\...`）不会被误判为 URI scheme（仅 scheme == 'file'
/// 才走 `File.fromUri`）；其余原样按文件路径处理。
///
/// [videoPlayerOptions] 由 `StreamAudioPlayer.playbackOptions` 传入：
/// `mixWithOthers=true` → media3 `handleAudioFocus=false`，避免底层播放器
/// 与 MediaSessionBridge 互抢焦点（D1 真机修复，2026-10-03）。
VideoPlayerController createLocalFileController(
  String source, {
  VideoPlayerOptions? videoPlayerOptions,
}) {
  final trimmed = source.trim();
  final uri = Uri.tryParse(trimmed);
  final file = uri != null && uri.scheme == 'file'
      ? File.fromUri(uri)
      : File(trimmed);
  return VideoPlayerController.file(
    file,
    videoPlayerOptions: videoPlayerOptions,
  );
}
