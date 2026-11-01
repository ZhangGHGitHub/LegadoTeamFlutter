// [设置批2a-1 | 2026-11-01] 护眼叠加层 widget 测试 — 全栈工程师
//
// 覆盖：生效/未生效渲染、P1 回归（切换生效态不重建宿主子树）、叠加层不拦截
// 点击、自动夜间跟随应用深色（同一棵树切 themeMode）、定时跨零点在分钟边界
// 切换、定时关闭/未配置不轮询、前后台恢复重算。
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ColorFilterLayer;
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/constants/pref_keys.dart';
import 'package:flutter_legado/src/providers/theme/eye_protection_notifier.dart';
import 'package:flutter_legado/src/widgets/eye_protection_layer.dart';

/// 记录 initState/dispose 次数的宿主子树节点
///
/// 必须挂在 `MaterialApp.builder` 内、`EyeProtectionLayer` 与 `child`
/// （Navigator）之间：旧实现 child↔ColorFiltered 切换时该节点会被重建，
/// 放 Navigator 内部（home）则不会，无法作为 P1 回归证据。
class _InitCounter extends StatefulWidget {
  final VoidCallback onInit;
  final VoidCallback onDispose;
  final Widget child;

  const _InitCounter({
    required this.onInit,
    required this.onDispose,
    required this.child,
  });

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
  void dispose() {
    widget.onDispose();
    super.dispose();
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

  EyeProtectionFilterRenderObject filterRenderObject(WidgetTester tester) =>
      tester.renderObject<EyeProtectionFilterRenderObject>(
        find.byType(EyeProtectionFilterBox),
      );

  Future<ProviderContainer> pumpApp(
    WidgetTester tester, {
    Map<String, Object> prefs = const {},
    ThemeMode themeMode = ThemeMode.light,
    ValueNotifier<ThemeMode>? themeModeNotifier,
    VoidCallback? onInit,
    VoidCallback? onDispose,
    required VoidCallback onTap,
  }) async {
    SharedPreferences.resetStatic();
    SharedPreferences.setMockInitialValues(prefs);
    final container = ProviderContainer();
    addTearDown(container.dispose);

    final home = Scaffold(
      body: Center(
        child: ElevatedButton(onPressed: onTap, child: const Text('点我')),
      ),
    );

    Widget app(ThemeMode mode) {
      return MaterialApp(
        theme: ThemeData.light(),
        darkTheme: ThemeData.dark(),
        themeMode: mode,
        builder: (context, child) {
          // 计数节点放在 builder 内、Navigator(child) 之外——
          // 这是旧实现类型切换时唯一会被重建的层级
          final navigator = (onInit != null || onDispose != null)
              ? _InitCounter(
                  onInit: onInit ?? () {},
                  onDispose: onDispose ?? () {},
                  child: child!,
                )
              : child!;
          return EyeProtectionLayer(clock: () => now, child: navigator);
        },
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
    expect(
      filterRenderObject(tester).debugColorFilterLayer,
      isNull,
      reason: 'inactive 时不得持有 ColorFilterLayer',
    );
  });

  testWidgets('启用后 active=true 且存在 ColorFilterLayer，且不拦截点击', (tester) async {
    var taps = 0;
    final container = await pumpApp(
      tester,
      prefs: {PrefKeys.eyeProtectionEnabled: true},
      onTap: () => taps++,
    );
    expect(overlayActive(tester), isTrue);
    expect(
      filterRenderObject(tester).debugColorFilterLayer,
      isA<ColorFilterLayer>(),
      reason: 'active 时 RenderObject 必须实际推入颜色滤镜层',
    );

    await tester.tap(find.text('点我'));
    await tester.pump();
    expect(taps, 1, reason: 'RenderProxyBox 只改绘制，命中测试必须透传');

    // 关闭后释放框架 layer 句柄
    await container.read(eyeProtectionProvider.notifier).setEnabled(false);
    await tester.pumpAndSettle();
    expect(overlayActive(tester), isFalse);
    expect(
      filterRenderObject(tester).debugColorFilterLayer,
      isNull,
      reason: 'inactive 后不得悬挂旧 ColorFilterLayer',
    );
  });

  // P1 回归（修前红）：生效/失效切换不得重建 Navigator 层级
  testWidgets('P1 回归：切换生效态 6 次，builder 内宿主 init=1 / dispose=0', (tester) async {
    var inits = 0;
    var disposes = 0;
    final container = await pumpApp(
      tester,
      onInit: () => inits++,
      onDispose: () => disposes++,
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
          '计数节点位于 EyeProtectionLayer 与 Navigator 之间；旧实现 '
          'child↔ColorFiltered 类型切换会重建该层（对照：本用例在 home 内则绿）',
    );
    expect(disposes, 0, reason: '宿主节点不得被卸载重建');
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
    var disposes = 0;
    final mode = ValueNotifier<ThemeMode>(ThemeMode.light);
    addTearDown(mode.dispose);
    await pumpApp(
      tester,
      prefs: {PrefKeys.eyeProtectionAutoNight: true},
      themeModeNotifier: mode,
      onInit: () => inits++,
      onDispose: () => disposes++,
      onTap: () {},
    );
    expect(overlayActive(tester), isFalse);

    mode.value = ThemeMode.dark;
    await tester.pumpAndSettle();
    expect(overlayActive(tester), isTrue);
    expect(inits, 1);
    expect(disposes, 0);

    mode.value = ThemeMode.light;
    await tester.pumpAndSettle();
    expect(overlayActive(tester), isFalse);
    expect(inits, 1);
    expect(disposes, 0);
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
