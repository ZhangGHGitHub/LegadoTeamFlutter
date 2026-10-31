import 'dart:async';
import 'dart:convert';
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;

import '../../models/models.dart';
import '../../providers/providers.dart' show bookApiProvider;
import '../../providers/reader/reader_notifier.dart';
import '../../providers/reader/reader_top_bar_actions_notifier.dart';
import '../../providers/theme/theme_notifier.dart';
import '../../providers/ui_settings/ui_settings_notifier.dart';
import '../../routes.dart';
import '../../screens/reader_config_panel.dart';
import '../../services/system_brightness.dart';
import '../../utils/txt_toc_rule.dart' show isLocalTxtBook;
import 'change_chapter_source_sheet.dart';
import 'change_source_flow.dart';
import 'reader_charset_dialog.dart';
import 'reader_download_dialog.dart';
import 'reader_toc_rule_dialog.dart';
import 'reader_top_bar_actions.dart';

/// [UI_SYNC_REFACTOR S2-1] 阅读菜单单块底部面板（对齐参考 ReadBookMenuBar）
///
/// 结构：屏幕顶栏（返回/书名/换源/刷新正文/下载（离线缓存）/更多溢出 +
/// 章节信息块与中部快捷钮）→ 底部 Surface（进度滑条行 + 单行五键行动作行）。
/// [PARITY A5] 键集收敛对齐参考版默认键集：动作行 = 全文搜索/自动翻页/
/// 目录/朗读/设置（参考 ReadButtonConfigDelegate.kt:197-203
/// DEFAULT_ENABLED_BUTTON_IDS = search/auto_page/catalog/read_aloud/setting，
/// 显示顺序 ReadBookContract.kt:404+ ReadBookButtonIds；无第二页、无字号/
/// 亮度键；参考 showBrightnessView 默认 "0" 亮度隐藏，字号/亮度保留在读内
/// 入口 ReaderSettingsSheet / ReaderConfigPanel）。
/// 常挂载+双向动画（visible 驱动）。
class ReaderMenuPanel extends ConsumerStatefulWidget {
  final bool visible;
  final VoidCallback onBack;
  final VoidCallback onAddBookmark;
  final VoidCallback onOpenCatalog;
  final VoidCallback onOpenSettings;
  final VoidCallback onOpenAdvancedConfig;
  final VoidCallback onOpenContentSearch;
  final VoidCallback onReadAloud;
  final VoidCallback onToggleAutoPage;
  final VoidCallback onOpenReplaceRules;

  /// 亮度条模式三档（'0'=不显示 / '1'=横条 / '2'=竖条，对齐参考版
  /// PreferKey.readBrightnessMode；[批1b-1] 取代旧布尔 showBrightnessView）
  final String brightnessMode;

  /// 竖条位置（'0'=左侧 / '1'=右侧，对齐参考版
  /// PreferKey.readBrightnessControlPosition，仅模式='2' 生效）
  final String brightnessVwPos;
  final String progressBehavior;
  final ValueChanged<int>? onSeekPage;
  final bool styleFollowPage;

  const ReaderMenuPanel({
    super.key,
    required this.visible,
    required this.onBack,
    required this.onAddBookmark,
    required this.onOpenCatalog,
    required this.onOpenSettings,
    required this.onOpenAdvancedConfig,
    required this.onOpenContentSearch,
    required this.onReadAloud,
    required this.onToggleAutoPage,
    required this.onOpenReplaceRules,
    this.brightnessMode = '0',
    this.brightnessVwPos = '1',
    this.progressBehavior = 'chapter',
    this.onSeekPage,
    this.styleFollowPage = false,
  });

  @override
  ConsumerState<ReaderMenuPanel> createState() => _ReaderMenuPanelState();
}

