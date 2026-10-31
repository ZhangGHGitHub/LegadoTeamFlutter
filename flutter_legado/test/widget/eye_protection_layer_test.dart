// [设置批2a-1 | 2026-11-01] 护眼叠加层 widget 测试 — 全栈工程师
//
// 覆盖：生效/未生效渲染、叠加层不拦截点击、自动夜间跟随应用深色、
// 定时跨零点在分钟边界切换、前后台恢复重算。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/constants/pref_keys.dart';
import 'package:flutter_legado/src/widgets/eye_protection_layer.dart';

void main() {
  /// 固定时钟（可被测试推进）
  late DateTime now;

  setUp(() {
    now = DateTime(2026, 1, 1, 12, 0, 30);
  });

  Future<void> pumpApp(
    WidgetTester tester, {
    Map<String, Object> prefs = const {},
    ThemeMode themeMode = ThemeMode.light,
    required void Function() onTap,
  }) async {
    SharedPreferences.resetStatic();
    SharedPreferences.setMockInitialValues(prefs);
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: ThemeData.light(),
          darkTheme: ThemeData.dark(),
          themeMode: themeMode,
          builder: (context, child) =>
              EyeProtectionLayer(clock: () => now, child: child!),
          home: Scaffold(
            body: Center(
              child: ElevatedButton(onPressed: onTap, child: const Text('点我')),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('未启用：不挂载护眼叠加层', (tester) async {
    await pumpApp(tester, onTap: () {});
    expect(
      find.byKey(const ValueKey<String>('eyeProtectionOverlay')),
      findsNothing,
    );
    expect(find.byType(ColorFiltered), findsNothing);
  });

  testWidgets('启用后挂载彩色滤镜，且不拦截点击', (tester) async {
    var taps = 0;
    await pumpApp(
      tester,
      prefs: {PrefKeys.eyeProtectionEnabled: true},
      onTap: () => taps++,
    );
    expect(
      find.byKey(const ValueKey<String>('eyeProtectionOverlay')),
      findsOneWidget,
    );
    expect(find.byType(ColorFiltered), findsOneWidget);

    await tester.tap(find.text('点我'));
    await tester.pump();
    expect(taps, 1, reason: 'ColorFiltered 是纯绘制代理，命中测试必须透传');
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
    expect(
      find.byKey(const ValueKey<String>('eyeProtectionOverlay')),
      findsOneWidget,
    );
  });

  testWidgets('自动夜间：仅深色主题生效，浅色不挂载', (tester) async {
    await pumpApp(
      tester,
      prefs: {PrefKeys.eyeProtectionAutoNight: true},
      onTap: () {},
    );
    expect(find.byType(ColorFiltered), findsNothing);

    await pumpApp(
      tester,
      prefs: {PrefKeys.eyeProtectionAutoNight: true},
      themeMode: ThemeMode.dark,
      onTap: () {},
    );
    expect(find.byType(ColorFiltered), findsOneWidget);
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
    expect(
      find.byType(ColorFiltered),
      findsNothing,
      reason: '12:00 在 22:00-07:00 窗口外',
    );

    // 时钟推进到 22:30（跨零点前），分钟边界定时器触发重算
    now = DateTime(2026, 1, 1, 22, 30, 5);
    await tester.pump(const Duration(seconds: 61));
    await tester.pumpAndSettle();
    expect(
      find.byType(ColorFiltered),
      findsOneWidget,
      reason: '22:30 处于跨零点窗口内',
    );

    // 推进到 07:00（结束时刻不含）
    now = DateTime(2026, 1, 2, 7, 0);
    await tester.pump(const Duration(seconds: 61));
    await tester.pumpAndSettle();
    expect(
      find.byType(ColorFiltered),
      findsNothing,
      reason: '结束时刻 07:00 不含，应关闭叠加',
    );
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
    expect(find.byType(ColorFiltered), findsNothing);

    // 应用在后台期间时间进入窗口，恢复前台应立即生效（不等下一分钟）
    now = DateTime(2026, 1, 1, 23, 0);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(find.byType(ColorFiltered), findsOneWidget);
  });
}
