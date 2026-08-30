import Flutter
import UIKit
import AVFAudio

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // [iOS 轨 P2-B] 后台听书：音频会话设为 playback（配合 Info.plist
    // UIBackgroundModes=audio，静音开关不影响朗读、退后台继续播放；
    // 不加 mixWithOthers——对齐 Android 音频焦点独占语义）。
    // 锁屏控制（MPNowPlayingInfoCenter/远程命令）由 P2-C audio_service 接管。
    do {
      try AVAudioSession.sharedInstance().setCategory(
        .playback, mode: .spokenAudio)
      try AVAudioSession.sharedInstance().setActive(true)
    } catch {
      NSLog("[AppDelegate] AVAudioSession 配置失败: \(error)")
    }
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
  }
}
