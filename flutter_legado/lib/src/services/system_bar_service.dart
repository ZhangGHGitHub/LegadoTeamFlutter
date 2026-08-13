import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 系统栏（状态栏 / 导航栏）样式服务
///
/// 对齐 Android 原版 [BaseActivity.setupSystemBar] +
/// [AppConfig.isTransparentStatusBar] / [AppConfig.immNavigationBar]：
/// - 沉浸式状态栏开启：edge-to-edge + 透明状态栏，AppBar 背景延伸至状态栏区域
/// - 沉浸式状态栏关闭：使用原版 status_bar_bag（#19000000）实色状态栏
/// - 沉浸式导航栏开启：导航栏底色与底部 TabBar 一致
/// - 沉浸式导航栏关闭：导航栏底色加深（对标 ColorUtils.darkenColor）
///
/// Android 侧经 [MethodChannel] 同步 Window 属性，避免 MainActivity
/// onPostResume 覆盖 Dart 侧 SystemChrome 设置。
///
/// — Composer + UI ｜ 2026-08-14
class SystemBarService {
  SystemBarService._();

  static const MethodChannel _channel = MethodChannel('legado/system_bar');

  /// 原版 status_bar_bag（非沉浸式 + fullScreen 时的状态栏底色）
  static const Color statusBarBag = Color(0x19000000);

  /// 按当前主题与偏好应用系统栏样式
  static Future<void> apply({
    required bool transparentStatusBar,
    required bool immNavigationBar,
    required Color appBarColor,
    required Color navigationBarColor,
  }) async {
    final lightStatusBarIcons =
        ThemeData.estimateBrightnessForColor(appBarColor) == Brightness.light;

    final statusBarColor =
        transparentStatusBar ? Colors.transparent : statusBarBag;

    final navBarColor = immNavigationBar
        ? navigationBarColor
        : Color.alphaBlend(Colors.black26, navigationBarColor);

    final lightNavIcons =
        ThemeData.estimateBrightnessForColor(navBarColor) == Brightness.light;

    if (Platform.isAndroid) {
      if (transparentStatusBar) {
        await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
      } else {
        await SystemChrome.setEnabledSystemUIMode(
          SystemUiMode.manual,
          overlays: SystemUiOverlay.values,
        );
      }
    }

    final overlayStyle = SystemUiOverlayStyle(
      statusBarColor: statusBarColor,
      statusBarIconBrightness:
          lightStatusBarIcons ? Brightness.dark : Brightness.light,
      statusBarBrightness:
          lightStatusBarIcons ? Brightness.light : Brightness.dark,
      systemNavigationBarColor: navBarColor,
      systemNavigationBarIconBrightness:
          lightNavIcons ? Brightness.dark : Brightness.light,
      systemNavigationBarContrastEnforced: false,
    );

    SystemChrome.setSystemUIOverlayStyle(overlayStyle);

    if (Platform.isAndroid) {
      try {
        await _channel.invokeMethod<void>('apply', {
          'transparentStatusBar': transparentStatusBar,
          'immNavigationBar': immNavigationBar,
          'statusBarColor': statusBarColor.toARGB32(),
          'navigationBarColor': navBarColor.toARGB32(),
          'lightStatusBarIcons': lightStatusBarIcons,
        });
      } catch (e) {
        debugPrint('SystemBarService.apply 原生通道异常: $e');
      }
    }
  }
}
