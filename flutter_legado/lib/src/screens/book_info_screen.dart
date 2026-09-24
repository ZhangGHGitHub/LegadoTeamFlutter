import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show ImageFilter;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
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
import '../providers/ui_settings/ui_settings_notifier.dart';
import '../widgets/legado_app_bar.dart';
import '../widgets/top_bar_button.dart';
import '../services/cover_palette_service.dart';
import '../services/book_api.dart';
import '../services/cache_service.dart';
import '../services/local_book_store.dart'; // [iOS 视角F C1] 本地书相对标识解析
import '../services/platform_bridge_service.dart';
import '../services/settings_service.dart';
import '../utils/book_info_utils.dart';
import '../utils/book_open_utils.dart';
import '../utils/meaningful_text_guard.dart'; // [U4 | 台账 0917] 详情页渲染层模板残留守卫
// [08 元信息区对齐 | 台账 0922 修订] book_progress_utils 导入已随「目录：已读 X%」
// 行移除而不再使用（工具本身保留：book_list_item 仍用，单测保留）
import '../utils/source_login_entry.dart';
import '../utils/source_login_prompt.dart';
import '../widgets/book_cover.dart';
import '../widgets/custom_refresh_indicator.dart'; // [LAYOUT_PLAN P4 收尾] 详情下拉 M3 化
import '../widgets/error_view.dart';
import '../widgets/skeleton.dart'; // [LAYOUT_PLAN P4] 首屏 Skeleton 接线
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

  /// [A4 对齐 B | 2026-09-21 裁决] 进入后目录就绪即自动打开阅读器
  ///（等价重构版 `BookInfoPage(openReaderImmediately: true)`：书架未读书
  ///单击入口）；目录不可用则停留在详情页，仍可经「阅读」FAB 手动开读。
  /// 默认 false，既有入口（长按封面/书名、阅读记录、搜索等）行为不变。
  final bool openReaderImmediately;

  const BookInfoScreen({
    super.key,
    this.book,
    this.bookUrl = '',
    this.openReaderImmediately = false,
  });

  /// 获取有效的 bookUrl：优先从 Book 对象取值
  String get effectiveBookUrl => book?.bookUrl ?? bookUrl;

  @override
  ConsumerState<BookInfoScreen> createState() => _BookInfoScreenState();
}

