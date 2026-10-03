import 'package:video_player/video_player.dart';

/// web 降级：无 Rust TTS 合成管线，不支持本地文件播放
///
/// [videoPlayerOptions] 仅为保持跨平台签名一致（io 平台用于禁用底层播放器
/// 自带音频焦点，见 `local_media_source_io.dart`）。
VideoPlayerController createLocalFileController(
  String source, {
  VideoPlayerOptions? videoPlayerOptions,
}) {
  throw UnsupportedError('Web 平台不支持本地 TTS 音频文件播放');
}
