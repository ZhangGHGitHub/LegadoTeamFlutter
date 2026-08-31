// iOS 运行时换图标验证（Bug1 证据采集 + 常驻回归门禁）
//
// 背景：真机点"更换图标"提示"当前平台或系统版本不支持"。静态核查确认
// LauncherIconBridge / AppDelegate 注册 / Info.plist CFBundleAlternateIcons /
// AlternateIcons 资源全部正确后，本测试在 iOS 模拟器上验证运行时行为。
//
// 回归门禁（断言，CI 必须通过）：
//   - status 方法可达 → AppDelegate 通道接线完好
//     （MissingPluginException = 接线断裂）；
//   - canSetApplicationIconsNamed(launcher1~6) == true → Info.plist
//     CFBundleAlternateIcons 声明与 AlternateIcons 资源完整。
//
// 仅取证（不断言，平台行为随版本/模拟器而异）：
//   - 真实 set icon1：iOS 模拟器的 setAlternateIconName completion
//     不回调（已知限制），故带超时守护只记录结果；真机切换成败以人工验收为准。
//
// 运行方式（CI ios-build.yml；本地 macOS）：
//   flutter test integration_test/launcher_icon_ios_test.dart -d <模拟器UDID>
//
// 说明：
//   - iOS 每次启动仅允许切换一次图标，故本测试最多发起一次真实 set；
//   - 本文件位于 integration_test/，不会被 `flutter test` 自动拾取。

import 'dart:io';

import 'package:flutter/foundation.dart';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  test('iOS 换图标：通道接线 + 变体声明（模拟器回归门禁）', () async {
    if (!Platform.isIOS) {
      debugPrint('[LauncherIconTest] SKIP: 非 iOS 平台');
      return;
    }

    final channel = const MethodChannel('legado/launcher_icon');

    // ── 1) 回归门禁：status（原生同步应答，无 UIKit 异步）──
    Map<String, Object?>? status;
    Object? statusError;
    try {
      status = await channel.invokeMethod('status');
    } catch (e) {
      statusError = e;
    }
    debugPrint(
      '[LauncherIconTest] status → ${statusError == null ? 'OK: $status' : 'FAILED: $statusError'}',
    );
    expect(
      statusError,
      isNull,
      reason: 'status 通道应可达；实际异常: $statusError'
          '（MissingPluginException = AppDelegate 接线断裂）',
    );
    expect(
      status?['canSet'],
      true,
      reason: 'Info.plist CFBundleAlternateIcons 应声明 launcher1~6；'
          'canSet=false 表示声明或 AlternateIcons 资源缺失',
    );

    // ── 2) 仅取证：真实 set icon1（模拟器 completion 不回调 → 超时守护，不断言）──
    Object? setError;
    try {
      await channel
          .invokeMethod('set', <String, Object>{'icon': 'icon1'})
          .timeout(const Duration(seconds: 8));
    } catch (e) {
      setError = e;
    }
    debugPrint(
      '[LauncherIconTest] set icon1 → '
      '${setError == null ? 'OK（UIKit 已确认）' : '无回调/被拒: $setError'}',
    );
  });
}
