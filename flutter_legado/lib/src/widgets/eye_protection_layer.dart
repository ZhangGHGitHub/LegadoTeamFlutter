// [设置批2a-1 | 2026-11-01] 护眼模式全局叠加层 — 全栈工程师
//
// 语义基准：参考版 `BaseComposeActivity.kt:89-106` 在 Activity 内容最外层
// （整个 App，不只阅读页）套 `graphicsLayer { colorFilter = ColorMatrix }`；
// `rememberEyeProtectionActive`（`ui/book/read/EyeProtection.kt:122-149`）在
// 启用定时时每 60 秒重算一次生效状态。
//
// 实现要点（P1 审查回修）：
// - 生效/失效切换时**不改变 widget 树形状**：始终返回
//   [EyeProtectionFilterBox]（自定义 RenderProxyBox），只更新绘制属性。
//   若在 `child` 与 `ColorFiltered(child)` 之间切换，Element 类型变化会
//   整棵重建 Navigator 子树，导致 SystemBarBinder / WebViewBridgeListener /
//   VerificationCodeListener 的 State 丢失（系统栏重显、WebView 队列丢失、
//   验证码重复弹窗）。
// - 生效时 `paint` 内 `pushColorFilter`（一次离屏合成）；失效时直接
//   `super.paint`，不产生离屏合成。
// - 定时对齐分钟边界重算；`resumed` 立即重算。
//
// 已知边界（设置批2a-1 登记，设备验收清单）：
// 1. 滤镜覆盖 Flutter 绘制内容：弹层（对话框/底部弹层）与背景壁纸同样被
//    着色；参考版 Compose Dialog 是独立窗口不着色，属框架差异。
// 2. PlatformView（WebView/视频 SurfaceTexture 等）可能绕过 ColorFilter。
// 3. 生效期间全屏 saveLayer 有一次离屏合成开销（参考版 graphicsLayer 同量级），
//    低端机需实机观察帧率。
// 4. 系统状态栏/导航栏/输入法在 Flutter 视图外，不受影响；系统截图/录屏
//    会包含应用绘制结果（参考版同样如此）。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
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
  EyeProtectionLayerState createState() => EyeProtectionLayerState();
}

class EyeProtectionLayerState extends ConsumerState<EyeProtectionLayer>
    with WidgetsBindingObserver {
  /// 分钟边界定时器（仅「已配置 + 定时开启」时存在）
  Timer? _timer;

  /// 当前是否处于定时刷新态（用于 build 期间检测状态迁移）
  bool _ticking = false;

  /// [P3 测试] 定时器是否存活（验证关闭定时/未配置时不轮询）
  @visibleForTesting
  bool get debugTickerActive => _timer != null;

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
    // 结构恒定：始终返回同一 widget 类型，仅更新 active/intensity；
    // child 是稳定的 Navigator 子树 → 切换生效态不重建宿主 State。
    return EyeProtectionFilterBox(
      active: active,
      intensity: settings.intensity,
      child: widget.child,
    );
  }
}

/// 稳定宿主：把「是否生效」作为绘制属性而非 widget 树形状
///
/// 生效时在 [EyeProtectionFilterRenderObject.paint] 中推入颜色滤镜层；
/// 失效时直接绘制子节点。widget 始终存在，因此子树 Element/State 不因
/// 开关切换而重建。
class EyeProtectionFilterBox extends SingleChildRenderObjectWidget {
  final bool active;
  final int intensity;

  const EyeProtectionFilterBox({
    super.key,
    required Widget super.child,
    required this.active,
    required this.intensity,
  });

  @override
  EyeProtectionFilterRenderObject createRenderObject(BuildContext context) {
    return EyeProtectionFilterRenderObject(
      active: active,
      intensity: intensity,
    );
  }

  @override
  void updateRenderObject(
    BuildContext context,
    EyeProtectionFilterRenderObject renderObject,
  ) {
    renderObject
      ..active = active
      ..intensity = intensity;
  }
}

/// 护眼颜色滤镜 RenderObject（替代「有/无 ColorFiltered」的树形切换）
class EyeProtectionFilterRenderObject extends RenderProxyBox {
  EyeProtectionFilterRenderObject({
    required bool active,
    required int intensity,
  }) : _active = active,
       _intensity = intensity,
       _colorFilter = active
           ? EyeProtectionFilter.colorFilterForIntensity(intensity)
           : null;

  bool _active;
  int _intensity;
  ColorFilter? _colorFilter;

  bool get active => _active;
  set active(bool value) {
    if (_active == value) return;
    _active = value;
    _colorFilter = value
        ? EyeProtectionFilter.colorFilterForIntensity(_intensity)
        : null;
    // 失效时释放框架 layer 句柄，避免旧 ColorFilterLayer 悬挂
    if (!value) layer = null;
    // 合成位变化：告知祖先本节点是否需要独立图层（同 ColorFiltered 的
    // alwaysNeedsCompositing 动态切换）
    markNeedsCompositingBitsUpdate();
    markNeedsPaint();
  }

  int get intensity => _intensity;
  set intensity(int value) {
    final clamped = value.clamp(
      EyeProtectionFilter.minIntensity,
      EyeProtectionFilter.maxIntensity,
    );
    if (_intensity == clamped) return;
    _intensity = clamped;
    if (_active) {
      _colorFilter = EyeProtectionFilter.colorFilterForIntensity(clamped);
      markNeedsPaint();
    }
  }

  @override
  bool get alwaysNeedsCompositing => _colorFilter != null;

  /// [测试] 当前挂载的颜色滤镜层（inactive/dispose 后应为 null）
  @visibleForTesting
  ColorFilterLayer? get debugColorFilterLayer => layer as ColorFilterLayer?;

  @override
  void paint(PaintingContext context, Offset offset) {
    final filter = _colorFilter;
    if (filter == null) {
      // 未生效：直接绘制，无离屏合成
      super.paint(context, offset);
      return;
    }
    // 使用框架 layer 句柄（同 Flutter _ColorFilterRenderObject），
    // 便于测试断言 ColorFilterLayer 是否存在，并由框架统一回收
    layer = context.pushColorFilter(
      offset,
      filter,
      super.paint,
      oldLayer: layer as ColorFilterLayer?,
    );
  }

  @override
  void dispose() {
    // 显式置空：RenderObject 销毁时不保留旧 ColorFilterLayer
    layer = null;
    super.dispose();
  }
}
