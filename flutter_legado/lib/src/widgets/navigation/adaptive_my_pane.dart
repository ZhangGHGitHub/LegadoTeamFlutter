import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;

import '../../providers/ui_settings/ui_settings_notifier.dart';
import '../../routes.dart';
import '../../screens/settings_screen.dart';
import '../../utils/multi_pane_layout.dart';
import 'my_pane_scope.dart';

/// 容器初始（空态）路由名；`AppRoutes` 中不存在，避免与业务路由冲突。
const String kMyPaneEmptyRoute = '/__my_pane_empty__';

/// 「我的」页容器：按 `multiPaneMode` + 当前窗口尺寸在双栏/单栏间切换。
///
/// 双栏（对齐参考版 `ListDetailSceneStrategy` 的容器左栏 + 详情右栏）：
/// - 左：`SettingsScreen` 菜单，固定 360dp、自身可滚动；
/// - 中间：24dp 间距；
/// - 右：nested `Navigator`（`AppRoutes.generateRoute`），初始为空态
///   「选择左侧项目」。
///
/// 单栏：**同一个 nested Navigator 全宽保留**（不再 root 转推/清空）：
/// - 右栏栈非空 → 左菜单隐藏，栈顶页面全宽显示；
/// - 右栏栈为空 → 全宽显示 `SettingsScreen` 菜单；
/// - 菜单入口仍进 nested Navigator；back 逐级 pop，空栈回菜单；
/// - 再变宽恢复「左菜单 + 右栏」，栈与页面内状态不丢。
///
/// 模式阈值按**完整窗口**宽（含导航 Rail），左右最小宽度/高度按扣掉 Rail
/// 后的窗格约束判定（见 [resolveMultiPane] 的 `windowSize`）。
/// 「我的」页不可见期间冻结上一次可见形态，重新可见时再按新窗口判定。
class AdaptiveMyPane extends ConsumerStatefulWidget {
  const AdaptiveMyPane({
    super.key,
    this.navigatorKey,
    this.routeGenerator,
    this.active = true,
  });

  /// 容器 nested Navigator 的 key（首页返回键据此优先 pop）
  final GlobalKey<NavigatorState>? navigatorKey;

  /// 路由生成器（默认 [AppRoutes.generateRoute]；测试可注入桩页面）
  ///
  /// 不用 Flutter 的 `RouteFactory`：其返回类型为 `Route<dynamic>?`，
  /// 而 nested Navigator 的 `onGenerateRoute` 契约要求非空路由。
  final Route<dynamic> Function(RouteSettings)? routeGenerator;

  /// 「我的」页当前是否可见：不可见时冻结形态，避免在其它页签上重排。
  final bool active;

  @override
  ConsumerState<AdaptiveMyPane> createState() => AdaptiveMyPaneState();
}

class AdaptiveMyPaneState extends ConsumerState<AdaptiveMyPane> {
  late final GlobalKey<NavigatorState> _navigatorKey =
      widget.navigatorKey ?? GlobalKey<NavigatorState>();
  final MyPaneController _controller = MyPaneController();
  late final _MyPaneNavigatorObserver _observer = _MyPaneNavigatorObserver(
    _onRightStackChanged,
  );

  /// 上一次可见时的双栏形态（不可见期间冻结）
  bool _wasMultiPane = false;

  /// 是否已经历过一次可见构建（未可见过时不冻结，直接用当前窗口判定）
  bool _modeSeen = false;

  /// 右栏栈是否有业务页面（决定单栏时显示菜单还是页面）
  bool _rightStackNotEmpty = false;

  /// State 已销毁（防止 Navigator 卸载期间 observer 回调再触发通知）
  bool _disposed = false;

  @override
  void initState() {
    super.initState();
    _controller.navigatorKey = _navigatorKey;
  }

  @override
  void dispose() {
    _disposed = true;
    // 容器销毁时清空 observer 栈，避免 GlobalKey 复用/重建时残留旧路由。
    _observer.clear();
    _controller.dispose();
    super.dispose();
  }