class _ReaderMenuPanelState extends ConsumerState<ReaderMenuPanel>
    with SingleTickerProviderStateMixin {
  // 进出场：进 220（fadeIn180 内含）/ 出 180（对齐参考 0.88 缩放族）
  late final AnimationController _menuController = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
    reverseDuration: const Duration(milliseconds: 180),
    value: widget.visible ? 1 : 0,
  );

  @override
  void didUpdateWidget(covariant ReaderMenuPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.visible != widget.visible) {
      widget.visible ? _menuController.forward() : _menuController.reverse();
    }
  }

  @override
  void dispose() {
    _menuController.dispose();
    super.dispose();
  }

  /// [批31] 切换「目录显示反转」并持久化到 `Book.readConfig.reverseTocDisplay`
  ///
  /// 对齐原版 `TocViewModel.reverseToc`：仅改展示序（数据/章节索引不变），
  /// 目录页读取同一 Book 对象即按「先数据反转、再显示反转」组合渲染。
  ///
  /// [批32] 改走单键写 `updateReadConfigField`：`updateBook` 是整书快照写，
  /// Dart `ReadConfig` 未建模的键（`useGlobalAudioSkip`/`tocExpanded`/
  /// `manualReplaceRuleIds` 等）会在往返中被清空；单键写只合并该键。
  Future<void> _toggleReverseTocDisplay(Book book) async {
    final cfg = book.readConfig ?? const ReadConfig();
    final next = !cfg.reverseTocDisplay;
    try {
      await ref
          .read(bookApiProvider)
          .updateReadConfigField(
            book.bookUrl,
            'reverseTocDisplay',
            jsonEncode(next),
          );
      if (!mounted) return;
      final updated = book.copyWith(
        readConfig: cfg.copyWith(reverseTocDisplay: next),
      );
      ref.read(readerNotifierProvider.notifier).updateCurrentBook(updated);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('设置保存失败: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(readerNotifierProvider);
    final notifier = ref.read(readerNotifierProvider.notifier);
    final book = state.currentBook;
    final chapter =
        (state.chapters.isNotEmpty &&
            state.currentChapterIndex < state.chapters.length)
        ? state.chapters[state.currentChapterIndex]
        : null;
    final cs = Theme.of(context).colorScheme;
    final followColor = widget.styleFollowPage ? state.backgroundColor : null;
    final foreground = widget.styleFollowPage ? state.textColor : null;
    final adv = ref.watch(readerAdvConfigProvider);
    final autoPageActive = adv?.autoPageTurn ?? false;
    var barColor = followColor ?? cs.surface;
    // [UI_SYNC_REFACTOR S2-2] 表面 Haze 档（实色等效）：enableBlur 时
    // 半透明底（α 85/255，参考 readMenuBlurAlpha 默认）+ BackdropFilter(24)
    final ui = uiSettingsListenable.value;
    final useSurfaceBlur = ui.enableBlur && followColor == null;
    if (useSurfaceBlur) {
      barColor = barColor.withValues(alpha: 85 / 255);
    }

    return Positioned.fill(
      child: AnimatedBuilder(
        animation: _menuController,
        builder: (context, child) {
          final v = _menuController.value;
          if (v == 0) return const SizedBox.shrink();
          final fade = Tween<double>(begin: 0, end: 1).animate(
            CurvedAnimation(
              parent: _menuController,
              curve: const Interval(0, 0.82, curve: Curves.easeOut),
            ),
          );
          return IgnorePointer(
            ignoring: !widget.visible,
            child: FadeTransition(opacity: fade, child: child!),
          );
        },
        child: Stack(
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // [UI_SYNC_REFACTOR S6 修 | 2026-09-08] 顶栏置屏幕顶部（用户
                // 反馈①：此前误置于底部面板首行；对齐原版布局——← 居左，
                // 换源/刷新/缓存/更多 居右）— Qoder
                _buildTopBar(context, barColor, book, chapter, notifier),
                const Spacer(),
                useSurfaceBlur
                    ? ClipRRect(
                        borderRadius: const BorderRadius.vertical(
                          top: Radius.circular(32),
                        ),
                        child: BackdropFilter(
                          filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
                          child: _panelSurface(
                            context,
                            barColor,
                            foreground,
                            book,
                            chapter,
                            notifier,
                            state,
                            autoPageActive,
                          ),
                        ),
                      )
                    : _panelSurface(
                        context,
                        barColor,
                        foreground,
                        book,
                        chapter,
                        notifier,
                        state,
                        autoPageActive,
                      ),
              ],
            ),
            // [批1b-1] 亮度竖条（模式='2'）：贴左/右缘居中（对齐参考版
            // ReadBookMenuBar.kt:189-274 CenterStart/CenterEnd + 圆角 40
            // 胶囊形态）；与底部面板/顶部栏不重叠，滑动手势区域独立，
            // 不遮挡翻页点击区（菜单展开时翻页手势本已停用）— 全栈工程师
            if (widget.brightnessMode == '2')
              _buildVerticalBrightnessBar(context, foreground),
          ],
        ),
      ),
    );
  }

  Widget _panelSurface(
    BuildContext context,
    Color barColor,
    Color? foreground,
    Book? book,
    BookChapter? chapter,
    ReaderNotifier notifier,
    ReaderState state,
    bool autoPageActive,
  ) {
    // [PARITY A5] 面板键集对齐参考版：进度行 + 单行五键行动作行
    //（参考版菜单无亮度/字号键与亮度竖条；亮度/字号保留在读内入口
    // ReaderSettingsSheet / ReaderConfigPanel）。
    return Material(
      color: barColor,
      borderRadius: const BorderRadius.vertical(top: Radius.circular(32)),
      child: SafeArea(
        top: false,
        child: IconTheme(
          data: IconThemeData(color: foreground),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _buildProgressRow(context, notifier, state, foreground),
              _buildActionRow(context, foreground, autoPageActive),
            ],
          ),
        ),
      ),
    );
  }

  // [P2-9 | 2026-09-24] 换源流程（Fix B）：await 导航 → 路由以新 bookUrl
  // pop（发生了切换）时重载书/目录/强制刷新正文（见
  // ReaderNotifier.reloadAfterSourceChange）；用户取消（pop null）
  // 不做任何事（不重载、不提示）。
  // [SB-HUNT | 2026-09-25] 统一至 runChangeSourceFlow（与顶栏换源入口
  // 共用）：notifier 级共享重入锁（在途第二触发静默忽略）+ 必收清理
  // （clearSnackBars，离场/异常也不留残留）+ 结果去重（成功反馈只保留
  // 换源页「已切换到」，阅读器侧只弹失败条）。原 [P2-9 fix/fix2] 的
  // 无类型 pushNamed 与 10min 进行中条语义见 change_source_flow.dart。
  Future<void> _changeSourceFlow(BuildContext context, Book book) =>
      runChangeSourceFlow(ref, context, book);

  // [P2-9 | 2026-09-24] 刷新正文流程（Fix A）：强制联网抓取（绕过缓存，
  // 见 ReaderNotifier.refreshChapterContent）→ 显式成功反馈 / 失败反馈
  // 含原因（失败保留旧正文，不清空）。
  Future<void> _refreshContentFlow(BuildContext context) async {
    // [P2-9 fix2 | 2026-09-24] 与 _changeSourceFlow 同一慢路径竞态：强制
    // 抓取 > 4s（SnackBar 默认自动消失时长）时，旧写法 controller.close()
    // 踩 scaffold.dart:341 `_snackBars.first == controller` 断言 / 空队
    // 列 StateError，结果条永不出现。修法：进行中条显式 10min duration +
    // 结果就绪收起（[SB-HUNT | 2026-09-25] 改 clearSnackBars 必收，见下）
    final messenger = ScaffoldMessenger.of(context);
    final notifier = ref.read(readerNotifierProvider.notifier);
    // [C5-hunt | 2026-09-24] 重入守卫：已有刷新在途时进行中 SnackBar 已
    // 在展示，静默返回（避免 N 次点击堆叠 N 个 SnackBar / N 次强制抓取，
    // 与换源流程 _applying 防重入同形态；notifier 侧 _refreshing 兜底）
    if (notifier.isRefreshing) return;
    messenger.showSnackBar(
      const SnackBar(content: Text('正在刷新正文…'), duration: Duration(minutes: 10)),
    );
    final err = await notifier.refreshChapterContent();
    // [SB-HUNT | 2026-09-25] 必收清理（与换源流程统一）：先 clearSnackBars
    // （root 队列、空队列安全、不踩 scaffold.dart:341 断言）——抓取期间
    // 用户离场（context 已卸载）也不留进行中条；结果条仅在仍在阅读场展示
    messenger.clearSnackBars();
    if (!context.mounted) return;
    messenger.showSnackBar(
      SnackBar(content: Text(err == null ? '正文已刷新' : '刷新正文失败：$err')),
    );
  }

  // ── 顶栏动作池（批37）──────────────────────────────────────────

  /// 「更多」菜单里动作项的值前缀（`action:<id>`），与既有固定项区分
  static const String _moreActionValuePrefix = 'action:';

  /// 「更多」菜单里已有同义入口的动作 id（目录/界面设置/添加书签/替换规则
  /// + 底部常驻动作行的全文搜索/自动翻页/朗读）
  ///
  /// 兜底列表跳过这些项，避免同一菜单出现两个同义入口；这些动作本身
  /// 已在固定位置（「更多」菜单项或底部五键行动作行），不会丢失。
  static const Set<String> _moreMenuOwnActionIds = {
    'catalog',
    'setting',
    'addBookmark',
    'replace',
    // [批37b P2-1] 底部动作行常驻的三项：顶栏未显示时不再在「更多」重复
    'search',
    'auto_page',
    'read_aloud',
  };

  /// 本地书判定（批37b P2-3）
  ///
  /// origin 为空视为本地（存量/未落库书没有书源可换源/刷新），其余复用
  /// 类型感知的 [BookType.isLocalBook]（对齐参考版 `Book.isLocal`）——
  /// 仅看 origin 会漏掉 type 位标记的本地书。
  static bool _isLocalBook(Book book) =>
      book.origin.trim().isEmpty || BookType.isLocalBook(book);

  /// 本地 TXT 判定（[批43b P3-4] 统一走 `utils/txt_toc_rule.dart::isLocalTxtBook`）
  ///
  /// 与 Rust `is_local_txt_book`（本地存储 + `bookUrl` 扩展名 `.txt/.text`）
  /// 同构；此前本处只认 `originName.endsWith('.txt')`，会漏 `.text` 且与
  /// Rust 准入不一致（UI 可见但设置失败）。
  static bool _isLocalTxtBook(Book book) => isLocalTxtBook(book);

  /// 顶栏动作按钮（40dp 紧凑热区，支持长按二级动作）
  ///
  /// 参考版 TopBarActionButton 用 combinedClickable 同时支持点击/长按。
  /// IconButton 自带 tooltip 在移动端默认「长按显示」，会与二级菜单抢手势，
  /// 故改用外层手动触发 Tooltip（find.byTooltip/无障碍语义仍可用），长按
  /// 交给 GestureDetector。
  Widget _buildTopBarActionButton(
    BuildContext context,
    Book? book,
    ReaderTopBarActionDef def,
  ) {
    return Tooltip(
      message: def.label,
      triggerMode: TooltipTriggerMode.manual,
      child: GestureDetector(
        key: ValueKey('reader-topbar-action-${def.id}'),
        onLongPress: def.longPress == null
            ? null
            : () => _performTopBarLongPress(context, book, def.longPress!),
        child: IconButton(
          icon: Icon(def.icon, size: 22, semanticLabel: def.label),
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints.tightFor(width: 40, height: 40),
          visualDensity: VisualDensity.compact,
          onPressed: () =>
              unawaited(_performTopBarAction(context, book, def.id)),
        ),
      ),
    );
  }

  /// 执行一个顶栏动作（顶栏按钮与「更多」兜底项共用同一实现）
  Future<void> _performTopBarAction(
    BuildContext context,
    Book? book,
    String id,
  ) async {
    final notifier = ref.read(readerNotifierProvider.notifier);
    switch (id) {
      case 'download':
        // 对齐原版 menu_download → 离线缓存范围对话框（默认起始 = 当前章）
        showReaderOfflineCacheDialog(context, ref);
      case 'refresh':
        await _refreshContentFlow(context);
      case 'change_source':
        if (book != null) await _changeSourceFlow(context, book);
      case 'toc_rule':
        // 批43：对齐原版 menu_toc_regex → TxtTocRuleDialog：选择规则弹层，
        // 选中后单列写 books.tocUrl + 清本地章节缓存 + 重载目录/正文；
        // 「管理规则」入口在弹层内（不再直接跳规则库管理页）。
        if (book != null) {
          await showReaderTocRuleDialog(
            context,
            ref,
            book: book,
            onApplied: (updated) => notifier.reloadAfterTocRuleChange(updated),
          );
        }
      case 'charset':
        showReaderCharsetDialog(context, ref);
      case 'catalog':
        widget.onOpenCatalog();
      case 'search':
        widget.onOpenContentSearch();
      case 'auto_page':
        widget.onToggleAutoPage();
      case 'read_aloud':
        widget.onReadAloud();
      case 'setting':
        widget.onOpenSettings();
      case 'addBookmark':
        widget.onAddBookmark();
      case 'replace':
        widget.onOpenReplaceRules();
      case 'theme':
        // 对齐原版 fabNightTheme：显式写日/夜，外层书架同步联动
        await ref
            .read(themeNotifierProvider.notifier)
            .toggleDayNight(
              isNight: Theme.of(context).brightness == Brightness.dark,
            );
      case 'prev_chapter':
        await notifier.prevChapter();
        notifier.hideControls();
      case 'next_chapter':
        await notifier.nextChapter();
        notifier.hideControls();
    }
  }

  /// 执行长按二级动作
  void _performTopBarLongPress(
    BuildContext context,
    Book? book,
    ReaderTopBarLongPress longPress,
  ) {
    switch (longPress) {
      case ReaderTopBarLongPress.changeSource:
        if (book != null) _showChangeSourceLongPress(context, book);
      case ReaderTopBarLongPress.cacheManage:
        // 长按缓存 = 进入缓存管理页（短按仍是离线缓存范围对话框）
        Navigator.pushNamed(context, AppRoutes.offlineCache);
    }
  }

  /// 换源长按菜单（对齐参考版 ChangeSourceMenuItems：换书源 / 单章换源）
  void _showChangeSourceLongPress(BuildContext context, Book book) {
    final state = ref.read(readerNotifierProvider);
    final chapter = state.currentChapter;
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetCtx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Symbols.article_rounded),
              title: const Text('单章换源'),
              subtitle: Text(
                chapter?.title.isNotEmpty == true ? chapter!.title : '仅替换当前章正文',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              onTap: () {
                Navigator.pop(sheetCtx);
                showChangeChapterSourceSheet(
                  context,
                  bookUrl: book.bookUrl,
                  bookName: book.name,
                  author: book.author,
                  chapterIndex: state.currentChapterIndex,
                  chapterTitle: chapter?.title ?? '',
                );
              },
            ),
            ListTile(
              leading: const Icon(Symbols.swap_horiz_rounded),
              title: const Text('换书源'),
              subtitle: const Text('切换整本书的书源'),
              onTap: () {
                Navigator.pop(sheetCtx);
                unawaited(_changeSourceFlow(context, book));
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  // ── 分区 1：屏幕顶部工具栏（对齐原版：← 居左；⇄ ↻ ⬇ ⋮ 居右）──
  //
  // [UI_SYNC_REFACTOR S6 修 | 2026-09-08] 用户反馈②：顶栏按参考版改造——
  // 移除书名/章名胶囊（章名在正文区与页脚已有呈现），改为参考版五钮
  //（返回/换源/刷新正文/下载当前章/更多溢出）— Qoder
  // [批37] 右侧动作改为动作池按配置渲染（默认投影 = 换源/刷新/缓存/更多）。
  Widget _buildTopBar(
    BuildContext context,
    Color barColor,
    Book? book,
    BookChapter? chapter,
    ReaderNotifier notifier,
  ) {
    // [UI_SYNC_REFACTOR S6 修 | 2026-09-08] 用户反馈②：头部信息（章节名/
    // 章节链接/书源名）应在顶栏菜单中而非正文——工具行下方补信息块
    //（章名+书源徽标 / 章节链接），对齐参考版顶栏布局 — Qoder
    // [PARITY C2 M2] 移除来源 URL 全文行：参考版顶栏信息块只保留
    // 章节名 + 书源小字徽标，不再渲染章节链接全文（来源名并入小字行）。
    final sourceName = book?.originName ?? '';
    // [批1a | 2026-10-31] showReadTitleAddition 接线（对标原版
    // showReadTitleAddition / 参考版 ReadConfigScreen #42）：关闭后
    // 顶栏信息块（章节名 + 书源徽标）整体不渲染 — 全栈工程师
    final showTitleAddition =
        ref.watch(readerAdvConfigProvider.select((v) => v?.showReadTitleAddition ?? true));
    // [P2-9 | 2026-09-24] 在线书判定（对齐顶栏 isOnline 语义，WebDAV 视作
    // 本地）：本地书（loc_book/webDav::/存量 dav:）不显示换源/刷新正文（原版 ReadMenu
    // 对本地书隐藏这两项入口）；notifier 侧守卫兜底
    // （refreshChapterContent 对本地书返回原因、不触网）
    // [批37b P2-3] origin 为空同样按本地处理；其余走类型感知的
    // BookType.isLocalBook（仅 origin 判定会漏掉 type 位标记的本地书）
    final isOnline = book != null && !_isLocalBook(book);
    // [批37] 顶栏动作可配置（参考版 ReadMenuActionDefs.kt）：
    // 顺序/开关来自用户配置，按当前书型过滤，最多 6 个（含末尾固定的
    // 「更多」）。旧版写死的换源/刷新/缓存/更多正是默认配置在在线书上的
    // 投影（参考版 DEFAULT_TITLE_BAR_ACTION_IDS），默认行为不变。
    final actionConfig = ref.watch(readerTopBarActionsProvider);
    final traits = ReaderBookTraits(
      isLocal: book != null && !isOnline,
      isLocalTxt: book != null && _isLocalTxtBook(book),
    );
    final topBarActions = book == null
        ? <ReaderTopBarActionDef>[readerTopBarActionById[kReaderMoreActionsId]!]
        : buildReaderTopBarActions(actionConfig, traits: traits);
    final visibleActionIds = {for (final def in topBarActions) def.id};
    // 「更多」菜单兜底：被移出顶栏（或本就不在顶栏）的动作仍从这里可达，
    // 确保换源/刷新/缓存/编码等入口不会因配置丢失。菜单里已有同义项
    // （目录/界面设置/添加书签/替换规则）不重复列出。
    final hiddenActions = book == null
        ? const <ReaderTopBarActionDef>[]
        : hiddenReaderTopBarActions(
            actionConfig,
            traits: traits,
            visibleIds: visibleActionIds,
            excludeIds: _moreMenuOwnActionIds,
          );
    return Material(
      color: barColor,
      child: SafeArea(
        bottom: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              height: 48,
              child: Row(
                children: [
                  IconButton(
                    icon: const Icon(
                      Symbols.arrow_back_rounded,
                      semanticLabel: '退出阅读',
                    ),
                    tooltip: '退出阅读',
                    onPressed: widget.onBack,
                  ),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: Text(
                        book?.name ?? '',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ),
                  ),
                  // [批37] 顶栏动作按配置渲染：旧版写死的换源/刷新/缓存
                  // 改为动作池投影（默认配置 = 参考版默认项），新增的
                  // 目录/设置等动作也由用户配置决定；「更多」固定末尾。
                  for (final def in topBarActions)
                    if (def.id == kReaderMoreActionsId)
                      PopupMenuButton<String>(
                        tooltip: '更多',
                        position: PopupMenuPosition.under,
                        onSelected: (value) {
                          if (value.startsWith(_moreActionValuePrefix)) {
                            unawaited(
                              _performTopBarAction(
                                context,
                                book,
                                value.substring(_moreActionValuePrefix.length),
                              ),
                            );
                            return;
                          }
                          switch (value) {
                            case 'addBookmark':
                              widget.onAddBookmark();
                            case 'highlightRule':
                              Navigator.pushNamed(
                                context,
                                AppRoutes.highlightRules,
                              );
                            case 'replace':
                              widget.onOpenReplaceRules();
                            case 'settings':
                              widget.onOpenSettings();
                            case 'toc':
                              widget.onOpenCatalog();
                            case 'reverseTocDisplay':
                              // [批31] 目录显示反转（对齐原版
                              // ReadConfig.reverseTocDisplay）：仅展示层反序，
                              // 数据顺序/章节身份不变，无需重载正文
                              if (book != null) {
                                unawaited(_toggleReverseTocDisplay(book));
                              }
                          }
                        },
                        itemBuilder: (_) => [
                          const PopupMenuItem(
                            value: 'addBookmark',
                            child: Text('添加书签'),
                          ),
                          const PopupMenuItem(
                            value: 'highlightRule',
                            child: Text('高亮规则'),
                          ),
                          const PopupMenuItem(
                            value: 'replace',
                            child: Text('替换规则'),
                          ),
                          const PopupMenuItem(
                            value: 'toc',
                            child: Text('查看目录'),
                          ),
                          CheckedPopupMenuItem(
                            value: 'reverseTocDisplay',
                            checked:
                                book?.readConfig?.reverseTocDisplay ?? false,
                            child: const Text('目录显示反转'),
                          ),
                          const PopupMenuItem(
                            value: 'settings',
                            child: Text('界面设置'),
                          ),
                          // [批37] 顶栏未显示的动作兜底（换源/刷新/缓存/
                          // 编码等），保证配置后功能入口不丢失。
                          if (hiddenActions.isNotEmpty) ...[
                            const PopupMenuDivider(),
                            for (final def in hiddenActions)
                              PopupMenuItem(
                                value: '$_moreActionValuePrefix${def.id}',
                                child: Text(def.label),
                              ),
                          ],
                        ],
                      )
                    else
                      _buildTopBarActionButton(context, book, def),
                ],
              ),
            ),
            // [批1a] showReadTitleAddition：关闭时顶栏信息块不渲染
            if (showTitleAddition &&
                (chapter != null || sourceName.isNotEmpty))
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            chapter?.title ?? '',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.titleSmall,
                          ),
                        ),
                        if (sourceName.isNotEmpty)
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 3,
                            ),
                            decoration: BoxDecoration(
                              color: Theme.of(context).colorScheme.primary,
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Text(
                              sourceName,
                              style: TextStyle(
                                fontSize: 12,
                                color: Theme.of(context).colorScheme.onPrimary,
                              ),
                            ),
                          ),
                      ],
                    ),
                    // [PARITY C2 M3] 中部快捷钮去圆底：参考版中部为小图标形态
                    //（无圆形底衬），对齐后保留全部五项功能入口。
                    const SizedBox(height: 10),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        _shortcutButton(
                          context,
                          Symbols.search_rounded,
                          '搜索',
                          widget.onOpenContentSearch,
                        ),
                        _shortcutButton(
                          context,
                          Symbols.format_list_bulleted_rounded,
                          '目录',
                          widget.onOpenCatalog,
                        ),
                        _shortcutButton(
                          context,
                          Symbols.headphones_rounded,
                          '朗读',
                          widget.onReadAloud,
                        ),
                        _shortcutButton(
                          context,
                          Symbols.settings_rounded,
                          '设置',
                          widget.onOpenSettings,
                        ),
                        // [P2-9 fix | 2026-09-24] 本地书不渲染换源快捷钮
                        // （隐藏而非置灰，同顶栏行）；换源 = await 导航，
                        // 成功后重载，取消不做任何事
                        if (isOnline)
                          _shortcutButton(
                            context,
                            Symbols.swap_horiz_rounded,
                            '换源',
                            () => unawaited(_changeSourceFlow(context, book)),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// [PARITY C2 M3] 小图标快捷钮（搜索/目录/朗读/设置/换源五项保留）：
  /// 对齐参考版中部小图标形态——去除圆形底衬，仅保留小图标 + 圆形点击热区。
  Widget _shortcutButton(
    BuildContext context,
    IconData icon,
    String tip,
    VoidCallback? onTap,
  ) {
    final cs = Theme.of(context).colorScheme;
    return Tooltip(
      message: tip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(18),
        child: SizedBox(
          width: 34,
          height: 34,
          child: Icon(
            icon,
            size: 22,
            semanticLabel: tip,
            color: onTap == null
                ? cs.onSurface.withValues(alpha: 0.35)
                : cs.onSurface,
          ),
        ),
      ),
    );
  }

  // ── 分区：单行五键行动作行（[PARITY A5] 键集对齐参考版默认键集）──
  //
  // [PARITY A5 | 深色对齐裁决"以参考版为准"] 参考版阅读菜单默认五键：
  // 全文搜索/自动翻页/目录/朗读/设置。依据（参考源码 D:\tmp\md3_ref_legado）：
  // ① 默认开启键集 ReadButtonConfigDelegate.kt:197-203
  //   DEFAULT_ENABLED_BUTTON_IDS = {search, auto_page, catalog, read_aloud, setting}
  //   （loadButtonConfig :148-154：用户未配置时按 ReadBookButtonIds 显示序取此五键）；
  //   ② 键位定义 SystemMenuPage.kt:898-903：search→Icons.Search/search_content、
  //   auto_page→Icons.PlayArrow/auto_next_page、catalog→Icons.List/chapter_list、
  //   read_aloud→Icons.RecordVoiceOver/read_aloud、setting→Icons.Settings/setting；
  //   ③ 文案 values-zh-rCN/strings.xml：search_content=全文搜索(:1036)、
  //   auto_next_page=自动翻页(:465)、chapter_list=目录(:184)、
  //   read_aloud=朗读(:189)、setting=设置(:97)；
  //   ④ 布局 ReadBookContract.kt:359-360 readMenuIconItemsPerRow=5、
  //   readMenuIconRowCount=1（单行五键，无第二页、无字号/亮度键；亮度
  //   showBrightnessView 默认 "0" 隐藏，:390）。
  // 注：在途版曾按 MuMu 定制实例截图放 章节梗概/AI改写 占位键，但参考源码默认
  // 键集不含 ai_summary/ai_rewrite（ReadBookButtonIds 成员但默认 enabled=false，
  // ReadButtonConfigDelegate.kt:172-190 normalizeButtonConfig），故按源码移除；
  // 如需保留 AI 占位请主代理另立裁决。替换/更多入口保留于顶栏更多溢出菜单，
  // 亮度/字号保留在读内（ReaderSettingsSheet / ReaderConfigPanel）。
  Widget _buildActionRow(
    BuildContext context,
    Color? foreground,
    bool autoPageActive,
  ) {
    final cs = Theme.of(context).colorScheme;
    Widget item(
      IconData icon,
      String label,
      VoidCallback onTap, {
      bool active = false,
    }) {
      final color = active ? cs.primary : (foreground ?? cs.onSurfaceVariant);
      return Expanded(
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 24, color: color),
                const SizedBox(height: 6),
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(
                    context,
                  ).textTheme.labelMedium?.copyWith(color: color),
                ),
              ],
            ),
          ),
        ),
      );
    }

    // [PARITY A5] 键集/顺序/文案 = 参考默认五键（见本分区头部注释依据）：
    // search / auto_page / catalog / read_aloud / setting。
    // 图标随中部快捷钮既有 Symbols 形态；auto_page 运行中切 pause 图标 +
    // primary 色（参考 active 态以颜色标记）。
    final items = <Widget>[
      item(Symbols.search_rounded, '全文搜索', widget.onOpenContentSearch),
      item(
        autoPageActive ? Symbols.pause_rounded : Symbols.play_arrow_rounded,
        '自动翻页',
        widget.onToggleAutoPage,
        active: autoPageActive,
      ),
      item(Symbols.format_list_bulleted_rounded, '目录', widget.onOpenCatalog),
      item(Symbols.headphones_rounded, '朗读', widget.onReadAloud),
      item(Symbols.settings_rounded, '设置', widget.onOpenSettings),
    ];
    return SizedBox(height: 76, child: Row(children: items));
  }

  // ── 分区：进度滑条行（page=调章内页 / chapter=调章节）──
  Widget _buildProgressRow(
    BuildContext context,
    ReaderNotifier notifier,
    ReaderState state,
    Color? foreground,
  ) {
    final chapterPageCount = notifier.paginator.pageCountForChapter(
      state.currentChapterIndex,
    );
    final usePageSeek =
        widget.progressBehavior == 'page' &&
        chapterPageCount > 1 &&
        widget.onSeekPage != null;
    final currentPage = state.currentChapterPos.clamp(
      0,
      chapterPageCount > 0 ? chapterPageCount - 1 : 0,
    );
    // [PARITY C2 M4] 进度形态对齐参考底行「X/Y + 目录%」：
    // ①左显章节/页码位置（页内寻址时「页/章内页」，否则「章/总章」）；
    // ②右显目录百分比（readingProgress 0~1 → 整数 %）；
    // ③保留滑条寻址能力（原 S6 圆形箭头钮为旧解读，参考该态为文字+滑条，
    //   故移除圆形箭头钮；上/下章仍可经点按屏缘与目录进入）。
    final percent = (state.readingProgress * 100).round();
    final positionText = usePageSeek
        ? '${currentPage + 1}/$chapterPageCount'
        : '${state.currentChapterIndex + 1}/${state.chapters.length}';
    final cs = Theme.of(context).colorScheme;
    final progressColor = foreground ?? cs.onSurface;
    final sliderTheme = SliderTheme.of(context).copyWith(
      trackHeight: 8,
      year2023: false,
      thumbColor: foreground ?? cs.onSurface,
      activeTrackColor: (foreground ?? cs.onSurface).withValues(alpha: 0.25),
      inactiveTrackColor: (foreground ?? cs.onSurface).withValues(alpha: 0.12),
      disabledActiveTrackColor: (foreground ?? cs.onSurface).withValues(
        alpha: 0.15,
      ),
      disabledInactiveTrackColor: (foreground ?? cs.onSurface).withValues(
        alpha: 0.08,
      ),
      activeTickMarkColor: Colors.transparent,
      inactiveTickMarkColor: (foreground ?? cs.onSurface).withValues(
        alpha: 0.35,
      ),
      overlayShape: SliderComponentShape.noOverlay,
    );
    // [PARITY C2 M4] 参考底行形态：「X/Y + 目录%」文字行 + 全宽滑条。
    // 文字行左=位置、右=百分比；下方保留滑条寻址（章节/章内页两种语义）。
    final textStyle = Theme.of(
      context,
    ).textTheme.labelMedium?.copyWith(color: progressColor);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(positionText, style: textStyle),
              Text('$percent%', style: textStyle),
            ],
          ),
          const SizedBox(height: 2),
          SliderTheme(
            data: sliderTheme,
            child: usePageSeek
                ? Slider(
                    value: currentPage.toDouble(),
                    min: 0,
                    max: (chapterPageCount - 1).toDouble(),
                    divisions: chapterPageCount - 1,
                    label: positionText,
                    onChanged: (value) => widget.onSeekPage!(value.toInt()),
                  )
                : Slider(
                    value: state.chapters.isNotEmpty
                        ? state.currentChapterIndex.toDouble()
                        : 0,
                    min: 0,
                    max: state.chapters.length > 1
                        ? (state.chapters.length - 1).toDouble()
                        : 1,
                    divisions: state.chapters.length > 1
                        ? state.chapters.length - 1
                        : null,
                    label: positionText,
                    onChanged: (value) => notifier.goToChapter(value.toInt()),
                  ),
          ),
        ],
      ),
    );
  }

  // ===== [批1b-1] 亮度竖条（模式='2'，贴左/右缘） =====

  /// 亮度竖条：圆角 40 胶囊（对齐参考版 RoundedCornerShape(40.dp)）+
  /// 竖向亮度滑条 + 自动亮度切换钮；贴 [widget.brightnessVwPos] 指定侧
  /// 屏幕边缘垂直居中（左右 8dp 边距，对齐参考版 padding start/end 8dp）。
  ///
  /// 亮度值与底栏横条同源（SystemBrightness 系统亮度服务），旋转 -90°
  /// 承载竖向滑动（RotatedBox 不参与父级水平手势竞争，仅胶囊自身区域
  /// 接收拖动，不影响正文翻页手势——菜单展开时正文点击/滑动本已由
  /// 面板层截停）。
  Widget _buildVerticalBrightnessBar(BuildContext context, Color? foreground) {
    final cs = Theme.of(context).colorScheme;
    final isLeft = widget.brightnessVwPos == '0';
    return Positioned(
      top: 0,
      bottom: 0,
      left: isLeft ? 8 : null,
      right: isLeft ? null : 8,
      child: Center(
        child: _VerticalBrightnessBar(
          foreground: foreground,
          fallbackColor: cs.surface,
        ),
      ),
    );
  }
}

