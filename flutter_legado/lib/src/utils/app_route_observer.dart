import 'package:flutter/material.dart';

/// 全局路由观察器：为「返回重现时需刷新」的页面提供路由回调。
///
/// 对齐原版 ChapterListFragment 经 EventBus.SAVE_CONTENT 增量刷新目录
/// 云图标的语义：从阅读器返回目录页（同一页面实例重现）时，阅读过程
/// 中写入的缓存章节应立即体现为实心云图标、当前章节信息同步更新。
final RouteObserver<ModalRoute<void>> appRouteObserver =
    RouteObserver<ModalRoute<void>>();

/// 只观察「不透明页面级路由」的路由观察器（批9c 复审 P2）
///
/// 书架用它判定「是否真正离开书架去看了另一个页面」。DialogRoute /
/// ModalBottomSheetRoute / PopupMenuRoute / `_CardMenuRoute`（opaque=false）
/// 都是浮层，不能触发分组私密授权撤销（否则打开菜单就重新上锁）。
/// [PageRoute.opaque] 为 false 的卡片菜单同样被排除。
class OpaquePageRouteObserver extends RouteObserver<ModalRoute<void>> {
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (route is PageRoute<dynamic> && route.opaque) {
      super.didPush(route, previousRoute);
    }
  }
}

/// 全局不透明页面路由观察器（需注册进 MaterialApp.navigatorObservers）
final OpaquePageRouteObserver opaquePageRouteObserver =
    OpaquePageRouteObserver();
