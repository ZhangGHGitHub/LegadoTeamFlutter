import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show ImageFilter;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import '../widgets/legado_app_bar.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:share_plus/share_plus.dart';

import '../l10n/app_strings.dart';
import '../models/models.dart';
import '../providers/auto_task/auto_task_notifier.dart';
import '../providers/bookshelf/bookshelf_notifier.dart';
import '../providers/providers.dart';
import '../providers/reader/reader_notifier.dart';
import '../providers/sync/sync_notifier.dart';
import '../routes.dart';
import '../services/book_api.dart';
import '../services/cache_service.dart';
import '../services/platform_bridge_service.dart';
import '../services/settings_service.dart';
import '../utils/book_info_utils.dart';
import '../utils/book_open_utils.dart';
import '../utils/book_progress_utils.dart';
import '../utils/source_login_entry.dart';
import '../utils/source_login_prompt.dart';
import '../widgets/book_cover.dart';
import '../widgets/error_view.dart';
import '../widgets/loading_indicator.dart';
import '../widgets/list_footer.dart';
part 'book_info_screen_load.part.dart';
part 'book_info_screen_builders.part.dart';
part 'book_info_screen_dialogs.part.dart';

// ↑ 分域 part 文件（体检 §三.16 超长文件拆分）：非生命周期方法按域拆入 extension，
// 零行为变更（同 library 私有成员可访问）。

/// 书籍详情页面
class BookInfoScreen extends ConsumerStatefulWidget {
  /// 书籍对象（路由参数规范化：优先使用 Book 对象）
  final Book? book;

  /// 书籍 URL（向后兼容，当未传入 Book 对象时使用）
  final String bookUrl;

  const BookInfoScreen({super.key, this.book, this.bookUrl = ''});

  /// 获取有效的 bookUrl：优先从 Book 对象取值
  String get effectiveBookUrl => book?.bookUrl ?? bookUrl;

  @override
  ConsumerState<BookInfoScreen> createState() => _BookInfoScreenState();
}

class _BookInfoScreenState extends ConsumerState<BookInfoScreen> {
  final ScrollController _scrollController = ScrollController();
  bool _isLoading = false;
  /// 整页首屏：仅在连 Book 壳都没有时显示（对齐原版先 post bookData）
  bool _pageLoading = true;
  /// 目录联网补全中（信息区已可交互）
  bool _tocLoading = false;
  /// 顶栏网络加载（对标原版 refreshProgressBar.isAutoLoading）
  bool _networkLoading = false;
  String? _loadError;
  // 当前书籍（供 AppBar 溢出菜单读取勾选态）
  Book? _loadedBook;
  List<BookChapter> _chapters = const [];
  // 当前书源（供溢出菜单条件项：设置变量/允许更新/登录/创建更新任务判定）
  BookSource? _bookSource;
  // 书架状态（对标原版 tv_shelf 加入书架/移出书架切换）
  bool _inBookshelf = false;
  // [UI-FIX v2.0.3 | 2026-08-08] 删除提醒开关（对齐原版 LocalConfig.deleteBookAlert，本地持久化） — Qoder
  // 书源按 origin 缓存，避免每次详情页全量扫描书源列表
  static final Map<String, BookSource?> _sourceByOriginCache = {};
  SettingsService get _settingsService => ref.read(settingsProvider);
  bool _deleteBookAlert = true;

  @override
  void initState() {
    super.initState();
    // 发现/搜索带入的 Book 立刻上屏（对齐原版 bookData.postValue 先于网络）
    _loadedBook = widget.book;
    _pageLoading = widget.book == null && widget.effectiveBookUrl.isEmpty;
    _loadData();
    _loadDeleteBookAlert();
    PlatformBridgeService.refreshSignal.addListener(_onBridgeRefresh);
  }

