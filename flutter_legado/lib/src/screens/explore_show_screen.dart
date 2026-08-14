/// 发现分类书籍浏览页面（ExploreShowScreen）
///
/// 参考 Android 原版 ExploreShowActivity.kt 实现：
/// 1. 标题 = 分类名 - 书源名（对标 titleBar.title = exploreName）
/// 2. 顶栏页码控件 + 「加入书架」（已加载书籍批量入架，对标 menuAddLoadedBooks）
/// 3. 下拉刷新 + 上滑翻页加载（ExploreBookList）
/// 4. 点击书籍跳转书籍详情页
///
/// 列表渲染与分页逻辑抽取至 [ExploreBookList]，供平板双栏右栏复用。
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;

import '../models/models.dart';
import '../providers/explore/explore_show_notifier.dart';
import '../providers/providers.dart';
import '../widgets/empty_state.dart';
import '../widgets/explore_book_list.dart';
import '../widgets/explore_page_control.dart';
import '../widgets/legado_app_bar.dart';

/// 路由参数类型转发（routes.dart / explore_screen.dart 依赖）— 保留原导出
export '../providers/explore/explore_show_notifier.dart' show ExploreShowArgs;

/// 发现分类书籍浏览页
class ExploreShowScreen extends ConsumerWidget {
  final ExploreShowArgs? args;

  const ExploreShowScreen({super.key, this.args});

  /// 将已加载书籍批量加入书架（对齐原版 addLoadedBooksToShelf）— 发现页修复 R5
  ///
  /// 经 BookApi.importBooks 批量导入（Rust RoomImporter 判重），
  /// 返回成功数量后提示；无已加载书籍时提示。
  Future<void> _addLoadedBooksToShelf(
    BuildContext context,
    WidgetRef ref,
    ExploreShowArgs args,
  ) async {
    final state = ref.read(exploreShowNotifierProvider(args));
    final books = state.books;
    if (books.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('没有已加载的书籍')),
      );
      return;
    }
    try {
      final jsonArray = jsonEncode([
        for (final b in books)
          Book(
            bookUrl: b.bookUrl,
            tocUrl: b.tocUrl,
            origin: b.origin,
            originName: b.originName,
            name: b.name,
            author: b.author,
            kind: b.kind,
            coverUrl: b.coverUrl,
            intro: b.intro,
            bookType: b.bookType,
            latestChapterTitle: b.latestChapterTitle,
            wordCount: b.wordCount,
          ).toJson(),
      ]);
      final added =
          await ref.read(bookApiProvider).importBooks(jsonArray);
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已加入书架 $added 本')),
      );
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('加入书架失败: $e')),
      );
    }
  }

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
        actions: [
          // 批量加入书架（对标原版 menuAddLoadedBooks；apple-ui-designer
          // 系统图标按钮，次级层级）— 发现页修复 R5
          IconButton(
            tooltip: '加入书架',
            icon: const Icon(Icons.playlist_add),
            onPressed: () => _addLoadedBooksToShelf(context, ref, args),
          ),
          ExplorePageControl(args: args),
        ],
      ),
      body: ExploreBookList(args: args),
    );
  }
}
