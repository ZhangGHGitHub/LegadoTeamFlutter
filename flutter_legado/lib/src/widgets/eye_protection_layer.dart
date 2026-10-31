// [设置批2a-1 | 2026-11-01] 护眼模式全局叠加层 — 全栈工程师
//
// 语义基准：参考版 `BaseComposeActivity.kt:89-106` 在 Activity 内容最外层
// （整个 App，不只阅读页）套 `graphicsLayer { colorFilter = ColorMatrix }`；
// `rememberEyeProtectionActive`（`ui/book/read/EyeProtection.kt:122-149`）在
// 启用定时时每 60 秒重算一次生效状态。
//
// Flutter 等价实现：
// - 挂在 `MaterialApp.builder` 最外层 → 覆盖所有路由（含全屏阅读页/漫画页）、
//   背景图层与弹层（同一 Overlay，绘制受滤镜影响）；
// - [ColorFiltered] 是纯绘制代理，不参与命中测试 → 不拦截点击/滑动手势；
// - 只作用于 Flutter 视图内容 → 系统状态栏/导航栏（系统窗口）不受影响。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;

import '../models/eye_protection.dart';
import '../providers/theme/eye_protection_notifier.dart';

/// 护眼叠加层：按当前偏好与时刻决定是否对 [child] 施加暖色滤镜
///
/// [clock] 仅测试注入固定/可控时钟；生产默认 [DateTime.now]。
class EyeProtectionLayer extends ConsumerStatefulWidget {
  final Widget child;
  final DateTime Function() clock;

  const EyeProtectionLayer({
    super.key,
    required this.child,
    this.clock = DateTime.now,
  });

  @override
  ConsumerState<EyeProtectionLayer> createState() => _EyeProtectionLayerState();
}

class _EyeProtectionLayerState extends ConsumerState<EyeProtectionLayer>
    with WidgetsBindingObserver {
  /// 分钟边界定时器（仅「已配置 + 定时开启」时存在）
  Timer? _timer;

  /// 当前是否处于定时刷新态（用于 build 期间检测状态迁移）
  bool _ticking = false;

  DateTime _now() => widget.clock();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    _timer = null;
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    // 前后台恢复：立即按当前时刻重算，并重新对齐到下一个分钟边界
    //（后台期间 Timer 可能被系统节流/延迟；参考版仅 60s 轮询，无恢复钩子）
    if (!mounted) return;
    setState(() {});
    if (_ticking) _scheduleNextTick();
  }

  /// 对齐到下一个分钟边界触发一次重算（参考版按 60s 轮询，此处对齐边界，
  /// 使 22:00/07:00 等边界最多延后到下一分钟开始时切换）
  void _scheduleNextTick() {
    _timer?.cancel();
    final now = _now();
    final nextMinute = DateTime(
      now.year,
      now.month,
      now.day,
      now.hour,
      now.minute,
    ).add(const Duration(minutes: 1));
    var delay = nextMinute.difference(now);
    if (delay <= Duration.zero) delay = const Duration(minutes: 1);
    _timer = Timer(delay, () {
      if (!mounted) return;
      setState(() {});
      if (_ticking) _scheduleNextTick();
    });
  }

  void _syncTicker(bool shouldTick) {
    if (_ticking == shouldTick && (!shouldTick || _timer != null)) return;
    _ticking = shouldTick;
    _timer?.cancel();
    _timer = null;
    if (shouldTick) _scheduleNextTick();
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(eyeProtectionProvider);
    // 参考版 rememberEyeProtectionActive：未配置或未开定时时无需轮询
    _syncTicker(settings.isConfigured && settings.schedule);

    final isDark = Theme.of(context).brightness == Brightness.dark;
    final active = EyeProtectionFilter.isActiveAt(
      settings: settings,
      isDark: isDark,
      now: _now(),
    );
    if (!active) return widget.child;
    return ColorFiltered(
      // 语义标记：叠加层（测试与排障定位；不影响命中测试）
      key: const ValueKey<String>('eyeProtectionOverlay'),
      colorFilter: EyeProtectionFilter.colorFilterForIntensity(
        settings.intensity,
      ),
      child: widget.child,
    );
  }
}
