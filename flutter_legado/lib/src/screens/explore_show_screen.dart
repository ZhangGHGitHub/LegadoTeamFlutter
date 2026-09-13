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
import 'package:material_symbols_icons/symbols.dart';
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
class ExploreShowScreen extends ConsumerStatefulWidget {
  final ExploreShowArgs? args;

  const ExploreShowScreen({super.key, this.args});

  @override
  ConsumerState<ExploreShowScreen> createState() =>
      _ExploreShowScreenState();
}

class _ExploreShowScreenState extends ConsumerState<ExploreShowScreen> {
  /// [A1 对齐 | Qoder UI] 筛选关键字（匹配书名/作者；空=不过滤）
  String _filterKeyword = '';

  /// [A1 对齐 | Qoder UI] 紧凑密度（参考版 ☰ 列表切换语义）
  bool _compact = false;

  ExploreShowArgs? get args => widget.args;

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

  /// [A1 对齐 | Qoder UI] 打开筛选关键字弹层（提交后返回关键字；取消返回 null）
  Future<void> _showFilterDialog() async {
    final keyword = await showDialog<String>(
      context: context,
      builder: (dialogContext) =>
          _ExploreFilterDialog(initial: _filterKeyword),
    );
    if (!mounted) return;
    setState(() => _filterKeyword = keyword ?? _filterKeyword);
  }

  @override
  Widget build(BuildContext context) {
    final ref = this.ref;
    final args = this.args;
    // 参数缺失兜底（正常路径由 routes.dart 保证非空）
    if (args == null) {
      return Scaffold(
        appBar: LegadoAppBar(title: const Text('')),
        body: const EmptyState(
          icon: Symbols.explore_rounded,
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
          // [A1 对齐 | Qoder UI] 筛选漏斗（参考版实心=已开启态）：
          // 本地关键字筛选（匹配书名/作者，作用于已加载列表）
          IconButton(
            tooltip: _filterKeyword.isEmpty
                ? '筛选'
                : '筛选（已开启：$_filterKeyword）',
            onPressed: _showFilterDialog,
            icon: Icon(
              _filterKeyword.isEmpty
                  ? Symbols.filter_alt_off_rounded
                  : Symbols.filter_alt_rounded,
              color: _filterKeyword.isEmpty
                  ? null
                  : Theme.of(context).colorScheme.primary,
            ),
          ),
          // [A1 对齐 | Qoder UI] ☰ 列表切换：书卡密度 舒适/紧凑
          IconButton(
            tooltip: _compact ? '切换为舒适' : '切换为紧凑',
            onPressed: () => setState(() => _compact = !_compact),
            icon: Icon(
              _compact ? Symbols.density_medium_rounded : Symbols.reorder,
            ),
          ),
          // 批量加入书架（对标原版 menuAddLoadedBooks；apple-ui-designer
          // 系统图标按钮，次级层级）— 发现页修复 R5
          IconButton(
            tooltip: '加入书架',
            icon: const Icon(Symbols.playlist_add_rounded),
            onPressed: () => _addLoadedBooksToShelf(context, ref, widget.args!),
          ),
          ExplorePageControl(args: args),
        ],
      ),
      body: ExploreBookList(
        args: args,
        filterKeyword: _filterKeyword,
        compact: _compact,
      ),
    );
  }
}


/// 发现书单筛选关键字弹层（有状态：controller 随弹层 State 建/销）
///
/// [A1 对齐 | Qoder UI] 生命周期与弹层子树严格一致（对齐 2.0.243 D1 修复
/// 模式：controller 不得建在 showDialog 外随 future dispose）。
class _ExploreFilterDialog extends StatefulWidget {
  final String initial;

  const _ExploreFilterDialog({required this.initial});

  @override
  State<_ExploreFilterDialog> createState() => _ExploreFilterDialogState();
}

class _ExploreFilterDialogState extends State<_ExploreFilterDialog> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('筛选'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '按关键字过滤已加载的书籍（匹配书名或作者，忽略英文字母大小写）',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _controller,
            autofocus: true,
            decoration: const InputDecoration(
              hintText: '关键字（留空=不过滤）',
              isDense: true,
              border: OutlineInputBorder(),
            ),
            onSubmitted: (v) => Navigator.of(context).pop(v),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(_controller.text),
          child: const Text('确定'),
        ),
      ],
    );
  }
}
