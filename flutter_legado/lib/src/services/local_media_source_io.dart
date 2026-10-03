import 'dart:io';

import 'package:video_player/video_player.dart';

/// 由绝对路径或 `file://` URI 构造本地文件播放控制器（io 平台）
///
/// Windows 盘符路径（`C:\...`）不会被误判为 URI scheme（仅 scheme == 'file'
/// 才走 `File.fromUri`）；其余原样按文件路径处理。
VideoPlayerController createLocalFileController(String source) {
  final trimmed = source.trim();
  final uri = Uri.tryParse(trimmed);
  final file = uri != null && uri.scheme == 'file'
      ? File.fromUri(uri)
      : File(trimmed);
  return VideoPlayerController.file(file);
}