  @override
  void dispose() {
    PlatformBridgeService.refreshSignal.removeListener(_onBridgeRefresh);
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 对标原版 activity_book_info.xml：封面背景 + 半透明遮罩 + 深色 TitleBar
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: LegadoAppBar(
        title: const Text('书籍信息'),
        backgroundColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        // [审计修复 §3.3] 改用 Theme Token（沉浸式封面背景上仍为白色系） — Qoder
        foregroundColor: Theme.of(context).colorScheme.onPrimary,
        actions: [
          // 编辑：仅在架书籍显示（对标原版 editMenuItem.isVisible = inBookshelf）
          if (_inBookshelf)
            IconButton(
              icon: const Icon(Symbols.edit_rounded),
              tooltip: '编辑书籍信息',
              onPressed: () async {
                try {
                  final book = _loadedBook;
                  if (book == null) return;
                  if (!context.mounted) return;
                  // [fix Task#24 | 2026-08-08] 去掉 <bool> 泛型，避免 routes 表
                  // MaterialPageRoute<dynamic> 运行时强转崩溃 — Qoder
                  final saved = await Navigator.pushNamed(
                    context,
                    AppRoutes.editBookInfo,
                    arguments: book,
                  );
                  // 编辑保存成功后重新加载书籍信息
                  if (saved == true && mounted) {
                    _reload();
                  }
                } catch (e) {
                  // [审计修复 §4.1] 不再静默吞异常，向用户提示 — Qoder
                  debugPrint('编辑书籍信息失败: $e');
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('书籍信息暂不可用，请稍后重试')),
                    );
                  }
                }
              },
            ),
          IconButton(
            icon: const Icon(Symbols.ios_share_rounded),
            tooltip: '分享',
            onPressed: () async {
              try {
                final book = _loadedBook;
                if (book == null) return;
                // 对齐原版 menu_share_it：bookUrl#bookJson + SourceCallBack
                // — Cursor UI
                final shareStr =
                    '${book.bookUrl}#${jsonEncode(book.toJson())}';
                final api = ref.read(bookApiProvider);
                final r = await api.sourceCallBackBtn(
                  event: 'clickShareBook',
                  bookUrl: book.bookUrl,
                  bookType: book.bookType,
                  result: shareStr,
                );
                final invoked = r['invoked'] == true;
                final jsTrue = r['jsTrue'] == true;
                if (!invoked || !jsTrue) {
                  await Share.share(shareStr);
                }
              } catch (e) {
                // [审计修复 §4.1] 不再静默吞异常，向用户提示 — Qoder
                debugPrint('分享书籍失败: $e');
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('书籍信息暂不可用，请稍后重试')),
                  );
                }
              }
            },
          ),
          if (_bookSource?.customButton == true)
            IconButton(
              icon: const Icon(Symbols.extension_rounded),
              tooltip: '自定义',
              onPressed: _onCustomButton,
            ),
          // 安卓原版三点菜单；P2-2 自定义按钮已接通 callBackBtn 中途 UI 桥
          PopupMenuButton<String>(
            tooltip: '更多',
            onSelected: _handleMenu,
            itemBuilder: (_) {
              final book = _loadedBook;
              final source = _bookSource;
              final hasSource = source != null;
              final isLocal = book != null && !_isOnlineBook(book);
              final isLocalTxt = book != null && _isLocalTxt(book);
              final hasLogin = (source?.loginUrl ?? '').isNotEmpty;
              final canUpd = book?.canUpdate ?? true;
              return [
                if (source?.customButton == true)
                  const PopupMenuItem(value: 'customBtn', child: Text('自定义')),
                if (isLocal)
                  const PopupMenuItem(value: 'upload', child: Text('上传至远程')),
                const PopupMenuItem(value: 'refresh', child: Text('刷新')),
                // 创建书籍更新任务（在架 + 书源 + 非本地 + 允许更新；
                // [Task #39 §5.11-2] 已接通 AutoTaskScreen 编辑/创建流程）
                if (_inBookshelf && hasSource && !isLocal && canUpd)
                  const PopupMenuItem(
                    value: 'updateTask',
                    child: Text('创建书籍更新任务'),
                  ),
                // 登录（书源支持登录时）
                if (hasLogin)
                  const PopupMenuItem(value: 'login', child: Text('登录')),
                const PopupMenuItem(value: 'top', child: Text('置顶')),
                // 设置源变量（Task #63 冻结 / #64-65 实现，§5.11-3 已接通 setSourceVariable）/
                // 设置书籍变量
                //（[Task #39 §5.11-4] 已接通变量对话框 + updateBook 保存）
                if (hasSource)
                  const PopupMenuItem(
                    value: 'sourceVariable',
                    child: Text('设置源变量'),
                  ),
                if (hasSource)
                  const PopupMenuItem(
                    value: 'bookVariable',
                    child: Text('设置书籍变量'),
                  ),
                const PopupMenuItem(
                    value: 'copyBookUrl', child: Text('拷贝书籍URL')),
                const PopupMenuItem(
                    value: 'copyTocUrl', child: Text('拷贝目录URL')),
                // 允许更新（书源存在；勾选态）
                if (hasSource)
                  CheckedPopupMenuItem(
                    value: 'canUpdate',
                    checked: book?.canUpdate ?? true,
                    child: const Text('允许更新'),
                  ),
                // 拆分长章节（仅本地 txt；勾选态）
                if (isLocalTxt)
                  CheckedPopupMenuItem(
                    value: 'splitLongChapter',
                    // isLocalTxt 已隐含 book != null（由 isLocal 推导），book 已提升为非空
                    checked: book.readConfig?.splitLongChapter ?? true,
                    child: const Text('拆分长章节'),
                  ),
                // [UI-fix v2.0.3 | 2026-08-08] 删除提醒接通本地持久化
                // （对齐原版 LocalConfig.deleteBookAlert） — Qoder
                CheckedPopupMenuItem(
                  value: 'deleteAlert',
                  checked: _deleteBookAlert,
                  child: const Text('删除提醒'),
                ),
                const PopupMenuItem(
                    value: 'clearCache', child: Text('清理缓存')),
                const PopupMenuItem(
                    value: 'cacheDownloads', child: Text('缓存下载队列')),
                const PopupMenuItem(value: 'log', child: Text('日志')),
              ];
            },
          ),
        ],
      ),
      body: _pageLoading
          ? const LoadingIndicator(message: '加载书籍信息...')
          : _loadError != null && _loadedBook == null
              ? ErrorView(
                  message: _loadError!,
                  onRetry: _reload,
                )
              : _loadedBook == null
                  ? const ErrorView(message: '书籍不存在')
                  : _buildPage(context, _loadedBook!, _chapters),
      bottomNavigationBar: _buildBottomBar(),
    );
  }
}
