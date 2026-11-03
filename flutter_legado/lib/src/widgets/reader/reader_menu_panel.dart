import 'dart:async';
import 'dart:convert';
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;

import '../../models/models.dart';
import '../../providers/providers.dart' show bookApiProvider;
import '../../providers/reader/reader_menu_style_notifier.dart';
import '../../providers/reader/reader_notifier.dart';
import '../../providers/reader/reader_top_bar_actions_notifier.dart';
import '../../providers/theme/theme_notifier.dart';
import '../../providers/ui_settings/ui_settings_notifier.dart';
import '../../routes.dart';
import '../../screens/reader_config_panel.dart' show readerAdvConfigProvider;
import '../../services/system_brightness.dart';
import '../../utils/txt_toc_rule.dart' show isLocalTxtBook;
import 'change_chapter_source_sheet.dart';
import 'change_source_flow.dart';
import 'reader_charset_dialog.dart';
import 'reader_download_dialog.dart';
import 'reader_menu_style.dart';
import 'reader_toc_rule_dialog.dart';
import 'reader_top_bar_actions.dart';

/// [UI_SYNC_REFACTOR S2-1] 阅读菜单单块底部面板（对齐参考 ReadBookMenuBar）
///
/// 结构：屏幕顶栏（返回/标题模式或胶囊/换源/刷新正文/下载/更多溢出 +
/// 章节信息块）→ 底部 Surface（进度滑条行 + 可配置五键图标网格）。
/// [批3a] 菜单配色/底栏布局/顶栏标题模式由 ReaderMenuStyle 驱动。
/// [PARITY A5] 键集收敛对齐参考版默认键集：动作行 = 全文搜索/自动翻页/
/// 目录/朗读/设置（参考 ReadButtonConfigDelegate.kt:197-203
/// DEFAULT_ENABLED_BUTTON_IDS = search/auto_page/catalog/read_aloud/setting，
/// 显示顺序 ReadBookContract.kt:404+ ReadBookButtonIds；批3a 起按
/// 每行图标数/行数溢出分页；无字号/亮度键（参考 showBrightnessView 默认
/// "0" 亮度隐藏，字号/亮度保留在读内入口 ReaderSettingsSheet /
/// ReaderConfigPanel）。
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

  /// 父级是否已处理底部系统 inset（`paddingDisplayCutouts` 外层 Padding）
  ///
  /// [批3a P1-1] 为 true 时浮动外边距不再叠加 `MediaQuery.padding.bottom`，
  /// 非浮动面板也不在内部 SafeArea 计底部，避免导航栏/手势条双计。
  final bool parentHandlesBottomInset;

  /// 旧「工具栏跟随页面」布尔参数（兼容既有调用方）
  ///
  /// [批3a] 配色已由 `readBarStyle`（0 系统 / 1 跟随阅读背景 / 2 自定义）
  /// 统一承载；本参数保留签名兼容，但不再参与渲染。旧持久化键
  /// `readBarStyleFollowPage` 仅在 `readBarStyle` 缺失时迁移。
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
    this.parentHandlesBottomInset = false,
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
    // [批3a] 菜单配色由 readBarStyle 统一定源：
    // 0 系统 / 1 跟随阅读背景 / 2 自定义（种子或自定义主题色）。
    // 旧参数 widget.styleFollowPage 保留兼容，但 readBarStyle 优先。
    final menuStyle = ref.watch(readerMenuStyleProvider);
    final menuColors = resolveReaderMenuColors(
      style: menuStyle,
      isDark: Theme.of(context).brightness == Brightness.dark,
      scheme: cs,
      pageBackgroundColor: state.backgroundColor,
      pageTextColor: state.textColor,
      // [批3a P2-3] paletteStyle='' 时跟随应用主题调色板
      appPaletteStyle: uiSettingsListenable.value.themeStyle,
    );
    final adv = ref.watch(readerAdvConfigProvider);
    final autoPageActive = adv?.autoPageTurn ?? false;
    var barColor = menuColors.background;
    // [UI_SYNC_REFACTOR S2-2] 表面 Haze 档（实色等效）：enableBlur 时
    // 半透明底（α 85/255，参考 readMenuBlurAlpha 默认）+ BackdropFilter(24)。
    // [批3a] 跟随阅读背景（readBarStyle=1）不使用模糊，与旧
    // styleFollowPage 语义一致。
    final ui = uiSettingsListenable.value;
    final useSurfaceBlur =
        ui.enableBlur &&
        menuStyle.readBarStyle != ReaderMenuBarStyle.followPage;
    if (useSurfaceBlur) {
      barColor = barColor.withValues(alpha: 85 / 255);
    }
    final radius = menuStyle.bottomCornerRadius.toDouble();
    final panelRadius = menuStyle.floatingBottomBar
        ? BorderRadius.circular(radius)
        : BorderRadius.vertical(top: Radius.circular(radius));

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
                // [批3a] 顶栏风格/标题模式/胶囊/合并按钮由菜单配置驱动。
                _buildTopBar(context, menuStyle, menuColors, book, chapter),
                const Spacer(),
                _buildBottomPanel(
                  context,
                  style: menuStyle,
                  colors: menuColors,
                  barColor: barColor,
                  panelRadius: panelRadius,
                  useSurfaceBlur: useSurfaceBlur,
                  notifier: notifier,
                  state: state,
                  autoPageActive: autoPageActive,
                ),
              ],
            ),
            // [批1b-1] 亮度竖条（模式='2'）：贴左/右缘居中（对齐参考版
            // ReadBookMenuBar.kt:189-274 CenterStart/CenterEnd + 圆角 40
            // 胶囊形态）；与底部面板/顶部栏不重叠，滑动手势区域独立，
            // 不遮挡翻页点击区（菜单展开时翻页手势本已停用）— 全栈工程师
            if (widget.brightnessMode == '2')
              // [批3a P2-11] 竖条前景与胶囊底色 cs.surface 同源
              _buildVerticalBrightnessBar(
                context,
                Theme.of(context).colorScheme.onSurfaceVariant,
              ),
          ],
        ),
      ),
    );
  }

  /// [批3a] 底部面板外壳：浮动（16dp 边距/四角圆角）或贴底全宽（仅上圆角）
  Widget _buildBottomPanel(
    BuildContext context, {
    required ReaderMenuStyle style,
    required ResolvedReaderMenuColors colors,
    required Color barColor,
    required BorderRadius panelRadius,
    required bool useSurfaceBlur,
    required ReaderNotifier notifier,
    required ReaderState state,
    required bool autoPageActive,
  }) {
    Widget surface = _panelSurface(
      context,
      style: style,
      colors: colors,
      barColor: barColor,
      panelRadius: panelRadius,
      notifier: notifier,
      state: state,
      autoPageActive: autoPageActive,
    );
    if (useSurfaceBlur) {
      surface = ClipRRect(
        borderRadius: panelRadius,
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
          child: surface,
        ),
      );
    }
    if (!style.floatingBottomBar) return surface;
    // [批3a P1-1] 浮动形态：外边距 16 + 系统导航栏/手势条高度；
    // 面板内部 SafeArea(bottom:false)，避免同一 padding.bottom 双计。
    // 父级（reader_screen paddingDisplayCutouts）已加底部 inset 时传 0。
    final bottomInset = widget.parentHandlesBottomInset
        ? 0.0
        : MediaQuery.paddingOf(context).bottom;
    return Padding(
      key: const ValueKey('reader-bottom-panel-floating'),
      padding: EdgeInsets.fromLTRB(16, 0, 16, 16 + bottomInset),
      child: surface,
    );
  }

  Widget _panelSurface(
    BuildContext context, {
    required ReaderMenuStyle style,
    required ResolvedReaderMenuColors colors,
    required Color barColor,
    required BorderRadius panelRadius,
    required ReaderNotifier notifier,
    required ReaderState state,
    required bool autoPageActive,
  }) {
    // [批3a] 面板键集对齐参考版：进度行 + 可配置 5 键图标网格
    //（全文搜索/自动翻页/目录/朗读/设置）。
    return Material(
      key: const ValueKey('reader-bottom-panel-surface'),
      color: barColor,
      borderRadius: panelRadius,
      clipBehavior: Clip.antiAlias,
      child: SafeArea(
        top: false,
        // 浮动形态底部留白已由外层 Padding 计入；贴底形态仍需 SafeArea
        // 导航栏（父级已处理时不再重复）
        bottom: !style.floatingBottomBar && !widget.parentHandlesBottomInset,
        child: IconTheme(
          data: IconThemeData(color: colors.text),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // [批1b-1 审查回修 P1-1] 亮度横条（模式='1'）：挂进菜单底部
              // 面板进度行上方（对齐参考版 ReadBookMenuBarBottom.kt:138
              // showBrightnessView=="1" → BrightnessBar(horizontal) 行）；
              // ReaderBottomBar 已被本面板取代、生产不再挂载，横条消费点
              // 收敛到唯一生产路径 — 全栈工程师
              if (widget.brightnessMode == '1')
                _buildHorizontalBrightnessRow(context, colors.text),
              _buildProgressRow(context, notifier, state, colors),
              _buildActionRow(
                context,
                style: style,
                colors: colors,
                autoPageActive: autoPageActive,
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ===== [批1b-1 审查回修 P1-1] 亮度横条行（模式='1'） =====

  /// 亮度横条行：自动亮度钮 + 亮度滑条（结构对齐原 ReadMenu 底栏
  /// ll_brightness 亮度行；亮度值与竖条同源 SystemBrightness 服务）。
  Widget _buildHorizontalBrightnessRow(
    BuildContext context,
    Color? foreground,
  ) {
    return _HorizontalBrightnessRow(foreground: foreground);
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
  ///
  /// [批3a] 图标容器三态由 `titleBarIconStyle` 独立控制（0 透明 / 1 圆底 /
  /// 2 描边）；合并模式下按钮不再各自包容器，由外层胶囊统一承载。
  Widget _buildTopBarActionButton(
    BuildContext context, {
    required Book? book,
    required ReaderTopBarActionDef def,
    required ReaderMenuStyle style,
    required ResolvedReaderMenuColors colors,
    required bool merged,
  }) {
    return Tooltip(
      message: def.label,
      triggerMode: TooltipTriggerMode.manual,
      child: GestureDetector(
        key: ValueKey('reader-topbar-action-${def.id}'),
        onLongPress: def.longPress == null
            ? null
            : () => _performTopBarLongPress(context, book, def.longPress!),
        child: _topBarIconSurface(
          context,
          icon: def.icon,
          label: def.label,
          style: style,
          colors: colors,
          merged: merged,
          onTap: () => unawaited(_performTopBarAction(context, book, def.id)),
        ),
      ),
    );
  }

  /// [批3a] 顶栏图标按钮表面（40dp 圆形热区，图标 20dp）
  ///
  /// [merged] 为 true 时由外层合并胶囊提供底色/描边，本按钮只画图标；
  /// 独立按钮按 `titleBarIconStyle` 画三态容器。非选中图标用
  /// onSurfaceVariant（参考 `ReadMenuGlassButtonSurface`）。
  Widget _topBarIconSurface(
    BuildContext context, {
    required IconData icon,
    required String label,
    required ReaderMenuStyle style,
    required ResolvedReaderMenuColors colors,
    required bool merged,
    required VoidCallback onTap,
  }) {
    // 顶栏动作当前无选中态（无调用方传 selected）；合并态仅染图标。
    final tint = colors.onSurfaceVariant;
    Color? containerColor;
    Border? border;
    if (merged) {
      containerColor = null;
    } else {
      switch (style.titleIconStyle) {
        case ReaderMenuIconStyle.tonal:
          containerColor = colors.container;
        case ReaderMenuIconStyle.outlined:
          containerColor = Colors.transparent;
          border = Border.all(
            color: colors.onSurfaceVariant.withValues(alpha: 0.45),
          );
        default:
          containerColor = Colors.transparent;
      }
    }
    return Semantics(
      button: true,
      label: label,
      child: InkWell(
        onTap: onTap,
        customBorder: const CircleBorder(),
        child: Container(
          key: ValueKey('reader-topbar-icon-surface-$label'),
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: containerColor,
            border: border,
          ),
          child: Icon(icon, size: 20, color: tint),
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

  // ── 分区 1：屏幕顶部工具栏（[批3a] 标题模式/胶囊/合并按钮）──
  //
  // 参考版 `ReadBookMenuBarTitle.kt`：
  // - titleBarMode '0' 书名在顶栏行内 / '1' 书名另起一行 / '2' 仅章节 /
  //   '3' 不显示标题与章节；
  // - 标题胶囊（readMenuTopBarTitleCapsule）显示书名 + 章名，点击进书籍详情；
  // - 合并按钮（readMenuTopBarMergeButtons）把右侧动作塞进一个 20 圆角胶囊；
  // - 图标容器三态由 titleBarIconStyle 独立控制（0 透明 / 1 圆底 / 2 描边）。
  Widget _buildTopBar(
    BuildContext context,
    ReaderMenuStyle style,
    ResolvedReaderMenuColors colors,
    Book? book,
    BookChapter? chapter,
  ) {
    final sourceName = book?.originName ?? '';
    // [批1a] showReadTitleAddition：关闭后章节/书源信息块整体不渲染
    final showTitleAddition = ref.watch(
      readerAdvConfigProvider.select((v) => v?.showReadTitleAddition ?? true),
    );
    // [P2-9 / 批37b] 在线书判定（origin 为空与类型位本地书均按本地处理）
    final isOnline = book != null && !_isLocalBook(book);
    // [批37] 顶栏动作可配置：顺序/开关来自用户配置，按书型过滤，
    // 最多 6 个（含末尾固定的「更多」）。
    final actionConfig = ref.watch(readerTopBarActionsProvider);
    final traits = ReaderBookTraits(
      isLocal: book != null && !isOnline,
      isLocalTxt: book != null && _isLocalTxtBook(book),
    );
    final topBarActions = book == null
        ? <ReaderTopBarActionDef>[readerTopBarActionById[kReaderMoreActionsId]!]
        : buildReaderTopBarActions(actionConfig, traits: traits);
    final visibleActionIds = {for (final def in topBarActions) def.id};
    // 「更多」菜单兜底：被移出顶栏的动作仍从这里可达。
    final hiddenActions = book == null
        ? const <ReaderTopBarActionDef>[]
        : hiddenReaderTopBarActions(
            actionConfig,
            traits: traits,
            visibleIds: visibleActionIds,
            excludeIds: _moreMenuOwnActionIds,
          );

    final mode = style.titleBarMode;
    final showCapsule =
        style.titleCapsule &&
        book != null &&
        mode != ReaderMenuTitleBarMode.hidden;
    final showBookInRow =
        !showCapsule && book != null && mode == ReaderMenuTitleBarMode.inTopBar;
    final showBookOwnLine =
        !showCapsule && book != null && mode == ReaderMenuTitleBarMode.ownLine;
    final showChapterRow =
        !showCapsule &&
        showTitleAddition &&
        mode != ReaderMenuTitleBarMode.hidden &&
        (chapter != null || sourceName.isNotEmpty);

    return Material(
      color: colors.background,
      child: SafeArea(
        bottom: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
              child: Row(
                children: [
                  IconButton(
                    icon: Icon(
                      Symbols.arrow_back_rounded,
                      size: 20,
                      semanticLabel: '退出阅读',
                      color: colors.onSurfaceVariant,
                    ),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints.tightFor(
                      width: 40,
                      height: 40,
                    ),
                    visualDensity: VisualDensity.compact,
                    tooltip: '退出阅读',
                    onPressed: widget.onBack,
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        // [批3a P2-6] 动作区优先占位：先按动作自然宽度
                        // （40dp/个 + 独立态 6dp 间距）分配，剩余给标题；
                        // 6 动作在 320dp 时标题收敛为 0，动作整体 scaleDown，
                        // 保证全部可见且可点，不产生 RenderFlex 溢出。
                        final actionNaturalWidth = style.mergeButtons
                            ? topBarActions.length * 40.0
                            : topBarActions.length * 40.0 +
                                  (topBarActions.length - 1) * 6.0;
                        final actionWidth = actionNaturalWidth
                            .clamp(0.0, constraints.maxWidth)
                            .toDouble();
                        final titleWidth =
                            (constraints.maxWidth -
                                    actionWidth -
                                    (actionWidth > 0 ? 16.0 : 0.0))
                                .clamp(0.0, constraints.maxWidth)
                                .toDouble();
                        final title = showCapsule
                            ? _buildTitleCapsule(
                                context,
                                style: style,
                                colors: colors,
                                book: book,
                                chapter: chapter,
                              )
                            : showBookInRow
                            ? InkWell(
                                key: const ValueKey(
                                  'reader-topbar-book-name',
                                ),
                                onTap: () => _openBookInfo(context, book),
                                child: SizedBox(
                                  width: double.infinity,
                                  child: Text(
                                    book.name,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: Theme.of(context)
                                        .textTheme
                                        .titleMedium
                                        ?.copyWith(color: colors.text),
                                  ),
                                ),
                              )
                            : const SizedBox.shrink();
                        final actions = style.mergeButtons
                            ? _buildMergedTopBarActions(
                                context,
                                style: style,
                                colors: colors,
                                book: book,
                                topBarActions: topBarActions,
                                hiddenActions: hiddenActions,
                              )
                            : Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  for (
                                    var i = 0;
                                    i < topBarActions.length;
                                    i++
                                  ) ...[
                                    if (i > 0) const SizedBox(width: 6),
                                    if (topBarActions[i].id ==
                                        kReaderMoreActionsId)
                                      _buildMoreMenuButton(
                                        context,
                                        book: book,
                                        hiddenActions: hiddenActions,
                                        style: style,
                                        colors: colors,
                                        merged: false,
                                      )
                                    else
                                      _buildTopBarActionButton(
                                        context,
                                        book: book,
                                        def: topBarActions[i],
                                        style: style,
                                        colors: colors,
                                        merged: false,
                                      ),
                                  ],
                                ],
                              );
                        return Row(
                          children: [
                            if (titleWidth > 0) ...[
                              SizedBox(width: titleWidth, child: title),
                              const SizedBox(width: 16),
                            ],
                            Flexible(
                              fit: FlexFit.loose,
                              child: SizedBox(
                                width: actionWidth,
                                child: FittedBox(
                                  fit: BoxFit.scaleDown,
                                  alignment: Alignment.centerRight,
                                  child: actions,
                                ),
                              ),
                            ),
                          ],
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
            // titleBarMode '1'：书名另起一行（胶囊开启时隐藏）
            if (showBookOwnLine)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
                child: InkWell(
                  key: const ValueKey('reader-topbar-book-name-own-line'),
                  onTap: () => _openBookInfo(context, book),
                  child: SizedBox(
                    width: double.infinity,
                    child: Text(
                      book.name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(
                        context,
                      ).textTheme.titleMedium?.copyWith(color: colors.text),
                    ),
                  ),
                ),
              ),
            // titleBarMode '0'/'1'/'2'：章节名 + 书源徽标（mode 3 整体隐藏）
            if (showChapterRow)
              _buildChapterInfoRow(
                context,
                chapter: chapter,
                sourceName: sourceName,
                colors: colors,
              ),
            const SizedBox(height: 4),
          ],
        ),
      ),
    );
  }

  /// 书名/胶囊点击进入书籍详情（沿用现有 BookInfo 路由参数约定：Book）
  void _openBookInfo(BuildContext context, Book book) {
    Navigator.pushNamed(context, AppRoutes.bookInfo, arguments: book);
  }

  /// 顶栏标题胶囊：书名 labelMedium + 章名 labelSmall@0.7（圆角 50/高 40）
  Widget _buildTitleCapsule(
    BuildContext context, {
    required ReaderMenuStyle style,
    required ResolvedReaderMenuColors colors,
    required Book book,
    BookChapter? chapter,
  }) {
    final textTheme = Theme.of(context).textTheme;
    final chapterTitle = chapter?.title ?? '';
    return InkWell(
      key: const ValueKey('reader-topbar-title-capsule'),
      onTap: () => _openBookInfo(context, book),
      borderRadius: BorderRadius.circular(50),
      child: Container(
        // [批3a P2-10] 胶囊随字体缩放增高（两行文本仍各 maxLines 1）
        constraints: const BoxConstraints(minHeight: 40),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(50),
          color: style.titleIconStyle == ReaderMenuIconStyle.tonal
              ? colors.container
              : Colors.transparent,
          border: style.titleIconStyle == ReaderMenuIconStyle.outlined
              ? Border.all(
                  color: colors.onSurfaceVariant.withValues(alpha: 0.45),
                )
              : null,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              book.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: textTheme.labelMedium?.copyWith(
                color: colors.text,
                fontWeight: FontWeight.w600,
              ),
            ),
            if (chapterTitle.isNotEmpty)
              Text(
                chapterTitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: textTheme.labelSmall?.copyWith(
                  color: colors.text.withValues(alpha: 0.7),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// 章节信息行：章节名 + 书源小字徽标（替代旧中部快捷钮行）
  Widget _buildChapterInfoRow(
    BuildContext context, {
    required BookChapter? chapter,
    required String sourceName,
    required ResolvedReaderMenuColors colors,
  }) {
    final onAccent = colors.accent.computeLuminance() > 0.5
        ? Colors.black
        : Colors.white;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              chapter?.title ?? '',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: colors.text,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          if (sourceName.isNotEmpty) ...[
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
              decoration: BoxDecoration(
                color: colors.accent,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                sourceName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12, color: onAccent),
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// 合并态顶栏动作：单个 20 圆角胶囊容器，按钮间无 6dp 间距
  Widget _buildMergedTopBarActions(
    BuildContext context, {
    required ReaderMenuStyle style,
    required ResolvedReaderMenuColors colors,
    required Book? book,
    required List<ReaderTopBarActionDef> topBarActions,
    required List<ReaderTopBarActionDef> hiddenActions,
  }) {
    return Container(
      key: const ValueKey('reader-topbar-merged-actions'),
      height: 40,
      decoration: BoxDecoration(
        // [批3a P2-5] 仅 tonal 档使用容器底色，其余透明
        color: style.titleIconStyle == ReaderMenuIconStyle.tonal
            ? colors.container
            : Colors.transparent,
        borderRadius: BorderRadius.circular(20),
        border: style.titleIconStyle == ReaderMenuIconStyle.outlined
            ? Border.all(color: colors.onSurfaceVariant.withValues(alpha: 0.45))
            : null,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final def in topBarActions)
            if (def.id == kReaderMoreActionsId)
              _buildMoreMenuButton(
                context,
                book: book,
                hiddenActions: hiddenActions,
                style: style,
                colors: colors,
                merged: true,
              )
            else
              _buildTopBarActionButton(
                context,
                book: book,
                def: def,
                style: style,
                colors: colors,
                merged: true,
              ),
        ],
      ),
    );
  }

  /// 「更多」溢出按钮（独立 40dp 圆形或合并胶囊内的纯图标）
  Widget _buildMoreMenuButton(
    BuildContext context, {
    required Book? book,
    required List<ReaderTopBarActionDef> hiddenActions,
    required ReaderMenuStyle style,
    required ResolvedReaderMenuColors colors,
    required bool merged,
  }) {
    return PopupMenuButton<String>(
      tooltip: '更多',
      position: PopupMenuPosition.under,
      padding: EdgeInsets.zero,
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
            Navigator.pushNamed(context, AppRoutes.highlightRules);
          case 'replace':
            widget.onOpenReplaceRules();
          case 'settings':
            widget.onOpenSettings();
          case 'toc':
            widget.onOpenCatalog();
          case 'reverseTocDisplay':
            // [批31] 目录显示反转（对齐原版 ReadConfig.reverseTocDisplay）：
            // 仅展示层反序，数据顺序/章节身份不变，无需重载正文
            if (book != null) {
              unawaited(_toggleReverseTocDisplay(book));
            }
        }
      },
      child: _topBarIconVisual(
        icon: Symbols.more_vert_rounded,
        label: '更多',
        style: style,
        colors: colors,
        merged: merged,
      ),
      itemBuilder: (_) => [
        const PopupMenuItem(value: 'addBookmark', child: Text('添加书签')),
        const PopupMenuItem(value: 'highlightRule', child: Text('高亮规则')),
        const PopupMenuItem(value: 'replace', child: Text('替换规则')),
        const PopupMenuItem(value: 'toc', child: Text('查看目录')),
        CheckedPopupMenuItem(
          value: 'reverseTocDisplay',
          checked: book?.readConfig?.reverseTocDisplay ?? false,
          child: const Text('目录显示反转'),
        ),
        const PopupMenuItem(value: 'settings', child: Text('界面设置')),
        // [批37] 顶栏未显示的动作兜底（换源/刷新/缓存/编码等）
        if (hiddenActions.isNotEmpty) ...[
          const PopupMenuDivider(),
          for (final def in hiddenActions)
            PopupMenuItem(
              value: '$_moreActionValuePrefix${def.id}',
              child: Text(def.label),
            ),
        ],
      ],
    );
  }

  /// 顶栏按钮的纯视觉（不含点击层）：供 PopupMenuButton / 普通按钮复用
  Widget _topBarIconVisual({
    required IconData icon,
    required String label,
    required ReaderMenuStyle style,
    required ResolvedReaderMenuColors colors,
    required bool merged,
  }) {
    Color? containerColor;
    Border? border;
    if (!merged) {
      switch (style.titleIconStyle) {
        case ReaderMenuIconStyle.tonal:
          containerColor = colors.container;
        case ReaderMenuIconStyle.outlined:
          containerColor = Colors.transparent;
          border = Border.all(
            color: colors.onSurfaceVariant.withValues(alpha: 0.45),
          );
        default:
          containerColor = Colors.transparent;
      }
    }
    return Semantics(
      button: true,
      label: label,
      child: Container(
        key: ValueKey('reader-topbar-icon-surface-$label'),
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: containerColor,
          border: border,
        ),
        child: Icon(icon, size: 20, color: colors.onSurfaceVariant),
      ),
    );
  }

  // ── 分区：五键图标网格（[批3a] 参考 ReadBookMenuBarBottom.kt:200-290）──
  //
  // 键集固定为参考默认五键：全文搜索/自动翻页/目录/朗读/设置
  //（ReadButtonConfigDelegate DEFAULT_ENABLED_BUTTON_IDS）。
  // 布局：每行 itemsPerRow（2..8）、共 rowCount（1..2）行、溢出用 PageView；
  // 行距 12dp、每行 SpaceBetween、按钮 40dp 圆形、图标 20dp；
  // showIconText 时图标下 2dp + labelSmall（maxLines 1）。
  Widget _buildActionRow(
    BuildContext context, {
    required ReaderMenuStyle style,
    required ResolvedReaderMenuColors colors,
    required bool autoPageActive,
  }) {
    final items = <_ReaderMenuAction>[
      _ReaderMenuAction(
        icon: Symbols.search_rounded,
        label: '全文搜索',
        onTap: widget.onOpenContentSearch,
      ),
      _ReaderMenuAction(
        icon: autoPageActive
            ? Symbols.pause_rounded
            : Symbols.play_arrow_rounded,
        label: '自动翻页',
        onTap: widget.onToggleAutoPage,
        active: autoPageActive,
      ),
      _ReaderMenuAction(
        icon: Symbols.format_list_bulleted_rounded,
        label: '目录',
        onTap: widget.onOpenCatalog,
      ),
      _ReaderMenuAction(
        icon: Symbols.headphones_rounded,
        label: '朗读',
        onTap: widget.onReadAloud,
      ),
      _ReaderMenuAction(
        icon: Symbols.settings_rounded,
        label: '设置',
        onTap: widget.onOpenSettings,
      ),
    ];
    final pageSize = style.pageSize;
    final pageCount = (items.length + pageSize - 1) ~/ pageSize;
    // [批3a P1-3] 图标文字高度按系统字体缩放伸展，避免大字体纵向溢出
    final itemHeight = style.showIconText
        ? 42.0 + MediaQuery.textScalerOf(context).scale(16)
        : 40.0;
    final gridHeight =
        style.rowCount * itemHeight + (style.rowCount - 1) * 12.0;

    Widget pageBuilder(int page) {
      final pageItems = items.skip(page * pageSize).take(pageSize).toList();
      final rows = <Widget>[];
      for (
        var start = 0;
        start < pageItems.length;
        start += style.itemsPerRow
      ) {
        final rowItems = pageItems
            .skip(start)
            .take(style.itemsPerRow)
            .toList(growable: false);
        if (rows.isNotEmpty) rows.add(const SizedBox(height: 12));
        rows.add(
          _buildBottomActionRow(
            context,
            rowItems: rowItems,
            itemHeight: itemHeight,
            style: style,
            colors: colors,
          ),
        );
      }
      return Column(mainAxisSize: MainAxisSize.min, children: rows);
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      child: SizedBox(
        height: gridHeight,
        child: pageCount > 1
            ? _BottomActionPager(pageCount: pageCount, pageBuilder: pageBuilder)
            : pageBuilder(0),
      ),
    );
  }

  /// [批3a] 单行图标：常规宽度按 SpaceBetween 铺满；
  /// 窄屏 + 每行 8 个（8×40dp 超过浮动面板可用宽度）时整体等比缩放兜底，
  /// 避免 RenderFlex 横向溢出，同时保持参考版 40dp 按钮的视觉比例。
  Widget _buildBottomActionRow(
    BuildContext context, {
    required List<_ReaderMenuAction> rowItems,
    required double itemHeight,
    required ReaderMenuStyle style,
    required ResolvedReaderMenuColors colors,
  }) {
    final children = [
      for (final item in rowItems)
        _buildBottomActionItem(
          context,
          action: item,
          style: style,
          colors: colors,
        ),
    ];
    return SizedBox(
      height: itemHeight,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final naturalWidth = rowItems.length * 40.0;
          if (naturalWidth <= constraints.maxWidth) {
            return Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: children,
            );
          }
          return Align(
            alignment: Alignment.center,
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: SizedBox(
                width: naturalWidth,
                height: itemHeight,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: children,
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  /// 底栏单个图标按钮（三态容器 + 选中态，语义 label=文案）
  Widget _buildBottomActionItem(
    BuildContext context, {
    required _ReaderMenuAction action,
    required ReaderMenuStyle style,
    required ResolvedReaderMenuColors colors,
  }) {
    final scheme = Theme.of(context).colorScheme;
    Color? containerColor;
    Border? border;
    if (action.active) {
      containerColor = scheme.secondaryContainer;
      border = Border.all(color: scheme.secondary, width: 1.5);
    } else {
      switch (style.iconStyle) {
        case ReaderMenuIconStyle.tonal:
          containerColor = colors.container;
        case ReaderMenuIconStyle.outlined:
          containerColor = Colors.transparent;
          border = Border.all(
            color: colors.onSurfaceVariant.withValues(alpha: 0.45),
          );
        default:
          containerColor = Colors.transparent;
      }
    }
    final tint = action.active ? colors.accent : colors.onSurfaceVariant;
    // 与 _buildActionRow 的 itemHeight 同一度量：文字行高 = 16 * textScale。
    // SizedBox 固定行高 + OverflowBox 允许横向自然绘制，纵向不撑破 Column。
    final labelHeight = MediaQuery.textScalerOf(context).scale(16);
    return Tooltip(
      key: ValueKey('reader-menu-action-${action.label}'),
      message: action.label,
      child: Semantics(
        button: true,
        container: true,
        label: action.label,
        child: InkWell(
          onTap: action.onTap,
          borderRadius: BorderRadius.circular(20),
          child: SizedBox(
            width: 40,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  key: ValueKey('reader-menu-action-surface-${action.label}'),
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: containerColor,
                    border: border,
                  ),
                  child: Icon(action.icon, size: 20, color: tint),
                ),
                if (style.showIconText) ...[
                  const SizedBox(height: 2),
                  // [批3a P2-4] 文字不锁 40dp 定宽：OverflowBox 居中自然
                  // 绘制，避免「全文搜索」等标签被 ellipsis 截断
                  SizedBox(
                    height: labelHeight,
                    child: OverflowBox(
                      alignment: Alignment.topCenter,
                      minWidth: 0,
                      maxWidth: double.infinity,
                      minHeight: labelHeight,
                      maxHeight: labelHeight,
                      child: Text(
                        action.label,
                        maxLines: 1,
                        softWrap: false,
                        overflow: TextOverflow.visible,
                        textAlign: TextAlign.center,
                        style: Theme.of(
                          context,
                        ).textTheme.labelSmall?.copyWith(color: colors.text),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ── 分区：进度滑条行（page=调章内页 / chapter=调章节）──
  Widget _buildProgressRow(
    BuildContext context,
    ReaderNotifier notifier,
    ReaderState state,
    ResolvedReaderMenuColors colors,
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
    // [批3a P2-9] 进度条 thumb/track 用强调色，文字仍用菜单文字色
    final progressColor = colors.text;
    final sliderTheme = SliderTheme.of(context).copyWith(
      trackHeight: 8,
      year2023: false,
      thumbColor: colors.accent,
      activeTrackColor: colors.accent.withValues(alpha: 0.25),
      inactiveTrackColor: colors.accent.withValues(alpha: 0.12),
      disabledActiveTrackColor: colors.accent.withValues(alpha: 0.15),
      disabledInactiveTrackColor: colors.accent.withValues(alpha: 0.08),
      activeTickMarkColor: Colors.transparent,
      inactiveTickMarkColor: colors.accent.withValues(alpha: 0.35),
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

/// [批1b-1 审查回修 P1-1] 亮度横条行内容（模式='1'，StatefulWidget 独立
/// 承载亮度异步加载与拖动值，避免污染面板整体 rebuild）
class _HorizontalBrightnessRow extends StatefulWidget {
  final Color? foreground;

  const _HorizontalBrightnessRow({required this.foreground});

  @override
  State<_HorizontalBrightnessRow> createState() =>
      _HorizontalBrightnessRowState();
}

class _HorizontalBrightnessRowState extends State<_HorizontalBrightnessRow> {
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
      debugPrint('亮度通道不可用，隐藏亮度行: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_supported) return const SizedBox.shrink();
    final fg = widget.foreground ??
        Theme.of(context).colorScheme.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(
        children: [
          IconButton(
            icon: Icon(
              _auto
                  ? Icons.brightness_auto
                  : Icons.brightness_auto_outlined,
              color: fg,
            ),
            tooltip: _auto ? '关闭自动亮度' : '自动亮度',
            // [批1b-1 审查回修 P2-5] 双向切换：开启后可关闭（对齐参考版
            // onToggleAuto = ToggleBrightnessAuto(!brightnessAuto)）
            onPressed: () async {
              await SystemBrightness.setAutoBrightness(!_auto);
              await _load();
            },
          ),
          Expanded(
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
        ],
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
                // [批1b-1 审查回修 P2-5] 双向切换：开启后可关闭（对齐参考版
                // onToggleAuto = ToggleBrightnessAuto(!brightnessAuto)）
                onPressed: () async {
                  await SystemBrightness.setAutoBrightness(!_auto);
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

/// [批3a] 底栏五键动作定义
class _ReaderMenuAction {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool active;

  const _ReaderMenuAction({
    required this.icon,
    required this.label,
    required this.onTap,
    this.active = false,
  });
}

/// [批3a] 底栏溢出分页：页数变化时把当前页收敛到有效范围
class _BottomActionPager extends StatefulWidget {
  final int pageCount;
  final Widget Function(int page) pageBuilder;

  const _BottomActionPager({
    required this.pageCount,
    required this.pageBuilder,
  });

  @override
  State<_BottomActionPager> createState() => _BottomActionPagerState();
}

class _BottomActionPagerState extends State<_BottomActionPager> {
  final PageController _controller = PageController();

  @override
  void didUpdateWidget(covariant _BottomActionPager oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.pageCount == widget.pageCount) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_controller.hasClients) return;
      final current = _controller.page?.round() ?? 0;
      final target = current.clamp(0, widget.pageCount - 1);
      if (current != target) _controller.jumpToPage(target);
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PageView.builder(
      controller: _controller,
      itemCount: widget.pageCount,
      itemBuilder: (context, page) => widget.pageBuilder(page),
    );
  }
}
