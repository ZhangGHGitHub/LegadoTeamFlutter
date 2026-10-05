// [V-B3-ROUTE 2026-10-05] 冷启动悬浮窗回全屏 × 欢迎页路由竞争回归
//
// 缺陷（round2 真机 2/2 复现，QA 证据 .tmp/video_qa/round2/c2_*.png）：
// 悬浮窗播放中划掉应用任务 → 点悬浮窗「全屏」→ 冷启动 MainActivity 携带
// 播放状态：Dart 侧 `_consumeInitialReturn` 在首帧附近触发回全屏导航
// （openFullscreen → push /video，压在闪屏 /welcome 之上）；闪屏随后
// `pushReplacementNamed(home)` 替换的是**当时栈顶**——刚压入的 /video 被
// 一并替换：可见播放页闪现后被书架顶掉、播放中断（logcat 见
// `[VideoPlay] isPlaying=true` 后约 0.3s 画面被替换）。
//
// 修复：回全屏导航经 [LegadoApp.scheduleFloatReturnNavigation] 门控——
// 以 [TopRouteWatcher]（didChangeTop 事件源，由框架在路由栈变化时同步
// 更新）判定「栈顶已非 /welcome」：未就绪时按固定间隔轮询等待（默认
// 50ms × 60 = 3s 上限），闪屏退出后立即压栈；热路径（App 已存活，
// onNewIntent）栈顶非 welcome → 同步 push，零额外延迟；超时放弃本次
// push 并回调 onTimeout（停留当前页，不重演「压栈后被欢迎页替换」）。
//
// 本测试复刻生产结构（MaterialApp 装配生产 navigatorKey + 生产
// TopRouteWatcher 注册 + initialRoute=/welcome + 生产调度入口）。
// 完整 LegadoApp 依赖 Rust FFI（见 test/widget_test.dart 注释），无法在
// 纯 widget 测试环境运行，故绕开 FFI 仅验证路由门控入口。

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_legado/app.dart';
import 'package:flutter_legado/src/routes.dart';
import 'package:flutter_legado/src/services/platform_bridge_service.dart';
import 'package:flutter_legado/src/services/video_float_window.dart';

/// 路由名 → 可读文本（断言用；避免与路由名常量混淆）
String _label(String? name) => switch (name) {
      AppRoutes.welcome => 'splash',
      AppRoutes.home => 'bookshelf',
      AppRoutes.video => 'player',
      _ => 'other',
    };

Widget _buildApp({
  required TopRouteWatcher watcher,
  String initialRoute = AppRoutes.welcome,
}) =>
    MaterialApp(
      // 与 app.dart build() 同源：生产全局 navigatorKey
      navigatorKey: PlatformBridgeService.navigatorKey,
      navigatorObservers: [watcher],
      initialRoute: initialRoute,
      onGenerateRoute: (settings) => MaterialPageRoute<void>(
        settings: settings,
        builder: (_) => Scaffold(body: Center(child: Text(_label(settings.name)))),
      ),
    );

