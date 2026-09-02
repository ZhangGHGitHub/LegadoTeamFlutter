import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import '../widgets/legado_app_bar.dart';
import '../widgets/md3_fast_scroller.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../models/models.dart';
import '../providers/search/search_notifier.dart';
import '../providers/source/source_notifier.dart';
import '../providers/source_check/check_source_notifier.dart';
import '../routes.dart';
import '../services/source_import_service.dart' show SourcePreview;
import '../theme/app_colors.dart';
import '../utils/legado_deep_link.dart';
import '../widgets/empty_state.dart';
import '../widgets/error_view.dart';
import '../widgets/ios_widgets.dart';
import '../widgets/loading_indicator.dart';
import '../widgets/book_source_group_manage_dialog.dart';
import '../widgets/help/help_assets.dart';
import '../widgets/help/show_help.dart';
import '../widgets/confirm_dialog.dart';
import 'association_import_dialog.dart';
import 'source_edit_screen.dart';
import 'js_source_edit_screen.dart';
import 'source_import_confirm_screen.dart';
import 'source_login_screen.dart';
part 'source_screen_builders.part.dart';
part 'source_screen_actions.part.dart';
part 'source_screen_widgets.part.dart';

// ↑ 分域 part 文件（体检 §三.16 超长文件拆分）：非生命周期方法按域拆入 extension，
// 零行为变更（同 library 私有成员可访问）。

/// 书源管理页面
class SourceScreen extends ConsumerStatefulWidget {
  const SourceScreen({super.key});

  @override
  ConsumerState<SourceScreen> createState() => _SourceScreenState();
}

class _SourceScreenState extends ConsumerState<SourceScreen> {
  /// 顶栏搜索框（对标原版 activity_book_source.xml 的 view_search）
  final _searchCtrl = TextEditingController();

  /// 校验会话结束后的总结 SnackBar 是否已展示（防 build 重复触发）
  bool _checkToastShown = false;

  /// 按域名分组显示（对标原版 menu_group_sources_by_domain）
  bool _groupByDomain = false;

  /// 上一帧的校验进行中状态（检测结束瞬间）
  bool _checkingForToast = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // [Task #70 D2 修复 | 2026-08-10] 搜索框 controller 随 State 重建
      //（初始为空），但 filterKeyword 位于全局 sourceNotifierProvider：
      // 若不同步重置，离屏返回时搜索框为空而过滤关键词残留，
      // filteredSources 恒空 → 整表误显示「暂无书源」（69 实机回归
      // D2 观察项根因，重启进程后 provider 重建才恢复） — Qoder
      ref.read(sourceNotifierProvider.notifier).clearFilter();
      ref.read(sourceNotifierProvider.notifier).loadSources();
    });
  }

  /// 长列表快速滚动条联动控制器（对齐原版 FastScroller）
  final ScrollController _listController = ScrollController();

  @override
  void dispose() {
    _searchCtrl.dispose();
    _listController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(sourceNotifierProvider);

    return PopScope(
      canPop: !state.batchMode,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && state.batchMode) {
          ref.read(sourceNotifierProvider.notifier).exitBatchMode();
        }
      },
      child: Scaffold(
        appBar: state.batchMode
            ? _buildBatchAppBar(context, state)
            : _buildAppBar(context, state),
        body: _buildBody(context),
        // 底部常驻批量操作栏（全选/反选/删除/更多选项，
        // 对标原版 SelectActionBar + book_source_sel.xml）；
        // 非批量模式下点击全选/反选会自动进入批量模式
        bottomNavigationBar: _buildBatchBottomBar(context, state),
      ),
    );
  }
}
