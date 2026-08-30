import AVFoundation
import Flutter
import MediaPlayer
import UIKit

/// [iOS 轨 P2-C] 锁屏控制 / Now Playing——对齐 Android MediaSessionBridge 的通道协议：
/// Flutter→Native: init / release / requestAudioFocus / abandonAudioFocus /
///   updatePlaybackState{state,position} / updateMetadata{title,artist,album} /
///   setPlaying{playing} / setWakeLock{enabled}
/// Native→Flutter: onPlay / onPause / onSkipToNext / onSkipToPrevious / onStop /
///   onAudioFocusChange{gain|loss|lossTransient|lossTransientCanDuck}
///
/// iOS 无前台服务/WakeLock 概念（后台运行由 UIBackgroundModes=audio +
/// AppDelegate 的 AVAudioSession playback 类别保障），setWakeLock 为空实现。
/// 拖动进度条暂不支持：通道协议不含 seek（Android 侧亦无该方向指令）。
@objc class NowPlayingBridge: NSObject {
  static let shared = NowPlayingBridge()

  private var channel: FlutterMethodChannel?
  private var isPlaying = false
  private var commandsConfigured = false
  private var interruptionsObserved = false

  private override init() {
    super.init()
  }

  /// 在 AppDelegate 的引擎初始化回调中调用（进程内仅一次）
  func attach(messenger: FlutterBinaryMessenger) {
    guard channel == nil else { return }
    let ch = FlutterMethodChannel(name: "legado/media_session", binaryMessenger: messenger)
    ch.setMethodCallHandler { [weak self] call, result in
      self?.handle(call: call, result: result)
    }
    channel = ch
  }

  private func handle(call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "init":
      configureRemoteCommands()
      observeInterruptions()
      result(true)
    case "release":
      clearNowPlaying()
      result(nil)
    case "requestAudioFocus":
      // iOS 无竞争焦点模型：会话已在 AppDelegate 设为 playback，
      // 中断经 interruptionNotification 下发（见 observeInterruptions）
      result(true)
    case "abandonAudioFocus":
      // 保持会话激活（退出后台继续播放），不做降激活
      result(nil)
    case "updatePlaybackState":
      let args = call.arguments as? [String: Any] ?? [:]
      let state = args["state"] as? String ?? "paused"
      let positionMs = (args["position"] as? NSNumber)?.intValue ?? 0
      updatePlaybackState(state: state, positionMs: positionMs)
      result(nil)
    case "updateMetadata":
      let args = call.arguments as? [String: Any] ?? [:]
      updateMetadata(
        title: args["title"] as? String ?? "",
        artist: args["artist"] as? String ?? "",
        album: args["album"] as? String ?? ""
      )
      result(nil)
    case "setPlaying":
      let args = call.arguments as? [String: Any] ?? [:]
      isPlaying = args["playing"] as? Bool ?? false
      result(nil)
    case "setWakeLock":
      // iOS 无 WakeLock：后台保活由音频会话承担
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // MARK: - Now Playing 信息

  private var nowPlayingInfo: [String: Any] = [:]

  private func updatePlaybackState(state: String, positionMs: Int) {
    switch state {
    case "playing":
      isPlaying = true
      nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = 1.0
      nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = positionMs / 1000
      nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackStatus] =
        MPNowPlayingPlaybackStatus.playing
    case "paused", "buffering":
      isPlaying = false
      nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = 0.0
      nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = positionMs / 1000
      nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackStatus] =
        state == "buffering" ? MPNowPlayingPlaybackStatus.interrupted
          : MPNowPlayingPlaybackStatus.paused
    default: // stopped
      clearNowPlaying()
      return
    }
    MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
  }

  private func updateMetadata(title: String, artist: String, album: String) {
    if !title.isEmpty { nowPlayingInfo[MPMediaItemPropertyTitle] = title }
    if !artist.isEmpty { nowPlayingInfo[MPMediaItemPropertyArtist] = artist }
    if !album.isEmpty { nowPlayingInfo[MPMediaItemPropertyAlbumTitle] = album }
    MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
  }

  private func clearNowPlaying() {
    isPlaying = false
    nowPlayingInfo.removeAll()
    MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
  }

  // MARK: - 远程命令（锁屏/控制中心/耳机线控）

  private func configureRemoteCommands() {
    guard !commandsConfigured else { return }
    commandsConfigured = true
    let center = MPRemoteCommandCenter.shared()

    center.playCommand.isEnabled = true
    center.playCommand.addTarget { [weak self] _ in
      self?.notifyFlutter("onPlay")
      return .success
    }
    center.pauseCommand.isEnabled = true
    center.pauseCommand.addTarget { [weak self] _ in
      self?.notifyFlutter("onPause")
      return .success
    }
    center.togglePlayPauseCommand.isEnabled = true
    center.togglePlayPauseCommand.addTarget { [weak self] _ in
      self?.notifyFlutter(self?.isPlaying == true ? "onPause" : "onPlay")
      return .success
    }
    center.nextTrackCommand.isEnabled = true
    center.nextTrackCommand.addTarget { [weak self] _ in
      self?.notifyFlutter("onSkipToNext")
      return .success
    }
    center.previousTrackCommand.isEnabled = true
    center.previousTrackCommand.addTarget { [weak self] _ in
      self?.notifyFlutter("onSkipToPrevious")
      return .success
    }
    center.stopCommand.isEnabled = true
    center.stopCommand.addTarget { [weak self] _ in
      self?.notifyFlutter("onStop")
      return .success
    }
    // 拖动进度：协议无 seek，不启用 changePlaybackPositionCommand
  }

  // MARK: - 系统中断（来电/Siri）→ 焦点事件映射

  private func observeInterruptions() {
    guard !interruptionsObserved else { return }
    interruptionsObserved = true
    NotificationCenter.default.addObserver(
      forName: AVAudioSession.interruptionNotification,
      object: AVAudioSession.sharedInstance()
    ) { [weak self] notification in
      guard
        let info = notification.userInfo,
        let typeRaw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
        let type = AVAudioSession.InterruptionType(rawValue: typeRaw)
      else { return }
      switch type {
      case .began:
        self?.notifyFlutter("onAudioFocusChange", "lossTransient")
      case .ended:
        let optionRaw = info[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
        let options = AVAudioSession.InterruptionOptions(rawValue: optionRaw)
        self?.notifyFlutter(
          "onAudioFocusChange",
          options.contains(.shouldResume) ? "gain" : "loss"
        )
      @unknown default:
        break
      }
    }
  }

  // MARK: - Native → Flutter

  private func notifyFlutter(_ method: String, _ arguments: Any? = nil) {
    DispatchQueue.main.async { [weak self] in
      self?.channel?.invokeMethod(method, arguments: arguments)
    }
  }
}
