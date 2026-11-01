// [设置批2a-1 | 2026-11-01] 护眼叠加层 widget 测试 — 全栈工程师
//
// 覆盖：生效/未生效渲染、P1 回归（切换生效态不重建宿主子树）、叠加层不拦截
// 点击、自动夜间跟随应用深色（同一棵树切 themeMode）、定时跨零点在分钟边界
// 切换、定时关闭/未配置不轮询、前后台恢复重算。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/constants/pref_keys.dart';
import 'package:flutter_legado/src/providers/theme/eye_protection_notifier.dart';
import 'package:flutter_legado/src/widgets/eye_protection_layer.dart';

/// 记录 initState 次数的宿主子树节点（P1 回归：任何一次重建都会 +1）
class _InitCounter extends StatefulWidget {
  final VoidCallback onInit;
  final Widget child;

  const _InitCounter({required this.onInit, required this.child});

  @override
  State<_InitCounter> createState() => _InitCounterState();
}

class _InitCounterState extends State<_InitCounter> {
  @override
  void initState() {
    super.initState();
    widget.onInit();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

void main() {
  /// 固定时钟（可被测试推进）
  late DateTime now;

  setUp(() {
    now = DateTime(2026, 1, 1, 12, 0, 30);
  });

  EyeProtectionFilterBox filterBox(WidgetTester tester) => tester
      .widget<EyeProtectionFilterBox>(find.byType(EyeProtectionFilterBox));

  bool overlayActive(WidgetTester tester) => filterBox(tester).active;

  Future<ProviderContainer> pumpApp(
    WidgetTester tester, {
    Map<String, Object> prefs = const {},
    ThemeMode themeMode = ThemeMode.light,
    ValueNotifier<ThemeMode>? themeModeNotifier,
    VoidCallback? onInit,
    required VoidCallback onTap,
  }) async {
    SharedPreferences.resetStatic();
    SharedPreferences.setMockInitialValues(prefs);
    final container = ProviderContainer();
    addTearDown(container.dispose);

    Widget home = Scaffold(
      body: Center(
        child: ElevatedButton(onPressed: onTap, child: const Text('点我')),
      ),
    );
    if (onInit != null) {
      home = _InitCounter(onInit: onInit, child: home);
    }

    Widget app(ThemeMode mode) {
      return MaterialApp(
        theme: ThemeData.light(),
        darkTheme: ThemeData.dark(),
        themeMode: mode,
        builder: (context, child) =>
            EyeProtectionLayer(clock: () => now, child: child!),
        home: home,
      );
    }

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: themeModeNotifier == null
            ? app(themeMode)
            : ValueListenableBuilder<ThemeMode>(
                valueListenable: themeModeNotifier,
                builder: (_, mode, _) => app(mode),
              ),
      ),
    );
    await tester.pumpAndSettle();
    return container;
  }

  testWidgets('未启用：宿主节点常驻但 active=false，不推颜色滤镜层', (tester) async {
    await pumpApp(tester, onTap: () {});
    expect(find.byType(EyeProtectionFilterBox), findsOneWidget);
    expect(overlayActive(tester), isFalse);
    // 结构恒定：不再出现 ColorFiltered 包装层
    expect(find.byType(ColorFiltered), findsNothing);
  });

  testWidgets('启用后 active=true，且不拦截点击', (tester) async {
    var taps = 0;
    await pumpApp(
      tester,
      prefs: {PrefKeys.eyeProtectionEnabled: true},
      onTap: () => taps++,
    );
    expect(overlayActive(tester), isTrue);

    await tester.tap(find.text('点我'));
    await tester.pump();
    expect(taps, 1, reason: 'RenderProxyBox 只改绘制，命中测试必须透传');
  });

  // P1 回归（修前红）：生效/失效切换不得重建 Navigator 子树
  testWidgets('P1 回归：多次切换生效态，宿主 initState 仅一次', (tester) async {
    var inits = 0;
    final container = await pumpApp(
      tester,
      onInit: () => inits++,
      onTap: () {},
    );
    expect(inits, 1);
    expect(overlayActive(tester), isFalse);

    for (final enabled in <bool>[true, false, true, false, true, false]) {
      await container.read(eyeProtectionProvider.notifier).setEnabled(enabled);
      await tester.pumpAndSettle();
      expect(overlayActive(tester), enabled);
    }
    expect(
      inits,
      1,
      reason:
          'SystemBarBinder/WebView/验证码监听器都在该子树内，'
          '切换护眼不得重建（原实现 child↔ColorFiltered 切换会整棵重建）',
    );
  });

  testWidgets('强度 0 仍处于生效态（单位矩阵，不改变颜色）', (tester) async {
    await pumpApp(
      tester,
      prefs: {
        PrefKeys.eyeProtectionEnabled: true,
        PrefKeys.colorTemperature: 0,
      },
      onTap: () {},
    );
    expect(overlayActive(tester), isTrue);
    expect(filterBox(tester).intensity, 0);
  });

