import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 桌面启动图标切换服务（对齐原版 LauncherIconHelp.changeIcon）。
///
/// - Android：原生侧经 PackageManager.setComponentEnabledSetting 切换
///   manifest 中默认禁用的 Launcher1~6 Activity（API 26+，低于此拒绝）；
/// - iOS：原生侧经 UIApplication.setAlternateIconName 切换
///   CFBundleAlternateIcons 声明的变体（每次启动限一次，下次启动生效）；
/// - 其他平台（Windows 桌面端等）：无运行时换图标能力，返回 false。
/// — Qoder UI
class LauncherIconService {
  LauncherIconService._();

  static const MethodChannel _channel = MethodChannel('legado/launcher_icon');

  /// 可选值（对齐原版 arrays.xml icon_names）：iconMain / icon1~icon6。
  static const List<String> icons = [
    'iconMain', 'icon1', 'icon2', 'icon3', 'icon4', 'icon5', 'icon6',
  ];

  /// 当前平台是否支持运行时换图标（仅 Android / iOS）。
  static bool get isSupported =>
      defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.iOS;

  /// 是否为 iOS（切换成功后提示"重启后生效"用）。
  static bool get isIos => defaultTargetPlatform == TargetPlatform.iOS;

  /// 切换桌面图标，成功返回 true；平台不支持或原生拒绝返回 false。
  static Future<bool> setIcon(String icon) async {
    if (!isSupported) return false;
    try {
      await _channel.invokeMethod('set', <String, Object>{'icon': icon});
      return true;
    } on PlatformException catch (e) {
      // 原生侧拒绝（如 Android 8.0 以下）
      debugPrint('[LauncherIcon] PlatformException: ${e.code} ${e.message}');
      return false;
    } catch (e) {
      // 通道无实现或调用失败
      debugPrint('[LauncherIcon] set failed: $e');
      return false;
    }
  }
}
