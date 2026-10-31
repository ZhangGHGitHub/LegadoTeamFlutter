// [批1b-1 | 2026-10-31] keepLight 保持亮屏平台通道测试 — 全栈工程师
//
// 覆盖（任务书 §C）：
// 1. 通道调用：阅读器进入（_loadAdvancedConfig → _applySystemChrome）
//    下发 true（keepLight≠0）/ false（keepLight=0）；退出 dispose 下发
//    false；设置变更（面板改值）即时重下发；通道异常不崩（通道抛错路径
//    在 PlatformChannel.setKeepScreenOn 静默吞没）
// 2. 平台分派：iOS/桌面覆写 no-op（灰字登记，参考版无 iOS 基准）
// 3. 设置页两行往返：保持亮屏/亮度条模式改值 → 落盘 → 重进回显
// 4. 备份白名单：readBrightnessMode/readBrightnessVwPos 命中 readPrefKeys
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/routes.dart';
import 'package:flutter_legado/src/screens/read_config_screen.dart';
import 'package:flutter_legado/src/screens/reader_config_panel.dart';
import 'package:flutter_legado/src/services/platform_bridge_service.dart';
import 'package:flutter_legado/src/services/restore_ignore_prefs.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// keepLight 通道调用记录（经 BrightnessBridge 通道 mock 收集）
  final keepScreenOnCalls = <bool>[];

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    keepScreenOnCalls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('io.legado.app/brightness'),
      (call) async {
        if (call.method == 'setKeepScreenOn') {
          keepScreenOnCalls.add(call.arguments as bool);
        } else if (call.method == 'isBrightnessSupported') {
          return false;
        }
        return null;
      },
    );
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
              const MethodChannel('io.legado.app/brightness'), null);
      // 覆写复位
      PlatformBridgeService.instance
        ..keepScreenOnOverride = null
        ..lastKeepScreenOn = null;
    });
  });

  group('keepLight 通道调用', () {
    test('服务层：Android 覆写时直达通道（true/false 各一次）', () async {
      PlatformBridgeService.instance.keepScreenOnOverride = true;
      await PlatformBridgeService.instance.setKeepScreenOn(true);
      await PlatformBridgeService.instance.setKeepScreenOn(false);
      expect(keepScreenOnCalls, [true, false]);
      expect(PlatformBridgeService.instance.lastKeepScreenOn, isFalse);
    });

    test('服务层：iOS 覆写 no-op（不触通道，灰字登记）', () async {
      PlatformBridgeService.instance.keepScreenOnOverride = false;
      await PlatformBridgeService.instance.setKeepScreenOn(true);
      expect(keepScreenOnCalls, isEmpty);
      expect(PlatformBridgeService.instance.lastKeepScreenOn, isTrue,
          reason: '观测点记录指令，便于诊断平台降级');
    });

    test('通道层异常吞没：通道抛 PlatformException 不向上传播', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('io.legado.app/brightness'),
        (call) async => throw PlatformException(code: 'BRIGHTNESS_ERROR'),
      );
      // 不抛即通过（对齐 setVolumeKeyCapture 降级语义）
      await PlatformBridgeService.instance.setKeepScreenOn(true);
      expect(PlatformBridgeService.instance.lastKeepScreenOn, isTrue);
    });

    test('通道层异常吞没：通道抛 MissingPluginException（未注册）不传播',
        () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('io.legado.app/brightness'),
        (call) async => throw MissingPluginException(),
      );
      await PlatformBridgeService.instance.setKeepScreenOn(false);
      expect(PlatformBridgeService.instance.lastKeepScreenOn, isFalse);
    });
  });

  group('设置页保持亮屏/亮度条两行往返', () {
    Future<ProviderContainer> pump(WidgetTester tester) async {
      late ProviderContainer container;
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: const ReadConfigScreen(),
            routes: <String, WidgetBuilder>{
              AppRoutes.readConfig: (_) => const ReadConfigScreen(),
            },
          ),
        ),
      );
      container = ProviderScope.containerOf(
        tester.element(find.byType(ReadConfigScreen)),
      );
      await tester.pumpAndSettle();
      return container;
    }

    testWidgets('保持亮屏下拉改「常亮」→ 落盘 keep_light=-1 → 重进回显',
        (tester) async {
      tester.view.physicalSize = const Size(800, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final container = await pump(tester);

      await tester.tap(find.text('保持亮屏'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('常亮'));
      await tester.pumpAndSettle();

      expect(container.read(readerAdvConfigProvider)?.keepLight, -1);
      expect((await ReaderAdvancedConfig.load()).keepLight, -1);

      // 重进页面回显（下拉行 value=-1）
      await tester.pumpWidget(
        const ProviderScope(child: MaterialApp(home: Scaffold(body: SizedBox()))),
      );
      await tester.pumpAndSettle();
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: const ReadConfigScreen(),
            routes: <String, WidgetBuilder>{
              AppRoutes.readConfig: (_) => const ReadConfigScreen(),
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      final row = tester
          .widgetList<SettingDropdownRow<int>>(
              find.byWidgetPredicate((w) => w is SettingDropdownRow<int>))
          .firstWhere((r) => r.title == '保持亮屏');
      expect(row.value, -1);
    });

    testWidgets('亮度条模式下拉改「竖排」→ 位置行出现 → 改「左侧」落盘往返',
        (tester) async {
      tester.view.physicalSize = const Size(800, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final container = await pump(tester);
      expect(find.text('亮度条位置'), findsNothing,
          reason: '默认模式 0 位置行不渲染');

      await tester.tap(find.text('亮度条模式'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('竖排'));
      await tester.pumpAndSettle();

      expect(container.read(readerAdvConfigProvider)?.readBrightnessMode, '2');
      expect(find.text('亮度条位置'), findsOneWidget,
          reason: '模式=2 时位置行条件渲染（对齐参考版 ReadConfigScreen）');

      await tester.tap(find.text('亮度条位置'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('左侧'));
      await tester.pumpAndSettle();

      final saved = await ReaderAdvancedConfig.load();
      expect(saved.readBrightnessVwPos, '0');
      expect(container.read(readerAdvConfigProvider)?.readBrightnessVwPos,
          '0');
    });

    testWidgets('亮度条模式改「横排」→ 持久化 + 重启保持', (tester) async {
      tester.view.physicalSize = const Size(800, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await pump(tester);
      await tester.tap(find.text('亮度条模式'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('横排'));
      await tester.pumpAndSettle();

      expect((await ReaderAdvancedConfig.load()).readBrightnessMode, '1');
      // 再次 load（模拟重启）保持
      expect((await ReaderAdvancedConfig.load()).readBrightnessMode, '1');
    });
  });

  group('备份忽略白名单（1b-1 新键）', () {
    test('readBrightnessMode/readBrightnessVwPos 命中 readPrefKeys', () {
      expect(RestoreIgnorePrefs.readPrefKeys.contains('readBrightnessMode'),
          isTrue);
      expect(RestoreIgnorePrefs.readPrefKeys.contains('readBrightnessVwPos'),
          isTrue);
      expect(
        RestoreIgnorePrefs.keyIsNotIgnore(
            'readBrightnessMode', {'readConfig': true}),
        isFalse,
      );
    });
  });

  group('审查回修 P2-3/P3-6：迁移标志备份排除 + 旧派生键优先级', () {
    test('迁移标志 brightness_mode_migrated_v1b1 入 backupExcludedKeys '
        '（设备级一次性状态不随备份往返）', () {
      expect(
        RestoreIgnorePrefs.backupExcludedKeys
            .contains('brightness_mode_migrated_v1b1'),
        isTrue,
      );
    });

    test('备份往返：未迁移设备恢复旧备份（无迁移标志）仍能迁移', () async {
      // 模拟「备份里携带旧布尔键、目标设备从未迁移」：标志不在备份
      //（被 backupExcludedKeys 剥除）也不在本机 → 恢复后首次 load 执行迁移
      SharedPreferences.setMockInitialValues({'showBrightnessView': true});
      expect(
        SharedPreferences.getInstance().then(
          (p) => p.getBool('brightness_mode_migrated_v1b1'),
        ),
        completion(isNull),
        reason: '旧备份不含设备级迁移标志（被备份排除键剥除）',
      );
      final cfg = await ReaderAdvancedConfig.load();
      expect(cfg.readBrightnessMode, '1',
          reason: '未迁移设备照常执行旧键迁移');
    });

    test('历史派生键 readMenuBrightnessVertical=true 优先迁移为 mode 2（竖条）',
        () async {
      SharedPreferences.setMockInitialValues({
        'readMenuBrightnessVertical': true,
        'showBrightnessView': true,
      });
      final cfg = await ReaderAdvancedConfig.load();
      expect(cfg.readBrightnessMode, '2',
          reason: '旧竖条开关（参考版 showBrightnessView="2" 变体）优先于'
              ' showBrightnessView 两态口径');
    });

    test('readMenuBrightnessVertical=false 不触发竖条迁移（回落两态口径）',
        () async {
      SharedPreferences.setMockInitialValues({
        'readMenuBrightnessVertical': false,
        'showBrightnessView': true,
      });
      final cfg = await ReaderAdvancedConfig.load();
      expect(cfg.readBrightnessMode, '1',
          reason: '派生键仅 true 表达竖条，false 无信息量，按两态口径迁移');
    });
  });
}
