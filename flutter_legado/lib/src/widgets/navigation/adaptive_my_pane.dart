import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;

import '../../providers/ui_settings/ui_settings_notifier.dart';
import '../../routes.dart';
import '../../screens/settings_screen.dart';
import '../../utils/multi_pane_layout.dart';
import 'my_pane_scope.dart';

/// 右栏初始（空态）路由名；`AppRoutes` 中不存在，避免与业务路由冲突。
const String kMyPaneEmptyRoute = '/__my_pane_empty__';

/// 「我的」页容器：按 `multiPaneMode` + 当前窗口尺寸在双栏/单栏间切换。
///
/// 双栏结构（对齐参考版 `ListDetailSceneStrategy` 的容器左栏 + 详情右栏）：
/// - 左：`SettingsScreen` 菜单，固定 360dp、自身可滚动；
/// - 中间：24dp 间距；
/// - 右：nested `Navigator`（`AppRoutes.generateRoute`），初始为空态
///   「选择左侧项目」，右栏页面继续 push 时自然留在该 Navigator。
///
/// 单栏（窄窗口 / `off`）保持批次前行为：只渲染 `SettingsScreen`，菜单入口
/// 走 root `Navigator.pushNamed`。
///
/// 窄高/窗口宽度不足时不进入双栏（[resolveMultiPane] 的最小尺寸约束）。
/// 双栏 → 单栏（旋转、拖拽窗口或改设置）时，若右栏栈非空，把**栈顶命名
/// 路由**转推到 root（保留用户当前页面），右栏栈随后随 nested Navigator
/// 卸载清空；无法还原的匿名路由（`RouteSettings.name == null`）只清空并
/// 回到菜单。双栏 → 单栏发生在「我的」页不可见时延迟到再次可见时处理。
class AdaptiveMyPane extends ConsumerStatefulWidget {
  const AdaptiveMyPane({
    super.key,
    this.navigatorKey,
    this.routeGenerator,
    this.active = true,
  });

  /// 右栏 nested Navigator 的 key（首页返回键据此优先 pop 右栏）
  final GlobalKey<NavigatorState>? navigatorKey;

  /// 路由生成器（默认 [AppRoutes.generateRoute]；测试可注入桩页面）
  ///
  /// 不用 Flutter 的 `RouteFactory`：其返回类型为 `Route<dynamic>?`，
  /// 而 nested Navigator 的 `onGenerateRoute` 契约要求非空路由。
  final Route<dynamic> Function(RouteSettings)? routeGenerator;

  /// 「我的」页当前是否可见：不可见时不做双栏 → 单栏的 root 转推，
  /// 避免在其它页签上凭空弹出页面。
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

  /// 上一次收到的双栏形态（仅在 [AdaptiveMyPane.active] 时更新）
  bool _wasMultiPane = false;

  /// 右栏当前栈顶路由设置（用于双栏 → 单栏时转推 root）
  RouteSettings? _lastRightSettings;

  @override
  void initState() {
    super.initState();
    _controller.navigatorKey = _navigatorKey;
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// 右栏栈顶变化：记录栈顶设置；右栏回到空态时清空左栏选中项
  ///
  /// 选中项只在左栏点击时写入（[MyPaneController.pushNamed]），不随右栏
  /// 内部下钻（设置 → 外观）改变——左栏高亮的是「从哪个入口进来的」。
  /// 观察回调可能发生在 Navigator 的构建帧内（初始空态路由），直接
  /// `notifyListeners()` 会在 build 期间标记左栏重建，故延迟到帧末。
  void _onRightStackChanged() {
    _lastRightSettings = _observer.topSettings;
    final name = _observer.topSettings?.name;
    if (name != null && name != kMyPaneEmptyRoute) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _controller.select(null);
    });
  }

  void _handleModeTransition(bool multi) {
    if (_wasMultiPane == multi) return;
    _wasMultiPane = multi;
    if (multi) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _controller.select(null);
      });
      return;
    }
    // 双栏 → 单栏：nested Navigator 即将卸载，先同步取出栈顶路由设置。
    final settings = _lastRightSettings;
    _lastRightSettings = null;
    final name = settings?.name;
    final shouldPushRoot = name != null && name != kMyPaneEmptyRoute;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _controller.select(null);
      if (!shouldPushRoot) return;
      Navigator.of(
        context,
        rootNavigator: true,
      ).pushNamed(name, arguments: settings!.arguments);
    });
  }

  Route<dynamic> _generateRoute(RouteSettings settings) {
    if (settings.name == kMyPaneEmptyRoute) {
      return MaterialPageRoute<void>(
        settings: settings,
        builder: (_) => const MyPaneEmptyState(),
      );
    }
    return (widget.routeGenerator ?? AppRoutes.generateRoute)(settings);
  }

  @override
  Widget build(BuildContext context) {
    final mode = ref.watch(uiSettingsProvider.select((s) => s.multiPaneMode));
    return LayoutBuilder(
      builder: (context, constraints) {
        final multi = resolveMultiPane(
          mode,
          Size(constraints.maxWidth, constraints.maxHeight),
        );
        // 不可见时保持上一次形态：窗口变化留到再次可见时统一处理，
        // 避免在其它页签上把右栏页面转推到 root。
        if (widget.active) _handleModeTransition(multi);
        return MyPaneScope(
          isMultiPane: multi,
          controller: _controller,
          child: multi ? _buildDualPane() : const SettingsScreen(),
        );
      },
    );
  }

  Widget _buildDualPane() {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          key: const ValueKey('my-pane-left'),
          width: kMultiPaneLeftWidth,
          child: const SettingsScreen(),
        ),
        const SizedBox(key: ValueKey('my-pane-gap'), width: kMultiPaneGap),
        Expanded(
          key: const ValueKey('my-pane-right'),
          child: ClipRect(
            child: Navigator(
              key: _navigatorKey,
              initialRoute: kMyPaneEmptyRoute,
              // 显式只生成一个空态路由：默认的 initialRoutes 会把
              // `/__my_pane_empty__` 拆成 `/` + 目标两页，导致右栏初始
              // 栈深 2（canPop 为真、back 会退到一份根首页副本）。
              onGenerateInitialRoutes: (_, _) => [
                MaterialPageRoute<void>(
                  settings: const RouteSettings(name: kMyPaneEmptyRoute),
                  builder: (_) => const MyPaneEmptyState(),
                ),
              ],
              onGenerateRoute: _generateRoute,
              observers: [_observer],
            ),
          ),
        ),
      ],
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

/// 右栏 nested Navigator 观察者：维护栈顶路由设置
class _MyPaneNavigatorObserver extends NavigatorObserver {
  _MyPaneNavigatorObserver(this.onChanged);

  final VoidCallback onChanged;
  final List<Route<dynamic>> _stack = <Route<dynamic>>[];

  RouteSettings? get topSettings =>
      _stack.isEmpty ? null : _stack.last.settings;

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