class _BookInfoScreenState extends ConsumerState<BookInfoScreen> {
  final ScrollController _scrollController = ScrollController();
  /// [UI_SYNC_REFACTOR B4] 顶栏折叠进度（对齐参考仓 collapsedFraction：
  /// 封面区滚动归一化，驱动透明→玻璃色插值）
  final ValueNotifier<double> _topCollapse = ValueNotifier<double>(0);
  /// [UI_SYNC_REFACTOR B4] 封面取色 seed（null=未取/关闭开关）
  Color? _coverSeed;
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
  // [A4 对齐 B | 2026-09-21 裁决；2026-09-22 review 硬化] 自动开读机会
  // 是否已消费：首轮全量加载完成时无条件置位（机会只属于首入——目录非空
  // 才真正自动开读，目录为空则停留详情页）；此后 _reload / 桥接刷新 /
  // 菜单刷新不再触发（对标重构版 BookInfoPage._autoStartScheduled）。
  // postFrame 回调内另有 ModalRoute 栈顶校验，防用户抢先导航后二次压栈。
  bool _autoStartScheduled = false;
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
    // [UI_SYNC_REFACTOR B4] 封面区滚动 → 顶栏折叠进度（对齐参考仓
    // exitUntilCollapsed 的 collapsedFraction，120px 归一区间）
    _scrollController.addListener(() {
      final offset = _scrollController.hasClients
          ? _scrollController.offset
          : 0.0;
      final fraction = (offset / 120).clamp(0.0, 1.0);
      if ((fraction - _topCollapse.value).abs() > 0.01) {
        _topCollapse.value = fraction;
      }
    });
    if (_loadedBook != null) {
      unawaited(_extractCoverSeed(_loadedBook!));
    }
  }

  @override
  void dispose() {
    PlatformBridgeService.refreshSignal.removeListener(_onBridgeRefresh);
    _scrollController.dispose();
    _topCollapse.dispose();
    super.dispose();
  }

  /// [UI_SYNC_REFACTOR B4] 封面取色（跟随封面换肤开关开启时生效）
  Future<void> _extractCoverSeed(Book book) async {
    final ui = uiSettingsListenable.value;
    if (!ui.bookInfoFollowCoverColor) return;
    final coverUrl = book.customCoverUrl ?? book.coverUrl;
    if (coverUrl == null || coverUrl.isEmpty) return;
    final seed = await CoverPaletteService.extractSeed(coverUrl);
    if (!mounted) return;
    setState(() => _coverSeed = seed);
  }


  /// [PARITY C1 D3] 右下绿色「阅读」胶囊 FAB（对齐参考 08 量化：
  /// 约 101×55dp 绿底 (175,242,196) / 深绿字 (11,81,48)，右 18dp / 底 17dp；
  /// 标签固定「阅读」（原「继续阅读」文案移除，参考即固定「阅读」）；
  /// 阅读跳转链路 _openReader 行为不变，续读位置仍取 durChapterIndex，
  /// 加书架/移出书架入口保留在操作区第一卡）
  Widget _buildReadFab() {
    final book = _loadedBook;
    if (book == null) return const SizedBox.shrink();
    return FloatingActionButton.extended(
      backgroundColor: const Color(0xFFAFF2C4),
      foregroundColor: const Color(0xFF0B5130),
      icon: const Icon(Symbols.menu_book_rounded),
      label: const Text('阅读'),
      onPressed: () => _openReader(context, book, book.durChapterIndex),
    );
  }

  /// [UI_SYNC_REFACTOR B4] 顶栏 actions（原 appBar actions 原样迁移，
  /// 由折叠 SliverAppBar 经 TopBarActionStyler 统一注入样式）
  List<Widget> _buildTopBarActions() {
    return [
      // 编辑：仅在架书籍显示（对标原版 editMenuItem.isVisible = inBookshelf）
      if (_inBookshelf)
        IconButton(
          icon: const Icon(Symbols.edit_rounded),
          tooltip: '编辑书籍信息',
          onPressed: () async {
            try {
              final book = _loadedBook;
              if (book == null) return;
              if (!mounted) return;
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
              if (mounted) {
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
            if (mounted) {
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
          final cs = Theme.of(context).colorScheme;
          // [U1 | 台账 0917] 勾选项尾部化：CheckboxListTile 式右侧 ✓
          //（对齐参考 08 勾选项尾样式；原 CheckedPopupMenuItem 为 leading ✓）
          PopupMenuItem<String> checkedItem(
              String value, String label, bool checked) {
            return PopupMenuItem<String>(
              value: value,
              child: Row(
                children: [
                  Expanded(child: Text(label)),
                  if (checked)
                    Icon(Symbols.check_rounded, size: 18, color: cs.primary),
                ],
              ),
            );
          }

          return [
            // ── 前段：对齐参考 08 菜单项序（U1 | 台账 0917）──
            // 编辑（顶栏编辑图标仅架上书显示；菜单项全量可用——能力已存在，
            // 非功能新增；_handleMenu 'edit' 逻辑同顶栏图标）
            const PopupMenuItem(value: 'edit', child: Text('编辑')),
            const PopupMenuItem(value: 'refresh', child: Text('刷新')),
            const PopupMenuItem(value: 'readRecord', child: Text('阅读记录')),
            // 设置源变量（Task #63 冻结 / #64-65 实现，§5.11-3 已接通）/
            // 设置书籍变量（[Task #39 §5.11-4] 已接通变量对话框 + updateBook）
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
            const PopupMenuItem(value: 'top', child: Text('置顶')),
            // 允许更新（书源存在；勾选态尾部 ✓）
            if (hasSource)
              checkedItem('canUpdate', '允许更新', book?.canUpdate ?? true),
            // [UI-fix v2.0.3] 删除提醒接通本地持久化（对齐原版
            // LocalConfig.deleteBookAlert；勾选态尾部 ✓）
            checkedItem('deleteAlert', '删除提醒', _deleteBookAlert),
            const PopupMenuItem(
                value: 'clearCache', child: Text('清理缓存')),
            // ── 分隔线后：本端独有项（双基准 + 红线：功能不删除）──
            PopupMenuItem<String>(
              value: 'menuDivider',
              enabled: false,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Divider(height: 1, thickness: 1, color: cs.outlineVariant),
              ),
            ),
            if (source?.customButton == true)
              const PopupMenuItem(value: 'customBtn', child: Text('自定义')),
            if (isLocal)
              const PopupMenuItem(value: 'upload', child: Text('上传至远程')),
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
            // [B1 形态对齐]「分组」由操作宫格收纳进 ⋮ 菜单（复用 _showChangeGroup）
            const PopupMenuItem(value: 'group', child: Text('设置分组')),
            // 拆分长章节（仅本地 txt；勾选态尾部 ✓；
            // isLocalTxt 已隐含 book != null，Dart 3 提升生效）
            if (isLocalTxt)
              checkedItem(
                  'splitLongChapter',
                  '拆分长章节',
                  book.readConfig?.splitLongChapter ?? true),
            const PopupMenuItem(
                value: 'cacheDownloads', child: Text('缓存下载队列')),
            const PopupMenuItem(value: 'log', child: Text('日志')),
          ];
        },
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    // 对标原版 activity_book_info.xml：封面背景 + 渐变遮罩 + 折叠 TitleBar
    // [UI_SYNC_REFACTOR B4] 封面取色换肤：ColorScheme 400ms 渐变
    //（对齐参考仓 rememberBookInfoColorTheme tween(400, FastOutSlowIn)；
    // bookInfoFollowCoverColor 开关关闭或未取到 seed 时保持原配色）
    final baseTheme = Theme.of(context);
    final seed = _coverSeed;
    final followCover =
        uiSettingsListenable.value.bookInfoFollowCoverColor;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: followCover && seed != null ? 1 : 0),
      duration: const Duration(milliseconds: 400),
      curve: Curves.fastOutSlowIn,
      builder: (context, t, child) {
        var scheme = baseTheme.colorScheme;
        if (seed != null && t > 0) {
          final target = ColorScheme.fromSeed(
            seedColor: seed,
            brightness: baseTheme.colorScheme.brightness,
          );
          scheme = ColorScheme.lerp(scheme, target, t);
        }
        return Theme(
          data: baseTheme.copyWith(colorScheme: scheme),
          child: child!,
        );
      },
      child: Scaffold(
        // [UI_SYNC_REFACTOR B4] appBar → 折叠 SliverAppBar（入 body 首位
        // sliver，collapsedFraction 驱动透明→surfaceContainer 插值）
        floatingActionButton: _pageLoading || _loadedBook == null
            ? null
            : _buildReadFab(),
        // [PARITY C1 D3] FAB 定位对齐参考 08 量化：右下角（slot 默认边距
        // 16dp ≈ 参考右 18dp / 底 17dp，误差 <2dp 在容差内）
        floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
      body: _pageLoading
          // [LAYOUT_PLAN P4] 首屏 Skeleton 接线：详情骨架替代整页 LoadingIndicator
          // （shimmer 1200ms 已在 skeleton.dart 实现）
          ? ListView.builder(
              padding: const EdgeInsets.all(16),
              itemCount: 4,
              itemBuilder: (_, _) => const ListSkeletonItem(),
            )
          : _loadError != null && _loadedBook == null
              ? ErrorView(
                  message: _loadError!,
                  onRetry: _reload,
                )
              : _loadedBook == null
                  ? const ErrorView(message: '书籍不存在')
                  : _buildPage(context, _loadedBook!, _chapters),
        // [B1 形态对齐 | full-stack-engineer + UI] 底部固定双按钮栏已移除：
        // 阅读入口改右下浮动胶囊（floatingActionButton 在位），
        // 加书架/移出书架入口保留在四宫格第一格，功能不丢失
        ),
      );
  }
}
