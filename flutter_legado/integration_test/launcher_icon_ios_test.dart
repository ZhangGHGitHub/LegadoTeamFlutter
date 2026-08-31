// iOS 运行时换图标验证（Bug1 证据采集 + 常驻回归门禁）
//
// 背景：真机点"更换图标"提示"当前平台或系统版本不支持"。静态核查确认
// LauncherIconBridge / AppDelegate 注册 / Info.plist CFBundleAlternateIcons /
// AlternateIcons 资源全部正确后，本测试在 iOS 模拟器上捕获真实运行时异常，
// 区分两类根因：
//   - MissingPluginException → 原生通道未注册（AppDelegate 接线问题）；
//   - PlatformException(LAUNCHER_ICON_ERROR) → setAlternateIconName 被拒
//     （code/message 即 UIKit 拒绝原因）。
//
// 运行方式（CI ios-build.yml；本地 macOS）：
//   flutter test integration_test/launcher_icon_ios_test.dart -d <模拟器UDID>
//
// 说明：
//   - iOS 每次启动仅允许切换一次图标，故本测试只发起一次真实 set（icon1）；
//     第二次 LauncherIconService.setIcon 调用仅打印实际拒绝原因（不参与断言）。
//   - 本文件位于 integration_test/，不会被 `flutter test` 自动拾取。

import 'dart:io';

import 'package:flutter/foundation.dart';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:flutter_legado/src/services/launcher_icon_service.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  test('iOS 换图标：通道可达且 set 成功', () async {
    if (!Platform.isIOS) {
      debugPrint('[LauncherIconTest] SKIP: 非 iOS 平台');
      return;
    }

    // 直接走裸通道（LauncherIconService.setIcon 会吞掉异常细节），
    // 捕获完整异常供 CI 日志取证
    final channel = const MethodChannel('legado/launcher_icon');
    Object? error;
    try {
      await channel.invokeMethod('set', <String, Object>{'icon': 'icon1'});
    } catch (e) {
      error = e;
    }

    if (error == null) {
      debugPrint('[LauncherIconTest] set icon1 → OK');
    } else {
      debugPrint('[LauncherIconTest] set icon1 → FAILED: '
          'type=${error.runtimeType} value=$error');
      if (error is PlatformException) {
        debugPrint(
          '[LauncherIconTest]   code=${error.code} message=${error.message}',
        );
      }
    }

    expect(
      error,
      isNull,
      reason: 'set 应成功；实际异常: $error'
          '（MissingPluginException = 原生通道未注册；'
          'PlatformException = setAlternateIconName 被拒，见上方 code/message）',
    );

    // 仅取证：iOS 每次启动限切换一次，第二次调用预期被 UIKit 拒绝——
    // 打印真实拒绝原因（断言会耦合平台行为细节，故只打印不断言）。
    final second = await LauncherIconService.setIcon('iconMain');
    debugPrint(
      '[LauncherIconTest] 第二次 set（预期被拒）: ok=${second.ok} '
          'message=${second.message}',
    );
  });
}
