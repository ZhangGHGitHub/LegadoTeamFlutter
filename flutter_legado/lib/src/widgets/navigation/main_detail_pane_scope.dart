import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

/// 右栏初始（空态）路由名；`AppRoutes` 中不存在，避免与业务路由冲突。
const String kMainDetailEmptyRoute = '/__main_detail_empty__';

/// 首页主 Tab（书架/发现/RSS）列表-详情右侧栏控制器
///
/// 对齐参考版 `ListDetailSceneStrategy` 的容器左列表 + 详情右栏：
/// - [openNamed] / [openPage]：多栏可用时推进右侧 nested Navigator；
///   窄屏 / 多栏关闭 / 未挂载时退回 root 全屏（与原行为一致）；
/// - [isEnabled] 由 HomeScreen 按「当前 Tab 支持列表-详情 + 多栏判定」写入；
/// - [hasStack] 由右栏 NavigatorObserver 回写，HomeScreen 据此决定是否占位；
/// - [clear]：切换 Tab 时清空右栏（登记行为）。
///
/// 右栏 Navigator 始终挂载（隐藏时零宽 + Offstage），窄屏期间保留的栈在
/// 窗口重新变宽后原样恢复；只有切换 Tab 才清空。
class MainDetailPaneController extends ChangeNotifier {
  /// 右栏 nested Navigator 的 key（隐藏期间同样挂载）
  GlobalKey<NavigatorState>? navigatorKey;

  bool _isEnabled = false;
  bool _hasStack = false;
  bool _disposed = false;
  int _stackDepth = 0;

  /// 当前窗口/当前 Tab 是否允许使用右栏（build 期间由 HomeScreen 写入，
  /// 不通知：显隐由 HomeScreen 自身的布局构建驱动）。
  bool get isEnabled => _isEnabled;

  /// 右栏是否有初始空态之外的业务页面
  bool get hasStack => _hasStack;

  /// 测试观测：右栏栈深度（0=未挂载，1=仅初始空态，>1=有业务页面）
  @visibleForTesting
  int get stackDepth => _stackDepth;

  /// build 期间写入（静默，不触发通知，避免布局阶段 setState）
  void setEnabled(bool value) {
    _isEnabled = value;
  }

  /// Observer 回写栈状态
  ///
  /// 栈变化可能发生在 build/layout 帧内（如页面 initState 里 push），
  /// 此时延后到帧末通知，避免监听者（HomeScreen）在布局阶段 setState。
  void updateStack({required int depth, required bool hasPage}) {
    if (_disposed) return;
    _stackDepth = depth;
    if (_hasStack == hasPage) return;
    _hasStack = hasPage;
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_disposed) return;
        notifyListeners();
      });
    } else {
      notifyListeners();
    }
  }

  /// 在多栏右栏打开命名路由；不可用时退回 root 全屏。
  Future<T?> openNamed<T>(
    BuildContext context,
    String name, {
    Object? arguments,
  }) {
    final navigator = navigatorKey?.currentState;
    if (_isEnabled && navigator != null) {
      return navigator.pushNamed<T>(name, arguments: arguments);
    }
    return Navigator.of(
      context,
      rootNavigator: true,
    ).pushNamed<T>(name, arguments: arguments);
  }

  /// 在多栏右栏打开构建器页面（RSS 文章详情等无全局命名路由的页面）；
  /// 不可用时退回 root 全屏。
  Future<T?> openPage<T>(
    BuildContext context,
    WidgetBuilder builder, {
    RouteSettings? settings,
  }) {
    final navigator = navigatorKey?.currentState;
    if (_isEnabled && navigator != null) {
      return navigator.push<T>(
        MaterialPageRoute<T>(builder: builder, settings: settings),
      );
    }
    return Navigator.of(context, rootNavigator: true).push<T>(
      MaterialPageRoute<T>(builder: builder, settings: settings),
    );
  }

  /// 清空右栏（回到初始空态）；切换 Tab 时调用。
  void clear() {
    final navigator = navigatorKey?.currentState;
    if (navigator == null) return;
    navigator.popUntil((route) => route.isFirst);
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

/// 首页列表-详情作用域：向书架/发现/RSS 页暴露右栏控制器。
///
/// 使用 [getInheritedWidgetOfExactType] 读取（不建立依赖）：列表项回调
/// 只在点击时取控制器，不需要因右栏栈变化重建整页列表。
class MainDetailPaneScope extends InheritedNotifier<MainDetailPaneController> {
  /// 当前窗口是否处于列表-详情双栏
  final bool isMultiPane;

  const MainDetailPaneScope({
    super.key,
    required this.isMultiPane,
    required MainDetailPaneController controller,
    required super.child,
  }) : super(notifier: controller);

  /// 当前控制器（构造器保证非空）
  MainDetailPaneController get controller => notifier!;

  /// 读取最近的列表-详情作用域；作用域外（独立打开的页面/深链）返回 null。
  static MainDetailPaneScope? maybeOf(BuildContext context) {
    return context.getInheritedWidgetOfExactType<MainDetailPaneScope>();
  }

  @override
  bool updateShouldNotify(covariant MainDetailPaneScope oldWidget) {
    return oldWidget.isMultiPane != isMultiPane ||
        super.updateShouldNotify(oldWidget);
  }
}

/// 书架/发现列表的「打开书籍详情」入口：多栏可用走右栏，否则 root 全屏。
Future<T?> pushMainDetailNamed<T>(
  BuildContext context,
  String name, {
  Object? arguments,
}) {
  final scope = MainDetailPaneScope.maybeOf(context);
  if (scope != null) {
    return scope.controller.openNamed<T>(context, name, arguments: arguments);
  }
  return Navigator.of(
    context,
    rootNavigator: true,
  ).pushNamed<T>(name, arguments: arguments);
}

/// RSS 等无全局命名路由的列表入口：多栏可用走右栏，否则 root 全屏。
Future<T?> pushMainDetailPage<T>(
  BuildContext context,
  WidgetBuilder builder, {
  RouteSettings? settings,
}) {
  final scope = MainDetailPaneScope.maybeOf(context);
  if (scope != null) {
    return scope.controller.openPage<T>(context, builder, settings: settings);
  }
  return Navigator.of(context, rootNavigator: true).push<T>(
    MaterialPageRoute<T>(builder: builder, settings: settings),
  );
}