  /// 右栏栈顶变化：回写栈顶用于去重；空态清空左栏选中项
  ///
  /// 选中项只在菜单点击时写入（[MyPaneController.pushNamed]），不随右栏
  /// 内部下钻（设置 → 外观）改变。观察回调可能发生在 build/layout 帧内
  /// （初始空态路由），此时延迟到帧末，避免 build 期间 setState。
  void _onRightStackChanged() {
    if (_disposed) return;
    final name = _observer.topSettings?.name;
    final hasPage = _observer.hasPage;
    // 匿名路由（RouteSettings.name == null）同样算业务页面，不能按名字判空。
    _controller.setTopRoute(hasPage ? name : null);
    final changed = hasPage != _rightStackNotEmpty;
    final clearSelection = !hasPage;
    if (!changed && !clearSelection) return;

    void apply() {
      if (!mounted) return;
      if (changed) setState(() => _rightStackNotEmpty = hasPage);
      if (clearSelection) _controller.select(null);
    }

    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      WidgetsBinding.instance.addPostFrameCallback((_) => apply());
    } else {
      apply();
    }
  }

  Route<dynamic> _generateRoute(RouteSettings settings) {
    if (settings.name == kMyPaneEmptyRoute) {
      return MaterialPageRoute<void>(
        settings: settings,
        builder: (_) => const MyPaneEmptyState(),
      );
    }
    final custom = widget.routeGenerator;
    if (custom != null) return custom(settings);
    final name = settings.name;
    assert(
      name != null && AppRoutes.routes.containsKey(name),
      '「我的」容器收到未注册路由：$name',
    );
    return AppRoutes.generateRoute(settings);
  }

  @override
  Widget build(BuildContext context) {
    final mode = ref.watch(uiSettingsProvider.select((s) => s.multiPaneMode));
    final windowSize = MediaQuery.sizeOf(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final paneSize = Size(constraints.maxWidth, constraints.maxHeight);
        final computed = resolveMultiPane(
          mode,
          paneSize,
          windowSize: windowSize,
        );
        final bool multi;
        if (widget.active || !_modeSeen) {
          multi = computed;
          if (widget.active) {
            _wasMultiPane = computed;
            _modeSeen = true;
          }
        } else {
          // 不可见期间冻结；窗格已容不下双栏时安全回单栏（恢复可见后
          // 再按 computed 判定，不把冻结值当作用户最终选择）。
          multi =
              _wasMultiPane &&
              resolveMultiPane(
                MultiPaneMode.always,
                paneSize,
                windowSize: windowSize,
              );
        }
        return MyPaneScope(
          isMultiPane: multi,
          controller: _controller,
          child: _buildPane(multi),
        );
      },
    );
  }

  Widget _buildPane(bool multi) {
    final showMenuOverlay = !multi && !_rightStackNotEmpty;
    // Row 子项数量/类型保持稳定：单栏时左栏槽位宽度 0，nested Navigator
    // 所在的 Expanded/Stack 不换位，切宽度时右栏栈与页面状态得以保留。
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          key: const ValueKey('my-pane-left-slot'),
          width: multi ? kMultiPaneLeftWidth : 0,
          child: multi
              ? const SettingsScreen(key: ValueKey('my-pane-left-menu'))
              : null,
        ),
        SizedBox(
          key: const ValueKey('my-pane-gap'),
          width: multi ? kMultiPaneGap : 0,
        ),
        Expanded(
          key: const ValueKey('my-pane-right'),
          child: Stack(
            fit: StackFit.expand,
            children: [
              // 单栏空栈时菜单覆盖在 Navigator 上方：Navigator 必须保持
              // 挂载，菜单入口才能继续把页面推进同一栈。
              IgnorePointer(
                ignoring: showMenuOverlay,
                child: ExcludeSemantics(
                  excluding: showMenuOverlay,
                  child: _buildNavigator(),
                ),
              ),
              if (showMenuOverlay)
                const Positioned.fill(
                  child: SettingsScreen(key: ValueKey('my-pane-menu-overlay')),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildNavigator() {
    return Navigator(
      key: _navigatorKey,
      initialRoute: kMyPaneEmptyRoute,
      // 显式只生成一个空态路由：默认的 initialRoutes 会把
      // `/__my_pane_empty__` 拆成 `/` + 目标两页，导致初始栈深 2
      //（canPop 为真、back 会退到一份根首页副本）。
      onGenerateInitialRoutes: (_, _) => [
        MaterialPageRoute<void>(
          settings: const RouteSettings(name: kMyPaneEmptyRoute),
          builder: (_) => const MyPaneEmptyState(),
        ),
      ],
      onGenerateRoute: _generateRoute,
      observers: [_observer],
    );
  }
}

/// 右栏初始空态（未选择左侧项目）
///
/// 用可滚动容器包住文本：大字体/极窄右栏时不溢出。
class MyPaneEmptyState extends StatelessWidget {
  const MyPaneEmptyState({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ColoredBox(
      color: scheme.surface,
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.view_sidebar_rounded,
                size: 40,
                color: scheme.onSurfaceVariant,
              ),
              const SizedBox(height: 12),
              Text(
                '选择左侧项目',
                key: const ValueKey('my-pane-empty'),
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 容器 nested Navigator 观察者：维护栈顶路由设置
class _MyPaneNavigatorObserver extends NavigatorObserver {
  _MyPaneNavigatorObserver(this.onChanged);

  final VoidCallback onChanged;
  final List<Route<dynamic>> _stack = <Route<dynamic>>[];

  RouteSettings? get topSettings =>
      _stack.isEmpty ? null : _stack.last.settings;

  /// 是否有初始空态之外的业务页面（匿名路由也算，不能只看 name）
  bool get hasPage =>
      _stack.isNotEmpty &&
      !(_stack.length == 1 && _stack.single.settings.name == kMyPaneEmptyRoute);

  /// 容器销毁/换 key 时清空，避免残留旧路由
  void clear() => _stack.clear();

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _stack.add(route);
    onChanged();
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _stack.remove(route);
    onChanged();
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _stack.remove(route);
    onChanged();
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    if (newRoute == null) return;
    final index = oldRoute == null ? -1 : _stack.indexOf(oldRoute);
    if (index >= 0) {
      _stack[index] = newRoute;
    } else {
      _stack.add(newRoute);
    }
    onChanged();
  }
}
