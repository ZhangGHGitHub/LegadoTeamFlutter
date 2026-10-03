/// 本地媒体源 → VideoPlayerController 的平台条件导入入口
///
/// - io 平台（Android/iOS/桌面）：`VideoPlayerController.file` 播放本地文件；
/// - web：TTS 合成走 Rust FFI（web 无此管线），本地文件播放直接报
///   `UnsupportedError`，保证 web 编译不引入 `dart:io`。
///
/// — Auto + UI｜2026-10-03（A1 批：TTS 合成产物接线真实播放）
library;

export 'local_media_source_io.dart'
    if (dart.library.js_interop) 'local_media_source_web.dart';
