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
import '../../services/system_brightness.dart';
import '../../l10n/app_strings.dart';

/// [UI_SYNC_REFACTOR S2-1] 阅读菜单单块底部面板（对齐参考 ReadBookMenuBar）
///
/// 五分区骨架：标题胶囊行（返回+书名+章节/源+More 溢出）→ FloatingIconRow
///（高频 8 位图标行）→ Surface（亮度行/进度滑条/搜索 pill/工具行）。
/// 常挂载+双向动画（visible 驱动）；朗读条暂与面板互斥显示（S2-2 并入面板
/// 路由页，登记）；标题行 More 为顶栏溢出菜单高频项子集（charset/图片样式
/// 等长尾项留顶栏文件待 S2-2 迁移）。
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

  /// 五项行动作行分页控制器（对齐参考版可横滑两页）
  final PageController _actionPageController = PageController();

  // 亮度（自旧 ReaderBottomBar 迁移）
  bool _brightnessSupported = false;
  bool _autoBrightness = false;
  double _brightness = 0.5;

  @override
  void initState() {
    super.initState();
    unawaited(_loadBrightness());
  }

  Future<void> _loadBrightness() async {
    try {
      final supported = await SystemBrightness.isSupported();
      if (!mounted) return;
      setState(() => _brightnessSupported = supported);
      if (!supported) return;
      final b = await SystemBrightness.getBrightness();
      final auto = await SystemBrightness.isAutoBrightness();
      if (!mounted) return;
      setState(() {
        _brightness = b;
        _autoBrightness = auto;
      });
    } catch (_) {}
  }

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
    _actionPageController.dispose();
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
    // [UI_SYNC_REFACTOR S2-2] 亮度竖条（对齐参考 brightnessVwPos 左右双位；
    // readMenuBrightnessVertical 开关，横行同步隐藏）
    final cs = Theme.of(context).colorScheme;
    final ui = uiSettingsListenable.value;
    final verticalBrightness =
        _brightnessSupported && ui.readMenuBrightnessVertical;
    final barOnLeft = ui.readMenuBrightnessPos == 'left';

    Widget surface = Material(
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
              // [UI_SYNC_REFACTOR S6 修 | 2026-09-08] 面板行序对齐参考版：
              // 亮度条 → 章节滑条（两侧箭头）→ 可横滑五项行
              //（章节梗概/AI改写/全文搜索/自动翻页/目录 ‖ 朗读/界面/替换/更多）
              // 替换原「图标行+全文搜索pill+底部文字行」三块 — Qoder
              if (!verticalBrightness) _buildBrightnessRow(context, foreground),
              _buildProgressRow(context, notifier, state, foreground),
              _buildActionPages(context, foreground, autoPageActive),
            ],
          ),
        ),
      ),
    );

    if (verticalBrightness) {
      surface = Stack(
        children: [
          surface,
          Positioned(
            bottom: 24,
            left: barOnLeft ? 6 : null,
            right: barOnLeft ? null : 6,
            child: Container(
              width: 40,
              height: 168,
              decoration: BoxDecoration(
                color: cs.surfaceContainerHighest.withValues(alpha: 0.7),
                borderRadius: BorderRadius.circular(40),
              ),
              child: RotatedBox(
                quarterTurns: barOnLeft ? 3 : 1,
                child: Slider(
                  value: _brightness,
                  onChanged: _autoBrightness
                      ? null
                      : (v) {
                          setState(() => _brightness = v);
                          unawaited(SystemBrightness.setBrightness(v));
                        },
                ),
              ),
            ),
          ),
        ],
      );
    }
    return surface;
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
    final sourceName = book?.originName ?? '';
    final chapterUrl = chapter?.url ?? '';
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
                  IconButton(
                    icon: const Icon(Symbols.swap_horiz_rounded),
                    tooltip: '换源',
                    onPressed: book == null
                        ? null
                        : () => Navigator.pushNamed(
                            context,
                            AppRoutes.changeSource,
                            arguments: book,
                          ),
                  ),
                  IconButton(
                    icon: const Icon(Symbols.refresh_rounded),
                    tooltip: '刷新正文',
                    onPressed: () => unawaited(notifier.reloadChapterContent()),
                  ),
                  IconButton(
                    icon: const Icon(Symbols.download_rounded),
                    tooltip: '缓存当前章',
                    onPressed: book == null
                        ? null
                        : () async {
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
                    if (chapterUrl.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(
                          chapterUrl,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 11,
                            color: Theme.of(
                              context,
                            ).colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    // [UI_SYNC_REFACTOR S6 修 | 2026-09-08] 用户反馈②：
                    // 顶栏信息下方补五个圆形浮动快捷钮
                    //（搜索/目录/朗读/设置/换源）— Qoder
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
                        _shortcutButton(
                          context,
                          Symbols.swap_horiz_rounded,
                          '换源',
                          book == null
                              ? null
                              : () => Navigator.pushNamed(
                                  context,
                                  AppRoutes.changeSource,
                                  arguments: book,
                                ),
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

  /// 圆形浮动快捷钮（顶栏信息下方五项：搜索/目录/朗读/设置/换源）
  Widget _shortcutButton(
    BuildContext context,
    IconData icon,
    String tip,
    VoidCallback? onTap,
  ) {
    final cs = Theme.of(context).colorScheme;
    return Material(
      color: cs.surfaceContainerHighest.withValues(alpha: 0.7),
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        splashFactory: NoSplash.splashFactory,
        highlightColor: Colors.transparent,
        onTap: onTap,
        child: SizedBox(
          width: 44,
          height: 44,
          child: Icon(
            icon,
            size: 20,
            color: onTap == null
                ? cs.onSurface.withValues(alpha: 0.35)
                : cs.onSurface,
          ),
        ),
      ),
    );
  }

  // ── 分区：可横滑五项行动作行（对齐参考版：图标+标签，两页）──
  //
  // [UI_SYNC_REFACTOR S6 修 | 2026-09-08] 对齐参考版主菜单：
  // 第1页 章节梗概/AI改写/全文搜索/自动翻页/目录；
  // 第2页 朗读/界面/替换/更多（参考版第2页为 朗读/设置，我方补替换与
  // 更多以保留功能入口）。章节梗概/AI改写为已授权 AI 占位按钮 — Qoder
  Widget _buildActionPages(
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

    final page1 = <Widget>[
      item(
        Symbols.auto_awesome_rounded,
        '章节梗概',
        () => _showAiPlaceholder(context, '章节梗概'),
      ),
      item(
        Symbols.edit_note_rounded,
        'AI 改写',
        () => _showAiPlaceholder(context, 'AI 改写'),
      ),
      item(Symbols.search_rounded, '全文搜索', widget.onOpenContentSearch),
      item(
        autoPageActive ? Icons.pause : Icons.auto_stories_outlined,
        autoPageActive ? '停止翻页' : '自动翻页',
        widget.onToggleAutoPage,
        active: autoPageActive,
      ),
      item(Symbols.format_list_bulleted_rounded, '目录', widget.onOpenCatalog),
    ];
    final page2 = <Widget>[
      item(Symbols.headphones_rounded, '朗读', widget.onReadAloud),
      item(Symbols.style_rounded, '界面', widget.onOpenSettings),
      item(Symbols.find_replace_rounded, '替换', widget.onOpenReplaceRules),
      item(Symbols.tune_rounded, '更多', widget.onOpenAdvancedConfig),
    ];
    return SizedBox(
      height: 76,
      child: PageView(
        controller: _actionPageController,
        children: [
          Row(children: page1),
          Row(children: page2),
        ],
      ),
    );
  }

  /// AI 占位弹层（章节梗概/AI 改写）：按钮占位先行（AGENTS 授权口径），
  /// 服务后端独立立项；形态对齐参考版弹层（把手 + 标题 + 状态说明）
  void _showAiPlaceholder(BuildContext context, String title) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: Theme.of(ctx).textTheme.titleLarge),
              const SizedBox(height: 12),
              Text(
                'AI 服务未配置：按钮占位已就绪，服务后端独立立项后接通。',
                style: Theme.of(ctx).textTheme.bodyMedium?.copyWith(
                  color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ── 分区 4：亮度行（对标 ll_brightness，自旧底栏面板迁移）──
  Widget _buildBrightnessRow(BuildContext context, Color? foreground) {
    if (!_brightnessSupported || !widget.showBrightnessView) {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(
        children: [
          IconButton(
            icon: Icon(
              _autoBrightness
                  ? Icons.brightness_auto
                  : Icons.brightness_auto_outlined,
            ),
            tooltip: _autoBrightness ? '关闭自动亮度' : '自动亮度',
            onPressed: () async {
              await SystemBrightness.setAutoBrightness(!_autoBrightness);
              await _loadBrightness();
            },
          ),
          Expanded(
            child: Slider(
              value: _brightness,
              onChanged: _autoBrightness
                  ? null
                  : (v) {
                      setState(() => _brightness = v);
                      unawaited(SystemBrightness.setBrightness(v));
                    },
            ),
          ),
        ],
      ),
    );
  }

  // ── 分区 5：进度滑条行（page=调章内页 / chapter=调章节）──
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
    // [UI_SYNC_REFACTOR S6 修 | 2026-09-08] 滑条行对齐参考版（用户反馈③）：
    // ①两端为圆形箭头钮（章节上/下调整语义，禁用态变浅）；
    // ②滑条用 M3 手柄样式（圆角矩钮）+ divisions 点刻轨（参考版分段点刻轨道）
    //   ——此前左右尖角箭头易被读作翻页，改为圆形按钮并统一视觉 — Qoder
    final cs = Theme.of(context).colorScheme;
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
    // [UI_SYNC_REFACTOR S6 修 | 2026-09-08] 圆形章节钮去掉水波纹/按压高亮
    //（用户反馈②：圆形箭头内阴影 → 即 IconButton 默认 ink/overlay）— Qoder
    Widget navButton(IconData icon, String tip, VoidCallback? onTap) {
      final enabled = onTap != null;
      final color = enabled
          ? (foreground ?? cs.onSurface)
          : (foreground ?? cs.onSurface).withValues(alpha: 0.35);
      return Material(
        color: cs.surfaceContainerHighest.withValues(alpha: 0.6),
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          splashFactory: NoSplash.splashFactory,
          highlightColor: Colors.transparent,
          hoverColor: Colors.transparent,
          onTap: onTap,
          child: SizedBox(
            width: 40,
            height: 40,
            child: Icon(icon, size: 20, color: color),
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(
        children: [
          navButton(
            Icons.chevron_left_rounded,
            AppStrings.previousChapter,
            state.hasPreviousChapter ? () => notifier.prevChapter() : null,
          ),
          Expanded(
            child: SliderTheme(
              data: sliderTheme,
              child: usePageSeek
                  ? Slider(
                      value: currentPage.toDouble(),
                      min: 0,
                      max: (chapterPageCount - 1).toDouble(),
                      divisions: chapterPageCount - 1,
                      label: '${currentPage + 1}/$chapterPageCount',
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
                      onChanged: (value) => notifier.goToChapter(value.toInt()),
                    ),
            ),
          ),
          navButton(
            Icons.chevron_right_rounded,
            AppStrings.nextChapter,
            state.hasNextChapter ? () => notifier.nextChapter() : null,
          ),
        ],
      ),
    );
  }
}
