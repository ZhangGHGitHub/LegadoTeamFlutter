import 'package:flutter/material.dart';

/// 全局路由观察器：为「返回重现时需刷新」的页面提供路由回调。
///
/// 对齐原版 ChapterListFragment 经 EventBus.SAVE_CONTENT 增量刷新目录
/// 云图标的语义：从阅读器返回目录页（同一页面实例重现）时，阅读过程
/// 中写入的缓存章节应立即体现为实心云图标、当前章节信息同步更新。
final RouteObserver<ModalRoute<void>> appRouteObserver =
    RouteObserver<ModalRoute<void>>();
