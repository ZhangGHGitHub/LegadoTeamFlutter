/// 发现分类书籍浏览页面（ExploreShowScreen）
///
/// 参考 Android 原版 ExploreShowActivity.kt 实现
/// 核心功能：
/// 1. 顶栏显示"分类名 - 书源名"
/// 2. 书籍列表（封面+书名+作者+最新章节）
/// 3. 支持下拉刷新 + 上滑翻页加载
/// 4. 点击书籍跳转书籍详情页
///
/// 列表渲染与分页逻辑抽取至 [ExploreBookList]，供平板双栏右栏复用。
library;

import 'package:flutter/material.dart';
import '../widgets/legado_app_bar.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;

import '../providers/explore/explore_show_notifier.dart';
import '../widgets/empty_state.dart';
import '../widgets/explore_book_list.dart';
import '../widgets/explore_page_control.dart';

// 重新导出路由参数，供 routes.dart 通过本文件引用 ExploreShowArgs
export '../providers/explore/explore_show_notifier.dart' show ExploreShowArgs;

/// 发现分类书籍浏览页
class ExploreShowScreen extends ConsumerWidget {
  /// 路由参数（通过 Navigator.pushNamed 传入）
  final ExploreShowArgs? args;

  const ExploreShowScreen({super.key, this.args});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final args = this.args;
    // 参数缺失兜底（正常路径由 routes.dart 保证非空）
    if (args == null) {
      return Scaffold(
        appBar: LegadoAppBar(title: const Text('')),
        body: const EmptyState(
          icon: Icons.explore_outlined,
          title: '参数错误',
          subtitle: '缺少发现分类参数',
        ),
      );
    }

    // 标题：分类名 - 书源名（对标 Android titleBar.title = exploreName）
    final title = ref.watch(
      exploreShowNotifierProvider(args).select((s) => s.title),
    );

    return Scaffold(
      appBar: LegadoAppBar(
        title: Text(title),
        actions: [ExplorePageControl(args: args)],
      ),
      body: ExploreBookList(args: args),
    );
  }
}