void main() {
  testWidgets(
      '冷启动：Navigator 未就绪且闪屏未退出 → push 推迟，闪屏退出后压入播放页',
      (tester) async {
    final watcher = TopRouteWatcher();
    final pushed = <String>[];

    // 复刻 _consumeInitialReturn 时序：首帧前（Navigator 尚未装配）即回调
    LegadoApp.scheduleFloatReturnNavigation(
      watcher: watcher,
      navigator: () => PlatformBridgeService.navigatorKey.currentState,
      push: (navigator) {
        pushed.add(AppRoutes.video);
        navigator.pushNamed(AppRoutes.video);
      },
      maxAttempts: 5,
      interval: const Duration(milliseconds: 50),
    );
    expect(pushed, isEmpty, reason: '首帧前 Navigator 未就绪，不得 push');

    await tester.pumpWidget(_buildApp(watcher: watcher));
    expect(watcher.topRouteName, AppRoutes.welcome, reason: '冷启动闪屏在栈顶');
    await tester.pump(const Duration(milliseconds: 50));
    expect(pushed, isEmpty, reason: '闪屏仍在栈顶，push 必须等待（原竞争点）');

    // 复刻 WelcomeScreen._goNext：闪屏 pushReplacementNamed(home)
    PlatformBridgeService.navigatorKey.currentState!
        .pushReplacementNamed(AppRoutes.home);
    await tester.pump(const Duration(milliseconds: 50));
    // 冲刷转场动画：闪屏退出转场结束后旧路由才被销毁
    await tester.pumpAndSettle();

    expect(pushed, [AppRoutes.video], reason: '闪屏退出后应立即压入播放页');
    expect(find.text('player'), findsOneWidget, reason: '播放页可见且位于栈顶');
    expect(find.text('splash', skipOffstage: false), findsNothing,
        reason: '闪屏已被 home 替换（不是被 video 替换后的残留）');
    expect(find.text('bookshelf', skipOffstage: false), findsAtLeastNWidgets(1),
        reason: 'bookshelf 仍在栈底，播放页压在其上');
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      '协调器 openFullscreen 冷启动回传：路由未就绪时 push 推迟，闪屏退出后压栈',
      (tester) async {
    final watcher = TopRouteWatcher();
    final pushed = <String>[];
    final coordinator = VideoFloatWindowCoordinator();
    // 复刻 app.dart 注入：openFullscreen → 门控调度 → push /video
    coordinator.openFullscreen = (state, book) {
      LegadoApp.scheduleFloatReturnNavigation(
        watcher: watcher,
        navigator: () => PlatformBridgeService.navigatorKey.currentState,
        push: (navigator) {
          pushed.add(state.url);
          navigator.pushNamed(AppRoutes.video);
        },
        maxAttempts: 5,
        interval: const Duration(milliseconds: 50),
      );
    };

    await tester.pumpWidget(_buildApp(watcher: watcher));
    // 复刻 MainActivity onCreate → getInitialFloatReturn → handleReturnState
    await coordinator.handleReturnState({
      'url': 'https://cdn.example/v.m3u8',
      'bookUrl': 'book://1',
      'chapterIndex': 0,
      'positionMs': 4000,
      'playing': true,
    });
    expect(pushed, isEmpty, reason: '闪屏未退出，回全屏 push 必须推迟（原竞争点）');

    PlatformBridgeService.navigatorKey.currentState!
        .pushReplacementNamed(AppRoutes.home);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pumpAndSettle();

    expect(pushed, ['https://cdn.example/v.m3u8']);
    expect(find.text('player'), findsOneWidget, reason: '回全屏播放页最终可见');
    expect(tester.takeException(), isNull);
  });

  testWidgets('冷启动回传晚到：闪屏已退出（栈顶 home）→ 立即 push，无需等待',
      (tester) async {
    final watcher = TopRouteWatcher();
    final pushed = <String>[];
    await tester.pumpWidget(_buildApp(watcher: watcher));
    PlatformBridgeService.navigatorKey.currentState!
        .pushReplacementNamed(AppRoutes.home);
    await tester.pump();

    LegadoApp.scheduleFloatReturnNavigation(
      watcher: watcher,
      navigator: () => PlatformBridgeService.navigatorKey.currentState,
      push: (navigator) {
        pushed.add(AppRoutes.video);
        navigator.pushNamed(AppRoutes.video);
      },
      maxAttempts: 1,
      interval: const Duration(seconds: 1),
    );

    expect(pushed, [AppRoutes.video], reason: '门控就绪时同步 push，不引入等待');
    await tester.pumpAndSettle();
    expect(find.text('player'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('热路径：栈顶非 welcome（App 已存活）→ 同步 push，零额外延迟',
      (tester) async {
    final watcher = TopRouteWatcher();
    final pushed = <String>[];
    await tester.pumpWidget(
      _buildApp(watcher: watcher, initialRoute: AppRoutes.home),
    );
    expect(watcher.topRouteName, AppRoutes.home);

    LegadoApp.scheduleFloatReturnNavigation(
      watcher: watcher,
      navigator: () => PlatformBridgeService.navigatorKey.currentState,
      push: (navigator) {
        pushed.add(AppRoutes.video);
        navigator.pushNamed(AppRoutes.video);
      },
      maxAttempts: 1,
      interval: const Duration(seconds: 1),
    );

    // 未 pump、未推进任何时间：push 已同步发生（热路径不得被本门控拖慢）
    expect(pushed, [AppRoutes.video]);
    await tester.pumpAndSettle();
    expect(find.text('player'), findsOneWidget);
    // 就绪路径不调度轮询定时器：推进 1s 不得出现重复 push
    // （若残留定时器，测试框架会在结束时报 pending timer）
    await tester.pump(const Duration(seconds: 1));
    expect(pushed, [AppRoutes.video], reason: '不得重复 push');
    expect(tester.takeException(), isNull);
  });

  testWidgets('超时兜底：闪屏始终未退出 → 放弃 push（停留当前页）并回调 onTimeout',
      (tester) async {
    final watcher = TopRouteWatcher();
    final pushed = <String>[];
    var timedOut = false;
    await tester.pumpWidget(_buildApp(watcher: watcher));

    LegadoApp.scheduleFloatReturnNavigation(
      watcher: watcher,
      navigator: () => PlatformBridgeService.navigatorKey.currentState,
      push: (navigator) {
        pushed.add(AppRoutes.video);
        navigator.pushNamed(AppRoutes.video);
      },
      maxAttempts: 2,
      interval: const Duration(milliseconds: 50),
      onTimeout: () => timedOut = true,
    );

    await tester.pump(const Duration(milliseconds: 50));
    expect(timedOut, isFalse);
    expect(pushed, isEmpty);
    await tester.pump(const Duration(milliseconds: 50));

    expect(timedOut, isTrue, reason: '超过等待上限须回调 onTimeout');
    expect(pushed, isEmpty, reason: '超时放弃 push，停留在闪屏而非错误压栈');
    expect(find.text('player'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
