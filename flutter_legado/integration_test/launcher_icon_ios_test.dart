// iOS 运行时换图标验证（Bug1 证据采集 + 常驻回归门禁）
//
// 背景：真机点"更换图标"提示"当前平台或系统版本不支持"。静态核查确认
// LauncherIconBridge / AppDelegate 注册 / Info.plist CFBundleAlternateIcons /
// AlternateIcons 资源全部正确后，本测试在 iOS 模拟器上验证运行时行为。
//
// 回归门禁（断言，CI 必须通过）：
//   - status 方法可达 → AppDelegate 通道接线完好
//     （MissingPluginException = 接线断裂）；
//   - canSet == true → 已安装 bundle 磁盘 Info.plist 的 CFBundleAlternateIcons
//     声明 launcher1~6（setAlternateIconName 的前提）；
//   - altIconNames == [launcher1=launcher1 … launcher6=launcher6]
//     → 已安装 plist 的 CFBundleAlternateIcons 各条目 CFBundleIconName
//     与键名一致（appiconset 名）；系统按 Assets.car appiconset 名解析，
//     与主图标 AppIcon.appiconset 同一条路径——UIImage(named:) 探针
//     不覆盖该路径（2.0.138 真机 -54 已证），故直接断言声明结构；
//   - carHasAllLaunchers == [launcher1…6] → 已安装 Assets.car 字节级含
//     全部变体 appiconset 名（第五轮：变体资产真实入包门禁，与 CI
//     静态 car 校验互证）。
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

    // ── 1) 回归门禁：status（原生主线程异步应答，UIKit 读取需主线程）──
    // invokeMethod 不指定泛型 T（避免按赋值目标推断为 Map<String, Object?>
    // 而平台实际返回 _Map<Object?, Object?> 导致 cast 失败），改动态取值。
    Object? statusResult;
    Object? statusError;
    try {
      statusResult = await channel.invokeMethod<dynamic>('status');
    } catch (e) {
      statusError = e;
    }
    debugPrint(
      '[LauncherIconTest] status → ${statusError == null ? 'OK: $statusResult' : 'FAILED: $statusError'}',
    );
    expect(
      statusError,
      isNull,
      reason: 'status 通道应可达；实际异常: $statusError'
          '（MissingPluginException = AppDelegate 接线断裂）',
    );
    final statusMap = (statusResult as Map?) ?? <Object?, Object?>{};
    // 诊断证据（CI 失败时用于定位 plist 缺失来源）：
    //   diskAltKeys/diskBytes = 已安装 bundle 磁盘 Info.plist 解析结果；
    //   altKeys/infoDictKeyCount/hasBundleId = infoDictionary 运行时读取，
    //   与磁盘对照可区分「安装副本缺声明」与「Foundation 运行时读取异常」。
    debugPrint(
      '[LauncherIconTest] 证据 → diskAltKeys=${statusMap['diskAltKeys']}'
      ' diskBytes=${statusMap['diskBytes']}'
      ' altIconNames=${statusMap['altIconNames']}'
      ' infoDictKeyCount=${statusMap['infoDictKeyCount']}'
      ' hasBundleId=${statusMap['hasBundleId']}'
      ' altKeys=${statusMap['altKeys']}'
      ' bundlePath=${statusMap['bundlePath']}',
    );
    // 第五轮真机自检字段（iOS 版本 / 平台能力 / car 变体资产）：
    // CI 失败时用于区分「安装副本缺资产」与「系统回归」。
    debugPrint(
      '[LauncherIconTest] 自检 → systemVersion=${statusMap['systemVersion']}'
      ' supportsAlt=${statusMap['supportsAlt']}'
      ' carHasAllLaunchers=${statusMap['carHasAllLaunchers']}',
    );
    final canSet = statusMap['canSet'];
    expect(
      canSet,
      true,
      reason: '已安装 bundle 磁盘 Info.plist CFBundleAlternateIcons 应声明 launcher1~6；'
          'diskAltKeys=[] → 安装副本 plist 缺声明（构建/安装链路问题）；'
          'diskAltKeys 有值但 canSet=false → 键名不匹配',
    );

    // ── 1b) 回归门禁：altIconNames（CFBundleIconName 声明结构完整性）──
    // setAlternateIconName 按 CFBundleIconName = Assets.car appiconset 名
    // （launcher1.appiconset…）解析变体图标——与主图标 AppIcon.appiconset
    // 同一条已验证可用的路径；UIImage(named:) 探针不覆盖该路径
    // （2.0.138 真机 -54 已证），故直接断言已安装 plist 的声明结构：
    // 各键的 CFBundleIconName 值必须等于键名，否则真机解析失败。
    final altIconNames = statusMap['altIconNames'];
    expect(
      altIconNames,
      [
        'launcher1=launcher1',
        'launcher2=launcher2',
        'launcher3=launcher3',
        'launcher4=launcher4',
        'launcher5=launcher5',
        'launcher6=launcher6',
      ],
      reason: 'CFBundleAlternateIcons 各条目 CFBundleIconName 应与键名一致'
          '（appiconset 名）；实际=$altIconNames → 声明缺失或值不匹配，'
          '真机 setAlternateIconName 将报 OSStatus -54',
    );

    // ── 1c) 回归门禁：carHasAllLaunchers（变体资产真实入包）──
    // Assets.car 字节级扫描 launcher1~6 appiconset 名——声明齐全但资产
    // 未编入 car，真机同样 -54；与 CI 静态 car 校验构成双门禁。
    final carNames = statusMap['carHasAllLaunchers'];
    expect(
      (carNames is List) ? carNames.length : 0,
      6,
      reason: '已安装 Assets.car 应含 launcher1~6 全部 appiconset；'
          '实际=$carNames → 变体资产未入包（actool/构建设置回归）',
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