  testWidgets('自动夜间：仅深色主题生效，浅色不生效', (tester) async {
    await pumpApp(
      tester,
      prefs: {PrefKeys.eyeProtectionAutoNight: true},
      onTap: () {},
    );
    expect(overlayActive(tester), isFalse);

    await pumpApp(
      tester,
      prefs: {PrefKeys.eyeProtectionAutoNight: true},
      themeMode: ThemeMode.dark,
      onTap: () {},
    );
    expect(overlayActive(tester), isTrue);
  });

  // P3：同一棵树切 themeMode 即触发 autoNight（不重进页面）
  testWidgets('自动夜间：同一棵树 themeMode 切换即时生效且不重建子树', (tester) async {
    var inits = 0;
    final mode = ValueNotifier<ThemeMode>(ThemeMode.light);
    addTearDown(mode.dispose);
    await pumpApp(
      tester,
      prefs: {PrefKeys.eyeProtectionAutoNight: true},
      themeModeNotifier: mode,
      onInit: () => inits++,
      onTap: () {},
    );
    expect(overlayActive(tester), isFalse);

    mode.value = ThemeMode.dark;
    await tester.pumpAndSettle();
    expect(overlayActive(tester), isTrue);
    expect(inits, 1);

    mode.value = ThemeMode.light;
    await tester.pumpAndSettle();
    expect(overlayActive(tester), isFalse);
    expect(inits, 1);
  });

  testWidgets('定时跨零点：12:00 不生效，推进到 22:30 后分钟边界生效，07:00 结束', (tester) async {
    await pumpApp(
      tester,
      prefs: {
        PrefKeys.eyeProtectionEnabled: true,
        PrefKeys.eyeProtectionSchedule: true,
        PrefKeys.eyeProtectionStartTime: '22:00',
        PrefKeys.eyeProtectionEndTime: '07:00',
      },
      onTap: () {},
    );
    expect(overlayActive(tester), isFalse, reason: '12:00 在 22:00-07:00 窗口外');

    // 时钟推进到 22:30（跨零点前），分钟边界定时器触发重算
    now = DateTime(2026, 1, 1, 22, 30, 5);
    await tester.pump(const Duration(seconds: 61));
    await tester.pumpAndSettle();
    expect(overlayActive(tester), isTrue, reason: '22:30 处于跨零点窗口内');

    // 推进到 07:00（结束时刻不含）
    now = DateTime(2026, 1, 2, 7, 0);
    await tester.pump(const Duration(seconds: 61));
    await tester.pumpAndSettle();
    expect(overlayActive(tester), isFalse, reason: '结束时刻 07:00 不含');
  });

  testWidgets('定时开关关闭后取消 Timer；仅定时开启但未配置时不轮询', (tester) async {
    final container = await pumpApp(
      tester,
      prefs: {
        PrefKeys.eyeProtectionEnabled: true,
        PrefKeys.eyeProtectionSchedule: true,
      },
      onTap: () {},
    );
    var state = tester.state<EyeProtectionLayerState>(
      find.byType(EyeProtectionLayer),
    );
    expect(state.debugTickerActive, isTrue, reason: '已配置 + 定时开启应轮询');

    await container.read(eyeProtectionProvider.notifier).setSchedule(false);
    await tester.pumpAndSettle();
    state = tester.state<EyeProtectionLayerState>(
      find.byType(EyeProtectionLayer),
    );
    expect(state.debugTickerActive, isFalse, reason: '关闭定时后必须取消 Timer');

    // 未配置（仅 schedule=true，开关与自动夜间均关）不轮询
    await pumpApp(
      tester,
      prefs: {PrefKeys.eyeProtectionSchedule: true},
      onTap: () {},
    );
    final state2 = tester.state<EyeProtectionLayerState>(
      find.byType(EyeProtectionLayer),
    );
    expect(state2.debugTickerActive, isFalse, reason: '未配置时无需按分钟重算');
  });

  testWidgets('前后台恢复：回到前台立即按当前时刻重算', (tester) async {
    await pumpApp(
      tester,
      prefs: {
        PrefKeys.eyeProtectionEnabled: true,
        PrefKeys.eyeProtectionSchedule: true,
        PrefKeys.eyeProtectionStartTime: '22:00',
        PrefKeys.eyeProtectionEndTime: '07:00',
      },
      onTap: () {},
    );
    expect(overlayActive(tester), isFalse);

    // 应用在后台期间时间进入窗口，恢复前台应立即生效（不等下一分钟）
    now = DateTime(2026, 1, 1, 23, 0);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(overlayActive(tester), isTrue);
  });
}
