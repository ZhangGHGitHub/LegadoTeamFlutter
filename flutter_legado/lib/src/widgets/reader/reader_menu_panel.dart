import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;

import '../../models/models.dart';
import '../../providers/reader/reader_notifier.dart';
import '../../providers/theme/theme_notifier.dart';
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
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(readerNotifierProvider);
    final notifier = ref.read(readerNotifierProvider.notifier);
    final book = state.currentBook;
    final chapter = (state.chapters.isNotEmpty &&
            state.currentChapterIndex < state.chapters.length)
        ? state.chapters[state.currentChapterIndex]
        : null;
    final cs = Theme.of(context).colorScheme;
    final followColor = widget.styleFollowPage ? state.backgroundColor : null;
    final foreground = widget.styleFollowPage ? state.textColor : null;
    final adv = ref.watch(readerAdvConfigProvider);
    final autoPageActive = adv?.autoPageTurn ?? false;
    final barColor = followColor ?? cs.surface;

    return Positioned(
      bottom: 0,
      left: 0,
      right: 0,
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
          final scale = Tween<double>(begin: 0.88, end: 1.0).animate(
            CurvedAnimation(
                parent: _menuController, curve: Curves.fastOutSlowIn),
          );
          return IgnorePointer(
            ignoring: !widget.visible,
            child: FadeTransition(
              opacity: fade,
              child: ScaleTransition(
                scale: scale,
                alignment: Alignment.bottomCenter,
                child: child!,
              ),
            ),
          );
        },
        child: Material(
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
                  _buildTitleRow(context, book, chapter, foreground),
                  _buildIconRow(context, foreground, autoPageActive),
                  _buildSearchRow(context, foreground),
                  _buildBrightnessRow(context, foreground),
                  _buildProgressRow(context, notifier, state, foreground),
                  _buildToolRow(context, foreground),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  // ── 分区 1：标题胶囊行 ──
  Widget _buildTitleRow(BuildContext context, Book? book,
      BookChapter? chapter, Color? foreground) {
    final cs = Theme.of(context).colorScheme;
    return SizedBox(
      height: 48,
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Symbols.arrow_back_rounded),
            tooltip: '退出阅读',
            onPressed: widget.onBack,
          ),
          Expanded(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              decoration: BoxDecoration(
                color: cs.surfaceContainerHighest.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(
                book?.name ?? '',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context)
                    .textTheme
                    .titleMedium
                    ?.copyWith(color: foreground),
              ),
            ),
          ),
          // 章节名（点击进目录）
          Flexible(
            child: GestureDetector(
              onTap: widget.onOpenCatalog,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Text(
                  chapter?.title ?? '',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.right,
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(
                        color:
                            foreground ?? cs.onSurfaceVariant,
                      ),
                ),
              ),
            ),
          ),
          // More 溢出（高频项子集；长尾项 S2-2 迁移）
          PopupMenuButton<String>(
            tooltip: '更多',
            position: PopupMenuPosition.under,
            onSelected: (value) {
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
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'addBookmark', child: Text('添加书签')),
              PopupMenuItem(value: 'highlightRule', child: Text('高亮规则')),
              PopupMenuItem(value: 'replace', child: Text('替换规则')),
              PopupMenuItem(value: 'toc', child: Text('查看目录')),
              PopupMenuItem(value: 'settings', child: Text('界面设置')),
            ],
          ),
        ],
      ),
    );
  }

  // ── 分区 2：FloatingIconRow（高频 8 位）──
  Widget _buildIconRow(BuildContext context, Color? foreground,
      bool autoPageActive) {
    final cs = Theme.of(context).colorScheme;
    IconData autoIcon() =>
        autoPageActive ? Icons.pause : Icons.auto_stories_outlined;
    final items = <(IconData, String, VoidCallback)>[
      (Symbols.bookmark_add_rounded, '添加书签', widget.onAddBookmark),
      (Symbols.auto_stories_rounded, '目录', widget.onOpenCatalog),
      (Symbols.sunny_rounded, '日/夜切换', () {
        final isNight = Theme.of(context).brightness == Brightness.dark;
        unawaited(ref
            .read(themeNotifierProvider.notifier)
            .toggleDayNight(isNight: isNight));
        ref
            .read(readerNotifierProvider.notifier)
            .updateBackgroundColor(
              isNight ? ReaderBackground.white : ReaderBackground.dark,
            );
      }),
      (autoIcon(), autoPageActive ? '停止自动翻页' : '自动翻页',
          widget.onToggleAutoPage),
      (Symbols.find_replace_rounded, '替换规则', widget.onOpenReplaceRules),
      (Symbols.settings_rounded, '界面设置', widget.onOpenSettings),
      (Symbols.tune_rounded, '更多设置', widget.onOpenAdvancedConfig),
      (Symbols.headphones_rounded, '朗读', widget.onReadAloud),
    ];
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          for (final (icon, tip, onTap) in items)
            IconButton(
              icon: Icon(icon,
                  size: 22,
                  color: autoPageActive && tip == '自动翻页'
                      ? cs.primary
                      : foreground),
              tooltip: tip,
              onPressed: onTap,
            ),
        ],
      ),
    );
  }

  // ── 分区 3：搜索 pill 行 ──
  Widget _buildSearchRow(BuildContext context, Color? foreground) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
      child: Row(
        children: [
          // [UI_SYNC_REFACTOR S2] 搜索 pill（40dp r16，对齐 SearchPillSurface）
          Material(
            color: cs.surfaceContainerHighest.withValues(alpha: 0.6),
            borderRadius: BorderRadius.circular(16),
            child: InkWell(
              borderRadius: BorderRadius.circular(16),
              onTap: widget.onOpenContentSearch,
              child: Container(
                height: 40,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.search,
                        size: 16, color: cs.onSurfaceVariant),
                    const SizedBox(width: 6),
                    Text(
                      '全文搜索',
                      style: Theme.of(context).textTheme.labelLarge?.copyWith(
                            color: cs.onSurfaceVariant,
                          ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const Spacer(),
        ],
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
            icon: Icon(_autoBrightness
                ? Icons.brightness_auto
                : Icons.brightness_auto_outlined),
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
      BuildContext context, ReaderNotifier notifier, ReaderState state,
      Color? foreground) {
    final chapterPageCount =
        notifier.paginator.pageCountForChapter(state.currentChapterIndex);
    final usePageSeek = widget.progressBehavior == 'page' &&
        chapterPageCount > 1 &&
        widget.onSeekPage != null;
    final currentPage =
        state.currentChapterPos.clamp(0, chapterPageCount > 0 ? chapterPageCount - 1 : 0);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          TextButton(
            onPressed: state.hasPreviousChapter
                ? () => notifier.prevChapter()
                : null,
            child: Text(AppStrings.previousChapter),
          ),
          Expanded(
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
          TextButton(
            onPressed:
                state.hasNextChapter ? () => notifier.nextChapter() : null,
            child: Text(AppStrings.nextChapter),
          ),
        ],
      ),
    );
  }

  // ── 分区 6：工具行 ──
  Widget _buildToolRow(BuildContext context, Color? foreground) {
    Widget action(IconData icon, String label, VoidCallback onTap) {
      return Expanded(
        child: TextButton.icon(
          onPressed: onTap,
          icon: Icon(icon, size: 20),
          label: Text(
            label,
            style: Theme.of(context).textTheme.labelMedium,
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
      child: Row(
        children: [
          action(Symbols.format_list_bulleted_rounded, '目录',
              widget.onOpenCatalog),
          action(Symbols.headphones_rounded, '朗读', widget.onReadAloud),
          action(Symbols.style_rounded, '界面', widget.onOpenSettings),
          action(Symbols.tune_rounded, '更多', widget.onOpenAdvancedConfig),
        ],
      ),
    );
  }
}
