import 'dart:async';
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;

import '../../models/models.dart';
import '../../providers/providers.dart';
import '../../providers/reader/reader_notifier.dart';
import '../../providers/ui_settings/ui_settings_notifier.dart';
import '../../routes.dart';
import '../../screens/reader_config_panel.dart';

/// [UI_SYNC_REFACTOR S2-1] 阅读菜单单块底部面板（对齐参考 ReadBookMenuBar）
///
/// 结构：屏幕顶栏（返回/书名/换源/刷新正文/缓存当前章/更多溢出 + 章节信息块
/// 与中部快捷钮）→ 底部 Surface（进度滑条行 + 单行五键行动作行）。
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
  final bool showBrightnessView;
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
    this.showBrightnessView = true,
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
        child: Column(
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
  // 反馈：进行中 SnackBar → 成功「已更换书源：<源名>」（源名取换源后
  // 记录的 originName）/ 失败含原因。
  Future<void> _changeSourceFlow(BuildContext context, Book book) async {
    // [P2-9 fix | 2026-09-24] 生产 /change_source 路由是
    // _ChangeSourceSheetRoute（PageRouteBuilder<dynamic>，见
    // AppRoutes.generateRoute）：类型化 pushNamed<String> 会在运行期把
    // 生成的路由强转 Route<String?> 抛 TypeError（真机崩溃）。对齐
    // 详情页 Task#24 既有修法（book_info_screen_builders
    // ._showChangeSourceDialog）：无类型 pushNamed + result is String 判定
    // [P2-9 fix2 | 2026-09-24] 慢路径 SnackBar 竞态：旧写法
    // 「controller.close() 收起进行中条」在重载 > 4s（SnackBar 默认自动
    // 消失时长）时，进行中条已离开 Scaffold 队列，close() 踩
    // scaffold.dart:341 `_snackBars.first == controller` 断言 / 空队列
    // StateError，恰在「收起进行中条」一步崩溃、结果条永不出现（真机 8
    // 次换源全如此，证据
    // docs/parity_shots/verify_ui_20260922/p29b_b1_crash_dialog.png）。
    // 修法：第一个 await 前取好对象；进行中条显式 10min duration（慢重载
    // 期间不自动消失）；结果就绪用 removeCurrentSnackBar() 收起（本 SDK
    // 队列为空时早退、无断言）再显结果条
    final messenger = ScaffoldMessenger.of(context);
    final notifier = ref.read(readerNotifierProvider.notifier);
    final result = await Navigator.pushNamed(
      context,
      AppRoutes.changeSource,
      arguments: book,
    );
    if (result is! String) return; // 取消 / 关闭 pop null → 不做任何事
    if (!context.mounted) return;
    messenger.showSnackBar(
      const SnackBar(
        content: Text('正在更换书源…'),
        duration: Duration(minutes: 10),
      ),
    );
    final err = await notifier.reloadAfterSourceChange(result);
    if (!context.mounted) return;
    messenger.removeCurrentSnackBar(); // 收起进行中条（已消失则无操作，不踩断言）
    final sourceName = ref.read(readerNotifierProvider).currentBook?.originName;
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          err == null
              ? (sourceName != null && sourceName.isNotEmpty
                  ? '已更换书源：$sourceName'
                  : '已更换书源')
              : '更换书源后重载失败：$err',
        ),
      ),
    );
  }

  // [P2-9 | 2026-09-24] 刷新正文流程（Fix A）：强制联网抓取（绕过缓存，
  // 见 ReaderNotifier.refreshChapterContent）→ 显式成功反馈 / 失败反馈
  // 含原因（失败保留旧正文，不清空）。
  Future<void> _refreshContentFlow(BuildContext context) async {
    // [P2-9 fix2 | 2026-09-24] 与 _changeSourceFlow 同一慢路径竞态：强制
    // 抓取 > 4s（SnackBar 默认自动消失时长）时，旧写法 controller.close()
    // 踩 scaffold.dart:341 `_snackBars.first == controller` 断言 / 空队
    // 列 StateError，结果条永不出现。修法：进行中条显式 10min duration +
    // removeCurrentSnackBar() 收起（已自动消失则无操作、不踩断言）
    final messenger = ScaffoldMessenger.of(context);
    final notifier = ref.read(readerNotifierProvider.notifier);
    messenger.showSnackBar(
      const SnackBar(
        content: Text('正在刷新正文…'),
        duration: Duration(minutes: 10),
      ),
    );
    final err = await notifier.refreshChapterContent();
    if (!context.mounted) return;
    messenger.removeCurrentSnackBar(); // 收起进行中条（已消失则无操作，不踩断言）
    messenger.showSnackBar(
      SnackBar(content: Text(err == null ? '正文已刷新' : '刷新正文失败：$err')),
    );
  }

  // ── 分区 1：屏幕顶部工具栏（对齐原版：← 居左；⇄ ↻ ⬇ ⋮ 居右）──
  //
  // [UI_SYNC_REFACTOR S6 修 | 2026-09-08] 用户反馈②：顶栏按参考版改造——
  // 移除书名/章名胶囊（章名在正文区与页脚已有呈现），改为参考版五钮
  //（返回/换源/刷新正文/下载当前章/更多溢出）— Qoder
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
    // [P2-9 | 2026-09-24] 在线书判定（对齐顶栏 isOnline 语义，WebDAV 视作
    // 本地）：本地书（loc_book/dav:）不显示换源/刷新正文（原版 ReadMenu
    // 对本地书隐藏这两项入口）；notifier 侧守卫兜底
    // （refreshChapterContent 对本地书返回原因、不触网）
    final isOnline = book != null &&
        book.origin != BookType.localTag &&
        !book.origin.startsWith(BookType.webDavTag);
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
                    icon: const Icon(Symbols.arrow_back_rounded),
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
                  // [P2-9 fix | 2026-09-24] 本地书不渲染换源/刷新正文/缓存
                  // 当前章（对齐原版 ReadMenu 本地书菜单构成：三项仅在线书
                  // 可见，与顶栏 isOnline 分支一致）。首版「isOnline ? 可点
                  // : null」的置灰形态被实机观测为「显示且点击无反应」
                  // （35% alpha no-op），现改为不渲染。
                  // 换源 = await 导航：路由 pop 新 bookUrl（发生切换）后
                  // 重载书/目录/强制刷新正文；取消（pop null）不做任何事
                  // （原实现未 await，换源后正文不刷新——缺陷根因 B）
                  // 换源闭包体保留 HEAD 基线缩进列（collection-if 后果
                  // 不重新缩进），避免 diff 引入纯空白行
                  if (isOnline) IconButton(
                    icon: const Icon(Symbols.swap_horiz_rounded),
                    tooltip: '换源',
                    onPressed: () => unawaited(_changeSourceFlow(context, book)),
                  ),
                  // [P2-9 | 2026-09-24] 刷新正文 = 强制拉取（绕过缓存，
                  // 见 ReaderNotifier.refreshChapterContent），统一 Fix A
                  // 路径 + 可见反馈（进行中/成功/失败含原因）
                  if (isOnline) IconButton(
                    icon: const Icon(Symbols.refresh_rounded),
                    tooltip: '刷新正文',
                    onPressed: () => unawaited(_refreshContentFlow(context)),
                  ),
                  if (isOnline) IconButton(
                    icon: const Icon(Symbols.download_rounded),
                    tooltip: '缓存当前章',
                    onPressed:
                        () async {
                            final idx = ref
                                .read(readerNotifierProvider)
                                .currentChapterIndex;
                            try {
                              await ref
                                  .read(bookApiProvider)
                                  .cacheDownloadStart(book.bookUrl, idx, idx);
                              if (!context.mounted) return;
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(content: Text('当前章已加入缓存队列')),
                              );
                            } catch (e) {
                              if (!context.mounted) return;
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(content: Text('缓存失败：$e')),
                              );
                            }
                          },
                  ),
                  PopupMenuButton<String>(
                    tooltip: '更多',
                    position: PopupMenuPosition.under,
                    onSelected: (value) {
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
                      }
                    },
                    itemBuilder: (_) => const [
                      PopupMenuItem(value: 'addBookmark', child: Text('添加书签')),
                      PopupMenuItem(
                        value: 'highlightRule',
                        child: Text('高亮规则'),
                      ),
                      PopupMenuItem(value: 'replace', child: Text('替换规则')),
                      PopupMenuItem(value: 'toc', child: Text('查看目录')),
                      PopupMenuItem(value: 'settings', child: Text('界面设置')),
                    ],
                  ),
                ],
              ),
            ),
            if (chapter != null || sourceName.isNotEmpty)
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
                        if (isOnline) _shortcutButton(
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
        autoPageActive
            ? Symbols.pause_rounded
            : Symbols.play_arrow_rounded,
        '自动翻页',
        widget.onToggleAutoPage,
        active: autoPageActive,
      ),
      item(Symbols.format_list_bulleted_rounded, '目录', widget.onOpenCatalog),
      item(Symbols.headphones_rounded, '朗读', widget.onReadAloud),
      item(Symbols.settings_rounded, '设置', widget.onOpenSettings),
    ];
    return SizedBox(
      height: 76,
      child: Row(children: items),
    );
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
    final textStyle = Theme.of(context).textTheme.labelMedium?.copyWith(
      color: progressColor,
    );
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
}