/// [批1b-1] 亮度竖条内容（ StatefulWidget 独立承载亮度异步加载与拖动值，
/// 避免污染面板整体 rebuild）
class _VerticalBrightnessBar extends StatefulWidget {
  final Color? foreground;
  final Color fallbackColor;

  const _VerticalBrightnessBar({
    required this.foreground,
    required this.fallbackColor,
  });

  @override
  State<_VerticalBrightnessBar> createState() => _VerticalBrightnessBarState();
}

class _VerticalBrightnessBarState extends State<_VerticalBrightnessBar> {
  bool _supported = false;
  bool _auto = false;
  double _value = 0.5;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final supported = await SystemBrightness.isSupported();
      if (!supported) return;
      final auto = await SystemBrightness.isAutoBrightness();
      final value = await SystemBrightness.getBrightness();
      if (!mounted) return;
      setState(() {
        _supported = true;
        _auto = auto;
        _value = value;
      });
    } catch (e) {
      debugPrint('亮度通道不可用，隐藏亮度竖条: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_supported) return const SizedBox.shrink();
    final fg = widget.foreground ??
        Theme.of(context).colorScheme.onSurfaceVariant;
    return Material(
      color: widget.fallbackColor.withValues(alpha: 0.9),
      borderRadius: BorderRadius.circular(40),
      child: InkWell(
        borderRadius: BorderRadius.circular(40),
        onTap: () {}, // 胶囊自身消费点击，避免透传翻页手势
        child: Padding(
          // 竖条内边距：贴合参考版 BrightnessBar 纵向形态（上下留滑动余量）
          padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 4),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                visualDensity: VisualDensity.compact,
                icon: Icon(
                  _auto ? Icons.brightness_auto : Icons.brightness_auto_outlined,
                  color: fg,
                ),
                tooltip: _auto ? '关闭自动亮度' : '自动亮度',
                onPressed: _auto
                    ? null
                    : () async {
                        await SystemBrightness.setAutoBrightness(true);
                        await _load();
                      },
              ),
              // 旋转 90° 承载竖向滑条（底部=暗、顶部=亮，拖动方向自下而上）
              RotatedBox(
                quarterTurns: -1,
                child: SizedBox(
                  width: 180,
                  child: Slider(
                    value: _value.clamp(0.0, 1.0),
                    onChanged: _auto
                        ? null
                        : (v) {
                            setState(() => _value = v);
                            unawaited(SystemBrightness.setBrightness(v));
                          },
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
