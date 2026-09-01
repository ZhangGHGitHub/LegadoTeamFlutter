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

  /// 取真机自检（仅 iOS）：系统版本 / plist 声明 / car 变体资产。
  ///
  /// 用于失败时一次性回报取证（-54 第五轮：旁载签名后的落盘 bundle
  /// 是唯一未验证环节，iOS 26.1+ 公开 API 回归为另一嫌疑）。
  static Future<String> _diagnostics() async {
    try {
      final res = await _channel
          .invokeMethod<dynamic>('status')
          .timeout(const Duration(seconds: 3));
      if (res is Map) {
        final ver = res['systemVersion'] ?? '?';
        final canSet = res['canSet'];
        final car = res['carHasAllLaunchers'];
        final carCount = (car is List) ? car.length : 0;
        return 'iOS $ver / 声明${canSet == true ? '✓' : '✗'} / car $carCount/6';
      }
    } catch (_) {
      // 自检通道异常不影响主流程
    }
    return '自检不可用';
  }

  /// 切换桌面图标，返回 [LauncherIconResult]。
  ///
  /// `ok=false` 时 [LauncherIconResult.message] 携带具体原因：
  /// - Android API 26 以下："Android 8.0 以下不支持更换图标"；
  /// - iOS 原生拒绝（如本次启动已切换过一次）：UIKit 本地化错误描述 +
  ///   错误域/码 + 真机自检结果（iOS 版本 / 声明 / car 资产，取证用）；
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
      final d = (e.details is Map) ? e.details as Map : <String, Object?>{};
      debugPrint('[LauncherIcon] PlatformException: ${e.code} $msg details=$d');
      // iOS 失败时附带真机自检，一次回报即可定位（旁载 bundle vs 系统回归）
      final extra = isIos ? ' | ${await _diagnostics()}' : '';
      final note = d['note'] is String ? ' | ${d['note']}' : '';
      return LauncherIconResult(
        ok: false,
        message: '$msg | domain=${d['domain']} code=${d['code']}$extra$note',
      );
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
