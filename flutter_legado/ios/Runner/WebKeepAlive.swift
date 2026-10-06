import AVFoundation
import Flutter

/// [iOS Web 服务后台保活 | 2026-10-07]（方案 C+A，用户已批准）
///
/// ## 目的对应原版 Android
/// 原版 `WebService.kt:76` 的 `useWakeLock`（默认关）用 `PARTIAL_WAKE_LOCK`
/// 防 CPU/Wi-Fi 睡眠（见 `docs/WEB_SERVICE_KEEPALIVE_SURVEY_20261007.md` §二.2）。
/// iOS 无前台服务 / WakeLock，平台等价物是 `UIBackgroundModes: audio`
/// （Info.plist 已声明）+ 后台播放近静音音频：Web 服务运行期间循环播放一段
/// **近静音** PCM，系统因音频后台模式不挂起进程，局域网浏览器可持续访问。
///
/// ## 近静音取舍（待实机验证）
/// 纯数字静音（全 0 采样）可能被系统识别为「无音频输出」而在锁屏后被掐，
/// 故生成低幅正弦（默认 200Hz / 4s / 振幅 0.02 ≈ -34dBFS，非 0 采样；
/// 4s × 200Hz = 整数周期，循环点无缝）。振幅经验区间 0.01~0.05：过低可能
/// 退化为数字静音、过高可闻；本值**待真机验证**（验收口径见调研报告 §五）。
/// 若实机仍被系统掐断，退路为上调振幅或插入周期性非静音帧（本批未实现）。
///
/// ## 会话与 NowPlaying
/// - 会话不切类别/模式（AppDelegate 已设 `.playback` + `.spokenAudio`，
///   切换会干扰听书/TTS），仅确保 `setActive(true)`（幂等）；被来电/Siri
///   中断时激活抛错 → 返回 false，上层回退「仅前台可用」。
/// - 停止时**不** `setActive(false)`：会话为进程共享资源，听书/TTS 可能正在
///   使用；停掉播放器后若确实无其它音频，系统会自然回收后台执行权。
/// - **不发布** MPNowPlayingInfoCenter（避免状态栏/控制中心出现「正在播放」
///   残留卡片）。注意冲突面：TTS/听书播放时 NowPlayingBridge 会发布自己的
///   metadata 并在 stopped 时清空；保活期间若有该发布，属 TTS 语义、与本类
///   无关（残留与否待实机验证）。
///
/// ## 与听书/TTS 共存
/// 决策在 Dart 侧（`WebKeepAliveService`）：真实音频播放时不下发启用、已启用
/// 则下发停止（让位），真实音频停止后自动恢复。本类只做「启/停静音循环」，
/// 不做播放来源判断（单一决策方，避免两端状态竞争）。
///
/// 通道：`legado/web_keepalive`，方法 `setEnabled{enabled: bool}` → `bool`
/// （true=静音音轨已运行/已停止；false=启动失败，Dart 侧记日志并回退提示）。
///
/// — 全栈工程师 ｜ 2026-10-07
@objc class WebKeepAlive: NSObject {
  static let shared = WebKeepAlive()

  /// Dart 侧通道（对齐 `WebKeepAliveService.channel`）
  static let channelName = "legado/web_keepalive"

  /// 近静音 PCM 默认参数（经验值，待实机验证）
  struct NearSilentSpec {
    /// 采样率（Hz，单声道 16bit）
    static let sampleRate: Double = 44_100
    /// 缓冲时长（秒）：4s × 200Hz = 800 个整周期，循环无相位跳变
    static let durationSeconds: Double = 4.0
    /// 正弦频率（Hz，低频、低可闻性）
    static let frequency: Double = 200
    /// 振幅（相对满刻度，≈ -34dBFS；报告建议 0.01~0.05，纯 0 可能被系统掐）
    static let amplitude: Double = 0.02
  }

  private var channel: FlutterMethodChannel?
  private var player: AVAudioPlayer?

  private override init() {
    super.init()
  }

  /// 在 AppDelegate 的引擎初始化回调中调用（进程内仅一次）
  func attach(messenger: FlutterBinaryMessenger) {
    guard channel == nil else { return }
    let ch = FlutterMethodChannel(name: WebKeepAlive.channelName, binaryMessenger: messenger)
    ch.setMethodCallHandler { [weak self] call, result in
      self?.handle(call: call, result: result)
    }
    channel = ch
  }

  /// 静音音轨当前是否在运行（诊断用）
  var isActive: Bool { player != nil }

