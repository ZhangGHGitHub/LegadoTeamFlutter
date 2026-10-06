import Flutter
import UIKit
import XCTest

@testable import Runner

class RunnerTests: XCTestCase {

  func testExample() {
    // If you add code to the Runner application, consider adding tests here.
    // See https://developer.apple.com/documentation/xctest for more information about using XCTest.
  }

  // MARK: - WebKeepAlive 近静音 PCM（纯函数用例 | 2026-10-07 Web 保活批）
  //
  // 覆盖 WebKeepAlive.makeNearSilentWavData 的 WAV 结构、非 0 采样与振幅
  // 约束、循环无缝前提。注意：本 target 未被 CI 执行（ios-build.yml 只做
  // build + 集成测试），本地 Xcode 可 `xcodebuild test` 手动跑；Dart 侧
  // 状态机由 test/unit/web_keep_alive_service_test.dart 门禁。

  /// WAV 头字段与总长度：44 字节头 + frames × 2 字节（单声道 16bit）
  func testNearSilentWavHeaderAndLength() {
    let sampleRate: Double = 44_100
    let seconds: Double = 1.0
    let frames = Int(sampleRate * seconds)
    let data = WebKeepAlive.makeNearSilentWavData(
      durationSeconds: seconds, sampleRate: sampleRate)

    XCTAssertEqual(data.count, 44 + frames * 2)
    XCTAssertEqual(ascii(data, 0, 4), "RIFF")
    XCTAssertEqual(ascii(data, 8, 4), "WAVE")
    XCTAssertEqual(ascii(data, 12, 4), "fmt ")
    XCTAssertEqual(ascii(data, 36, 4), "data")
    XCTAssertEqual(uint16LE(data, 20), 1, "PCM 格式标记")
    XCTAssertEqual(uint16LE(data, 22), 1, "单声道")
    XCTAssertEqual(uint32LE(data, 24), UInt32(sampleRate), "采样率")
    XCTAssertEqual(uint32LE(data, 34), 16, "16bit")
    XCTAssertEqual(uint32LE(data, 40), UInt32(frames * 2), "data 块长度")
    XCTAssertEqual(uint32LE(data, 4), UInt32(36 + frames * 2), "RIFF 块长度")
  }

  /// 近静音不是数字静音：存在非 0 采样，且峰值受设定振幅约束
  func testNearSilentSamplesNonZeroAndBounded() {
    let amplitude = 0.02
    let data = WebKeepAlive.makeNearSilentWavData(
      durationSeconds: 0.1, amplitude: amplitude)
    let frames = (data.count - 44) / 2
    XCTAssertEqual(frames, 4_410, "0.1s × 44100 = 4410 帧")

    var peak = 0
    var nonZero = 0
    for i in 0 ..< frames {
      let offset = data.startIndex + 44 + i * 2
      let lo = Int(data[offset])
      let hi = Int(data[offset + 1])
      let sample = Int(Int16(truncatingIfNeeded: lo | (hi << 8)))
      peak = max(peak, abs(sample))
      if sample != 0 { nonZero += 1 }
    }

    XCTAssertGreaterThan(nonZero, 0, "纯 0 数字静音可能被系统掐，必须为非 0 采样")
    let expectedPeak = Int((amplitude * 32767).rounded())
    XCTAssertLessThanOrEqual(peak, expectedPeak + 1, "峰值不应超过设定振幅")
    XCTAssertGreaterThan(peak, expectedPeak / 2, "峰值过低会退化为数字静音")
  }

  /// 循环无缝前提：缓冲时长 × 频率为整数周期（默认 4s × 200Hz = 800）
  func testNearSilentLoopIsWholeNumberOfCycles() {
    let cycles = WebKeepAlive.NearSilentSpec.durationSeconds
      * WebKeepAlive.NearSilentSpec.frequency
    XCTAssertEqual(cycles, cycles.rounded(), accuracy: 1e-9)
  }

  // MARK: - 小端读取辅助

  private func ascii(_ data: Data, _ offset: Int, _ length: Int) -> String {
    let start = data.startIndex + offset
    return String(decoding: data[start ..< start + length], as: UTF8.self)
  }

  private func uint16LE(_ data: Data, _ offset: Int) -> UInt16 {
    let start = data.startIndex + offset
    let bytes = [UInt8](data[start ..< start + 2])
    return UInt16(bytes[0]) | UInt16(bytes[1]) << 8
  }

  private func uint32LE(_ data: Data, _ offset: Int) -> UInt32 {
    let start = data.startIndex + offset
    let bytes = [UInt8](data[start ..< start + 4])
    return UInt32(bytes[0]) | UInt32(bytes[1]) << 8
      | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
  }

}
