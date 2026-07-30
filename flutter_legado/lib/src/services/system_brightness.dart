import 'package:flutter/services.dart';

/// 系统亮度控制
/// 
/// 通过平台通道访问 Android/iOS 系统亮度设置
class SystemBrightness {
  static const MethodChannel _channel = MethodChannel('io.legado.app/brightness');

  /// 获取当前系统亮度 (0.0 - 1.0)
  static Future<double> getBrightness() async {
    try {
      final int brightness = await _channel.invokeMethod('getSystemBrightness');
      return brightness / 255.0; // Android 返回 0-255，转换为 0.0-1.0
    } on PlatformException catch (e) {
      print('获取系统亮度失败: ${e.message}');
      return 0.5; // 默认值
    }
  }

  /// 设置系统亮度 (0.0 - 1.0)
  static Future<void> setBrightness(double brightness) async {
    try {
      final int value = (brightness * 255).round().clamp(0, 255);
      await _channel.invokeMethod('setSystemBrightness', value);
    } on PlatformException catch (e) {
      print('设置系统亮度失败: ${e.message}');
    }
  }

  /// 检查是否支持系统亮度调节
  static Future<bool> isSupported() async {
    try {
      final bool supported = await _channel.invokeMethod('isBrightnessSupported');
      return supported;
    } on PlatformException catch (e) {
      print('检查亮度支持失败: ${e.message}');
      return false;
    }
  }

  /// 获取亮度模式（自动/手动）
  static Future<bool> isAutoBrightness() async {
    try {
      final bool auto = await _channel.invokeMethod('isAutoBrightness');
      return auto;
    } on PlatformException catch (e) {
      print('获取自动亮度状态失败: ${e.message}');
      return false;
    }
  }

  /// 设置亮度模式（自动/手动）
  static Future<void> setAutoBrightness(bool auto) async {
    try {
      await _channel.invokeMethod('setAutoBrightness', auto);
    } on PlatformException catch (e) {
      print('设置自动亮度失败: ${e.message}');
    }
  }
}