  private func handle(call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard call.method == "setEnabled" else {
      result(FlutterMethodNotImplemented)
      return
    }
    let args = call.arguments as? [String: Any] ?? [:]
    let enabled = args["enabled"] as? Bool ?? false
    // 播放器操作与通道回调都在主线程（AVAudioPlayer 亲和主 runloop）
    DispatchQueue.main.async { [weak self] in
      guard let self = self else {
        result(false)
        return
      }
      result(enabled ? self.startKeepAlive() : self.stopKeepAlive())
    }
  }

  // MARK: - 启停

  /// 启动静音循环；返回 false 表示保活不可用（上层回退「仅前台可用」）
  private func startKeepAlive() -> Bool {
    if player != nil { return true } // 幂等：Dart 侧已去重，这里再兜一层
    do {
      // 仅激活会话，不改类别/模式（AppDelegate 已配置 playback/spokenAudio）
      try AVAudioSession.sharedInstance().setActive(true)
      let data = WebKeepAlive.makeNearSilentWavData()
      let p = try AVAudioPlayer(data: data)
      p.numberOfLoops = -1
      p.volume = 1.0 // 近静音由采样振幅承担（缓冲非 0，系统/路由可见真实音频）
      p.prepareToPlay()
      guard p.play() else {
        NSLog("[WebKeepAlive] AVAudioPlayer.play() 返回 false，保活未生效")
        return false
      }
      player = p
      NSLog(
        "[WebKeepAlive] 保活启动：近静音循环 %.0fHz/%.0fs/振幅%.2f",
        WebKeepAlive.NearSilentSpec.frequency, WebKeepAlive.NearSilentSpec.durationSeconds,
        WebKeepAlive.NearSilentSpec.amplitude)
      return true
    } catch {
      NSLog("[WebKeepAlive] 保活启动失败（回退仅前台可用）: \(error)")
      player = nil
      return false
    }
  }

  /// 停止静音循环（不 deactivate 会话，见类注释）
  private func stopKeepAlive() -> Bool {
    if let p = player {
      p.stop()
      player = nil
      NSLog("[WebKeepAlive] 保活已停止")
    }
    return true
  }

  // MARK: - 近静音 PCM（纯函数，供 RunnerTests 校验）

  /// 生成近静音 WAV（单声道 16bit）：44 字节 RIFF/WAVE 头 + 低幅正弦采样
  static func makeNearSilentWavData(
    durationSeconds: Double = WebKeepAlive.NearSilentSpec.durationSeconds,
    sampleRate: Double = WebKeepAlive.NearSilentSpec.sampleRate,
    frequency: Double = WebKeepAlive.NearSilentSpec.frequency,
    amplitude: Double = WebKeepAlive.NearSilentSpec.amplitude
  ) -> Data {
    let frameCount = max(1, Int(durationSeconds * sampleRate))
    let bitsPerSample = 16
    let channels = 1
    let byteRate = Int(sampleRate) * channels * bitsPerSample / 8
    let blockAlign = channels * bitsPerSample / 8
    let dataSize = frameCount * blockAlign

    var data = Data(capacity: 44 + dataSize)
    data.append(contentsOf: Array("RIFF".utf8))
    data.appendLE(UInt32(36 + dataSize))
    data.append(contentsOf: Array("WAVE".utf8))
    data.append(contentsOf: Array("fmt ".utf8))
    data.appendLE(UInt32(16)) // fmt 块长度
    data.appendLE(UInt16(1)) // PCM
    data.appendLE(UInt16(channels))
    data.appendLE(UInt32(sampleRate))
    data.appendLE(UInt32(byteRate))
    data.appendLE(UInt16(blockAlign))
    data.appendLE(UInt16(bitsPerSample))
    data.append(contentsOf: Array("data".utf8))
    data.appendLE(UInt32(dataSize))

    let clamped = min(max(amplitude, 0.0), 1.0)
    let scale = clamped * Double(Int16.max)
    for i in 0 ..< frameCount {
      let phase = 2.0 * Double.pi * frequency * Double(i) / sampleRate
      let sample = Int16((sin(phase) * scale).rounded())
      data.appendLE(sample)
    }
    return data
  }
}

private extension Data {
  /// 追加小端 UInt16（WAV 头字段）
  mutating func appendLE(_ value: UInt16) {
    append(UInt8(truncatingIfNeeded: value))
    append(UInt8(truncatingIfNeeded: value >> 8))
  }

  /// 追加小端 UInt32（WAV 头字段）
  mutating func appendLE(_ value: UInt32) {
    append(UInt8(truncatingIfNeeded: value))
    append(UInt8(truncatingIfNeeded: value >> 8))
    append(UInt8(truncatingIfNeeded: value >> 16))
    append(UInt8(truncatingIfNeeded: value >> 24))
  }

  /// 追加小端 Int16（PCM 采样）
  mutating func appendLE(_ value: Int16) {
    appendLE(UInt16(bitPattern: value))
  }
}
