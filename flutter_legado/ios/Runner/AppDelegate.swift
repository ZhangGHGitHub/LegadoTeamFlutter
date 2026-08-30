import AVFAudio
import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // [iOS 轨 P2-B] 后台听书：音频会话设为 playback（配合 Info.plist
    // UIBackgroundModes=audio，静音开关不影响朗读、退后台继续播放；
    // 不加 mixWithOthers——对齐 Android 音频焦点独占语义）。
    // 锁屏控制（Now Playing/远程命令）由 NowPlayingBridge 接管（P2-C）。
    do {
      try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
      try AVAudioSession.sharedInstance().setActive(true)
    } catch {
      NSLog("[AppDelegate] AVAudioSession 配置失败: \(error)")
    }
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    // [iOS 轨 P2-C] 注册锁屏控制通道（legado/media_session，协议对齐
    // Android MediaSessionBridge.kt）。registry 协议仅暴露 registrar，
    // messenger 经 registrar 取（FlutterPlugin.h FlutterBaseRegistrar）。
    let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "NowPlayingBridge")
    NowPlayingBridge.shared.attach(messenger: registrar.messenger)
  }
}
