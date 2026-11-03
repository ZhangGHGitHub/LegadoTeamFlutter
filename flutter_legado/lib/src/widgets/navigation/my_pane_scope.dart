import 'package:flutter/widgets.dart';

/// 「我的」容器双栏控制器
///
/// 左栏菜单（[SettingsScreen]）经 [MyPaneScope] 取得本控制器：
/// - 双栏激活时，入口 [pushNamed] 推进右栏 nested Navigator，并记录选中项；
/// - 单栏/未挂载时返回 false，调用方回退到 root `Navigator.pushNamed`。
///
/// 右栏栈顶变化由 `AdaptiveMyPane` 内的 NavigatorObserver 回写
/// [selectedRoute]（用于左栏选中高亮与返回后清空）。
class MyPaneController extends ChangeNotifier {
  /// 「我的」容器 nested Navigator 的 key（双栏/单栏均挂载）
  GlobalKey<NavigatorState>? navigatorKey;

  String? _selectedRoute;
  String? _topRoute;

  /// 左栏当前选中/高亮的入口路由名；null = 未选中（空态）
  String? get selectedRoute => _selectedRoute;

  /// 右栏栈顶路由名（空态为 null）；用于重复点击去重
  String? get topRoute => _topRoute;

  /// 右栏 nested Navigator 当前是否可用
  bool get isAttached => navigatorKey?.currentState != null;

  /// 更新选中项（值未变化时不通知，避免无谓重建）
  void select(String? route) {
    if (_selectedRoute == route) return;
    _selectedRoute = route;
    notifyListeners();
  }

  /// Observer 回写栈顶路由（不触发重建）
  void setTopRoute(String? route) {
    _topRoute = route;
  }

  /// 尝试在「我的」容器打开命名路由。
  ///
  /// 单栏/双栏都进同一 nested Navigator（单栏时菜单隐藏、页面全宽）；
  /// 仅当容器未挂载（独立 SettingsScreen / 深链）时返回 false，调用方
  /// 回退 root push。栈顶已是同一路由时去重，避免重复点入口叠页。
  bool pushNamed(String name, {Object? arguments}) {
    final navigator = navigatorKey?.currentState;
    if (navigator == null) return false;
    if (_topRoute == name) return true;
    _topRoute = name;
    select(name);
    navigator.pushNamed(name, arguments: arguments);
    return true;
  }
}

/// 双栏作用域：向「我的」页菜单暴露当前是否双栏与容器控制器。
///
/// 单栏时同样挂载（`isMultiPane=false`）：菜单与页面共用同一个
/// nested Navigator，切换宽度不会丢右栏栈。
class MyPaneScope extends InheritedNotifier<MyPaneController> {
  /// 当前窗口是否处于双栏展示
  final bool isMultiPane;

  const MyPaneScope({
    super.key,
    required this.isMultiPane,
    required MyPaneController controller,
    required super.child,
  }) : super(notifier: controller);

  /// 当前控制器（构造器保证非空）
  MyPaneController get controller => notifier!;

  /// 读取最近的双栏作用域；「我的」页以外（如独立打开 SettingsScreen）返回 null。
  static MyPaneScope? maybeOf(BuildContext context) {
    return context.dependOnInheritedWidgetOfExactType<MyPaneScope>();
  }

  @override
  bool updateShouldNotify(covariant MyPaneScope oldWidget) {
    return oldWidget.isMultiPane != isMultiPane ||
        super.updateShouldNotify(oldWidget);
  }
}
