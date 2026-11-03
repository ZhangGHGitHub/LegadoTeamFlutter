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
/// 窗口重新变宽后原样恢复；清空时机为：切换 Tab、左列表选择替换
///（`replace: true`）、root standalone 前显式 [clear]。
///
/// 左列表选择（书架/发现书单/RSS 源列表）使用 `replace: true`：先清空
/// 右栏再压入，等价参考版 `selectMainPaneChild` 的「左栏选择替换详情」；
/// 右栏内部下钻（BookInfo → 目录、RSS 文章列表 → 文章）保持追加。
class MainDetailPaneController extends ChangeNotifier {
  /// 右栏 nested Navigator 的 key（隐藏期间同样挂载）
  GlobalKey<NavigatorState>? navigatorKey;

  bool _isEnabled = false;
  bool _hasStack = false;
  bool _disposed = false;
  int _stackDepth = 0;

  /// 当前 Tab（来源令牌）：左列表入口在 await 后据此校验来源是否仍有效
  Object? _activeSource;

  /// 当前右栏栈所属来源 Tab（首次压栈时记录，用于横滑 settle 后清栈）
  Object? _stackSource;

  /// 当前窗口/当前 Tab 是否允许使用右栏（build 期间由 HomeScreen 写入，
  /// 不通知：显隐由 HomeScreen 自身的布局构建驱动）。
  bool get isEnabled => _isEnabled;

  /// 右栏是否有初始空态之外的业务页面
  bool get hasStack => _hasStack;

  /// 右栏当前是否可见（多栏可用且栈非空）；右栏页面据此判定自身是否
  /// 真正展示（如隐藏期间不得触发自动开读）。
  bool get isPaneVisible => _isEnabled && _hasStack;

  /// 右栏栈所属来源（无栈为 null）
  Object? get stackSource => _stackSource;

  /// 测试观测：右栏栈深度（0=未挂载，1=仅初始空态，>1=有业务页面）
  @visibleForTesting
  int get stackDepth => _stackDepth;

  /// build 期间写入（静默，不触发通知，避免布局阶段 setState）
  void setEnabled(bool value) {
    _isEnabled = value;
  }

  /// 当前 Tab 变化（静默；供异步入口在 await 后比对来源）
  void setActiveSource(Object? value) {
    _activeSource = value;
  }

  /// Observer 回写栈状态
  ///
  /// 栈变化可能发生在 build/layout 帧内（如页面 initState 里 push），
  /// 此时延后到帧末通知，避免监听者（HomeScreen）在布局阶段 setState。
  void updateStack({required int depth, required bool hasPage}) {
    if (_disposed) return;
    _stackDepth = depth;
    if (!hasPage) _stackSource = null;
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

  /// 来源令牌是否仍有效（null = 调用方未提供令牌，不校验）
  bool isSourceCurrent(Object? source) =>
      source == null || _activeSource == null || source == _activeSource;

  /// 在多栏右栏打开命名路由；不可用时退回 root 全屏。
  ///
  /// [replace]：左列表选择语义——先清空右栏再压入（窄屏时同时清掉隐藏
  /// 的旧栈）；[source]：来源 Tab 令牌，await 完成后 Tab 已切换则丢弃。
  Future<T?> openNamed<T>(
    BuildContext context,
    String name, {
    Object? arguments,
    bool replace = false,
    Object? source,
  }) {
    if (!isSourceCurrent(source)) return Future<T?>.value();
    final navigator = navigatorKey?.currentState;
    if (_isEnabled && navigator != null) {
      if (replace) _popToEmpty();
      _stackSource = source ?? _activeSource;
      return navigator.pushNamed<T>(name, arguments: arguments);
    }
    if (replace) _popToEmpty();
    return Navigator.of(
      context,
      rootNavigator: true,
    ).pushNamed<T>(name, arguments: arguments);
  }

  /// 在多栏右栏打开构建器页面（RSS 文章详情等无全局命名路由的页面）；
  /// 不可用时退回 root 全屏。参数语义同 [openNamed]。
  Future<T?> openPage<T>(
    BuildContext context,
    WidgetBuilder builder, {
    RouteSettings? settings,
    bool replace = false,
    Object? source,
  }) {
    if (!isSourceCurrent(source)) return Future<T?>.value();
    final navigator = navigatorKey?.currentState;
    if (_isEnabled && navigator != null) {
      if (replace) _popToEmpty();
      _stackSource = source ?? _activeSource;
      return navigator.push<T>(
        MaterialPageRoute<T>(builder: builder, settings: settings),
      );
    }
    if (replace) _popToEmpty();
    return Navigator.of(context, rootNavigator: true).push<T>(
      MaterialPageRoute<T>(builder: builder, settings: settings),
    );
  }

  /// 清空右栏（回到初始空态）；切换 Tab / 左列表替换时调用。
  void clear() {
    _stackSource = null;
    _popToEmpty();
  }

  void _popToEmpty() {
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
  bool replace = false,
  Object? source,
}) {
  final scope = MainDetailPaneScope.maybeOf(context);
  if (scope != null) {
    return scope.controller.openNamed<T>(
      context,
      name,
      arguments: arguments,
      replace: replace,
      source: source,
    );
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
  bool replace = false,
  Object? source,
}) {
  final scope = MainDetailPaneScope.maybeOf(context);
  if (scope != null) {
    return scope.controller.openPage<T>(
      context,
      builder,
      settings: settings,
      replace: replace,
      source: source,
    );
  }
  return Navigator.of(context, rootNavigator: true).push<T>(
    MaterialPageRoute<T>(builder: builder, settings: settings),
  );
}

/// 来源令牌是否仍有效：右栏作用域外（独立页面/深链）恒为 true。
bool isMainDetailSourceCurrent(BuildContext context, Object source) {
  final scope = MainDetailPaneScope.maybeOf(context);
  return scope == null || scope.controller.isSourceCurrent(source);
}

/// 清空首页右栏（root standalone 前调用；作用域外 no-op）。
void clearMainDetailPane(BuildContext context) {
  MainDetailPaneScope.maybeOf(context)?.controller.clear();
}
