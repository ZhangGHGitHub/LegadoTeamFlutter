import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:screen_brightness/screen_brightness.dart';

/// 系统亮度控制
/// 
/// 通过平台通道访问 Android/iOS 系统亮度设置
class SystemBrightness {
  static const MethodChannel _channel = MethodChannel('io.legado.app/brightness');

  /// 获取当前亮度 (0.0 - 1.0)
  ///
  /// [iOS 轨 P2] iOS 仅允许应用窗口亮度（系统亮度只读），走
  /// screen_brightness 插件的 application 接口；Android 保持原通道。
  static Future<double> getBrightness() async {
    if (Platform.isIOS) {
      try {
        return await ScreenBrightness().application;
      } catch (e) {
        debugPrint('获取应用亮度失败: $e');
        return 0.5;
      }
    }
    try {
      final int brightness = await _channel.invokeMethod('getSystemBrightness');
      return brightness / 255.0; // Android 返回 0-255，转换为 0.0-1.0
    } on PlatformException catch (e) {
      debugPrint('获取系统亮度失败: ${e.message}');
      return 0.5; // 默认值
    }
  }

  /// 设置亮度 (0.0 - 1.0)
  static Future<void> setBrightness(double brightness) async {
    if (Platform.isIOS) {
      try {
        await ScreenBrightness().setApplicationScreenBrightness(brightness);
      } catch (e) {
        debugPrint('设置应用亮度失败: $e');
      }
      return;
    }
    try {
      final int value = (brightness * 255).round().clamp(0, 255);
      await _channel.invokeMethod('setSystemBrightness', value);
    } on PlatformException catch (e) {
      debugPrint('设置系统亮度失败: ${e.message}');
    }
  }

  /// 检查是否支持亮度调节
  static Future<bool> isSupported() async {
    if (Platform.isIOS) return true; // 应用亮度可调
    try {
      final bool supported = await _channel.invokeMethod('isBrightnessSupported');
      return supported;
    } on PlatformException catch (e) {
      debugPrint('检查亮度支持失败: ${e.message}');
      return false;
    }
  }

  /// 获取亮度模式（自动/手动）
  static Future<bool> isAutoBrightness() async {
    try {
      final bool auto = await _channel.invokeMethod('isAutoBrightness');
      return auto;
    } on PlatformException catch (e) {
      debugPrint('获取自动亮度状态失败: ${e.message}');
      return false;
    }
  }

  /// 设置亮度模式（自动/手动）
  static Future<void> setAutoBrightness(bool auto) async {
    try {
      await _channel.invokeMethod('setAutoBrightness', auto);
    } on PlatformException catch (e) {
      debugPrint('设置自动亮度失败: ${e.message}');
    }
  }
}
