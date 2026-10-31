// [批1b-1 | 2026-10-31] 亮度条模式三档 + 位置行为测试 — 全栈工程师
//
// 覆盖（docs/SETTINGS_READ_PAGE_PLAN_20261031.md §六 1b 行）：
// 1. 模式 0/1/2 显隐：横条（ReaderBottomBar 亮度行）模式='1' 渲染、
//    '0'/'2' 不渲染；竖条（ReaderMenuPanel）模式='2' 渲染、其余不渲染
// 2. 竖条左右位置：brightnessVwPos '0' 贴左缘 / '1' 贴右缘
// 3. 旧布尔键迁移：showBrightnessView=true→'1'（横条）/false→'0'，
//    readMenuBrightnessVwPos left/right→'0'/'1'；迁移一次性（幂等）、
//    迁移后旧键不再消费（save 不写旧键）
// 4. 重启保持：save → load 往返幂等
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/screens/reader_config_panel.dart';
import 'package:flutter_legado/src/services/system_brightness.dart';
import 'package:flutter_legado/src/widgets/reader/reader_bottom_bar.dart';
import 'package:flutter_legado/src/widgets/reader/reader_menu_panel.dart';

import '../mocks/mocks.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    // 桌面/测试宿主无亮度通道：SystemBrightness.isSupported 抛
    // MissingPluginException → 横条/竖条内部降级隐藏。为断言「结构渲染」，
    // stub 通道返回支持（值读取回落默认 0.5）。
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('io.legado.app/brightness'),
      (call) async {
        switch (call.method) {
          case 'isBrightnessSupported':
            return true;
          case 'isAutoBrightness':
            return false;
          case 'getSystemBrightness':
            return 128;
          default:
            return null;
        }
      },
    );
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
              const MethodChannel('io.legado.app/brightness'), null);
      SystemBrightness.platformIsIOS = () => false;
    });
  });

  /// 横条宿主（ReaderBottomBar 需 Positioned → Stack）
  Widget bottomBarHarness(ProviderContainer container, String mode) {
    return UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: Scaffold(
          body: Stack(
            children: [
              ReaderBottomBar(
                onOpenCatalog: () {},
                onOpenSettings: () {},
                onOpenAdvancedConfig: () {},
                onOpenContentSearch: () {},
                onReadAloud: () {},
                brightnessMode: mode,
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 竖条宿主（ReaderMenuPanel 需 Positioned.fill → Stack）
  Widget menuPanelHarness(ProviderContainer container,
      {required String mode, required String pos}) {
    return UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: Scaffold(
          body: Stack(
            children: [
              ReaderMenuPanel(
                visible: true,
                onBack: () {},
                onAddBookmark: () {},
                onOpenCatalog: () {},
                onOpenSettings: () {},
                onOpenAdvancedConfig: () {},
                onOpenContentSearch: () {},
                onReadAloud: () {},
                onToggleAutoPage: () {},
                onOpenReplaceRules: () {},
                brightnessMode: mode,
                brightnessVwPos: pos,
              ),
            ],
          ),
        ),
      ),
    );
  }

  ProviderContainer newContainer() {
    final api = MockRustApi();
    when(() => api.getChapters(any())).thenAnswer((_) async => const []);
    when(() => api.getConfig(any())).thenAnswer((_) async => '');
    final container = ProviderContainer(
      overrides: [bookApiProvider.overrideWithValue(api)],
    );
    addTearDown(container.dispose);
    return container;
  }

  group('亮度条模式 0/1/2 显隐', () {
    testWidgets("模式 '1'：底栏横条（亮度行）渲染", (tester) async {
      final container = newContainer();
      await tester.pumpWidget(bottomBarHarness(container, '1'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      // 横条亮度行：自动亮度图标（进度滑条无此图标）
      expect(find.byIcon(Icons.brightness_auto_outlined), findsOneWidget);
      // 横条亮度滑条 + 章节进度滑条
      expect(find.byType(Slider), findsNWidgets(2));
    });

    testWidgets("模式 '0'：底栏无亮度行（仅章节进度滑条）", (tester) async {
      final container = newContainer();
      await tester.pumpWidget(bottomBarHarness(container, '0'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(find.byIcon(Icons.brightness_auto_outlined), findsNothing);
      expect(find.byType(Slider), findsOneWidget);
    });

    testWidgets("模式 '2'：底栏无亮度行（竖条在菜单面板承载）", (tester) async {
      final container = newContainer();
      await tester.pumpWidget(bottomBarHarness(container, '2'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(find.byIcon(Icons.brightness_auto_outlined), findsNothing);
      expect(find.byType(Slider), findsOneWidget);
    });

    testWidgets("模式 '2'：菜单面板渲染竖条（自动亮度钮 + RotatedBox 滑条）",
        (tester) async {
      final container = newContainer();
      await tester.pumpWidget(
          menuPanelHarness(container, mode: '2', pos: '1'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(find.byTooltip('自动亮度'), findsOneWidget);
      expect(find.byType(RotatedBox), findsOneWidget,
          reason: '竖向滑条经 RotatedBox(-90°) 承载');
    });

    testWidgets("模式 '0'/'1'：菜单面板不渲染竖条", (tester) async {
      final container = newContainer();
      await tester.pumpWidget(
          menuPanelHarness(container, mode: '0', pos: '1'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.byTooltip('自动亮度'), findsNothing);

      await tester.pumpWidget(
          menuPanelHarness(container, mode: '1', pos: '1'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.byTooltip('自动亮度'), findsNothing);
    });
  });

  group('竖条左右位置', () {
    testWidgets("pos '0'：竖条贴左缘（左 8dp、无右缘约束）", (tester) async {
      final container = newContainer();
      await tester.pumpWidget(
          menuPanelHarness(container, mode: '2', pos: '0'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      final positioned = tester.widget<Positioned>(
        find.ancestor(
          of: find.byTooltip('自动亮度'),
          matching: find.byType(Positioned),
        ).first,
      );
      expect(positioned.left, 8);
      expect(positioned.right, isNull);
    });

    testWidgets("pos '1'：竖条贴右缘（右 8dp、无左缘约束）", (tester) async {
      final container = newContainer();
      await tester.pumpWidget(
          menuPanelHarness(container, mode: '2', pos: '1'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      final positioned = tester.widget<Positioned>(
        find.ancestor(
          of: find.byTooltip('自动亮度'),
          matching: find.byType(Positioned),
        ).first,
      );
      expect(positioned.right, 8);
      expect(positioned.left, isNull);
    });

    testWidgets('配置往返：模型字段随 provider 推送驱动位置切换', (tester) async {
      final container = newContainer();
      // 先右侧
      await tester.pumpWidget(
          menuPanelHarness(container, mode: '2', pos: '1'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(
        tester
            .widget<Positioned>(find.ancestor(
              of: find.byTooltip('自动亮度'),
              matching: find.byType(Positioned),
            ).first)
            .right,
        8,
      );
      // 切左侧（同 widget 树 rebuild：面板参数来自配置快照）
      await tester.pumpWidget(
          menuPanelHarness(container, mode: '2', pos: '0'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(
        tester
            .widget<Positioned>(find.ancestor(
              of: find.byTooltip('自动亮度'),
              matching: find.byType(Positioned),
            ).first)
            .left,
        8,
      );
    });
  });

  group('旧布尔键迁移', () {
    test('showBrightnessView=true → readBrightnessMode="1"（横条）', () async {
      SharedPreferences.setMockInitialValues({'showBrightnessView': true});
      final cfg = await ReaderAdvancedConfig.load();
      expect(cfg.readBrightnessMode, '1');
      // 迁移标志落地
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('brightness_mode_migrated_v1b1'), isTrue);
    });

    test('showBrightnessView=false → readBrightnessMode="0"（不显示）',
        () async {
      SharedPreferences.setMockInitialValues({'showBrightnessView': false});
      final cfg = await ReaderAdvancedConfig.load();
      expect(cfg.readBrightnessMode, '0');
    });

    test('readMenuBrightnessVwPos left/right → "0"/"1"', () async {
      SharedPreferences.setMockInitialValues({
        'showBrightnessView': true,
        'readMenuBrightnessVwPos': 'left',
      });
      final cfg = await ReaderAdvancedConfig.load();
      expect(cfg.readBrightnessMode, '1');
      expect(cfg.readBrightnessVwPos, '0');

      SharedPreferences.setMockInitialValues({
        'readMenuBrightnessVwPos': 'right',
      });
      final cfg2 = await ReaderAdvancedConfig.load();
      expect(cfg2.readBrightnessVwPos, '1');
    });

    test('迁移幂等：二次 load 不再改写（新键优先）', () async {
      SharedPreferences.setMockInitialValues({'showBrightnessView': true});
      final first = await ReaderAdvancedConfig.load();
      expect(first.readBrightnessMode, '1');

      // 用户此后改模式 0 并保存；旧键仍为 true
      final cfg = await ReaderAdvancedConfig.load()
        ..readBrightnessMode = '0';
      await cfg.save();

      // 重启（重新 load）：新键 '0' 优先，不被旧布尔键二次迁移覆盖
      final again = await ReaderAdvancedConfig.load();
      expect(again.readBrightnessMode, '0');
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('showBrightnessView'), isTrue,
          reason: '迁移不清旧键（可逆登记）：旧值保留但不再消费');
    });

    test('save 停写旧键：仅写 readBrightnessMode/readBrightnessVwPos', () async {
      final cfg = await ReaderAdvancedConfig.load()
        ..readBrightnessMode = '2'
        ..readBrightnessVwPos = '0';
      await cfg.save();
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('readBrightnessMode'), '2');
      expect(prefs.getString('readBrightnessVwPos'), '0');
      expect(prefs.getBool('showBrightnessView'), isNull,
          reason: '旧布尔键不再写入（迁移后停消费）');
      expect(prefs.getString('readMenuBrightnessVwPos'), isNull,
          reason: '旧位置键不再写入');
    });

    test('非法值回落参考版默认（mode→"0"、pos→"1"）', () async {
      SharedPreferences.setMockInitialValues({
        'readBrightnessMode': '9',
        'readBrightnessVwPos': 'left',
      });
      final cfg = await ReaderAdvancedConfig.load();
      expect(cfg.readBrightnessMode, '0');
      expect(cfg.readBrightnessVwPos, '1');
    });
  });
}
