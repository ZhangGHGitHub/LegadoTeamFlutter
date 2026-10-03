import 'package:video_player/video_player.dart';

/// web 降级：无 Rust TTS 合成管线，不支持本地文件播放
VideoPlayerController createLocalFileController(String source) {
  throw UnsupportedError('Web 平台不支持本地 TTS 音频文件播放');
}
