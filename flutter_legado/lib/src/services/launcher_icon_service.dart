import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 切换结果：`ok=false` 时 [message] 携带失败原因，供 UI 展示真实错误
/// （此前统一返回 bool，UI 只能显示笼统的"当前平台或系统版本不支持"）。
class LauncherIconResult {
  const LauncherIconResult({required this.ok, this.message});

  final bool ok;
  final String? message;
}

/// 桌面启动图标切换服务（对齐原版 LauncherIconHelp.changeIcon）。
///
/// - Android：原生侧经 PackageManager.setComponentEnabledSetting 切换
///   manifest 中默认禁用的 Launcher1~6 Activity（API 26+，低于此拒绝）；
/// - iOS：原生侧经 UIApplication.setAlternateIconName 切换
///   CFBundleAlternateIcons 声明的变体（每次启动限一次，下次启动生效）；
/// - 其他平台（Windows 桌面端等）：无运行时换图标能力，返回失败。
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

  /// 切换桌面图标，返回 [LauncherIconResult]。
  ///
  /// `ok=false` 时 [LauncherIconResult.message] 携带具体原因：
  /// - Android API 26 以下："Android 8.0 以下不支持更换图标"；
  /// - iOS 原生拒绝（如本次启动已切换过一次）：UIKit 本地化错误描述；
  /// - 通道未注册：MissingPluginException 信息。
  static Future<LauncherIconResult> setIcon(String icon) async {
    if (!isSupported) {
      return const LauncherIconResult(
        ok: false,
        message: '当前平台不支持运行时换图标',
      );
    }
    try {
      await _channel.invokeMethod('set', <String, Object>{'icon': icon});
      return const LauncherIconResult(ok: true);
    } on PlatformException catch (e) {
      // 原生侧拒绝（Android API<26 / iOS setAlternateIconName 错误）
      final msg = e.message ?? '原生侧拒绝切换图标';
      debugPrint('[LauncherIcon] PlatformException: ${e.code} $msg');
      return LauncherIconResult(ok: false, message: msg);
    } on MissingPluginException catch (e) {
      // 通道无实现（原生桥未注册）
      debugPrint('[LauncherIcon] MissingPluginException: ${e.message}');
      return LauncherIconResult(
        ok: false,
        message: '原生图标通道未注册：${e.message}',
      );
    } catch (e) {
      debugPrint('[LauncherIcon] set failed: $e');
      return LauncherIconResult(ok: false, message: '$e');
    }
  }
}
