import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;

import '../../l10n/app_strings.dart';
import '../../providers/audio/audio_notifier.dart';
import '../../providers/reader/reader_notifier.dart';
import '../../services/system_brightness.dart';

/// 阅读器底部工具栏
///
/// 对齐安卓原版 ReadMenu 底部栏（view_read_menu.xml）：
/// 悬浮按钮行（搜索/夜间，对标 ll_floating_button）
/// + 亮度行（自动亮度+亮度滑条）+ 上一章/章节进度条/下一章
/// + 目录/朗读/界面/设置四功能按钮
/// [UI-fix v2.0.4 | 2026-08-08] 源操作行移除（原版底栏无此行，源操作
/// 已迁至顶栏源名称徽章，对标 tv_source_action）；搜索/夜间自顶栏迁入
/// 悬浮按钮行（对标 fabSearch/fabNightTheme） — Qoder
class ReaderBottomBar extends ConsumerStatefulWidget {
  final VoidCallback onOpenCatalog;
  final VoidCallback onOpenSettings;
  final VoidCallback onOpenAdvancedConfig;

  /// 全文搜索回调（对标原版 fabSearch 悬浮按钮）
  final VoidCallback onOpenContentSearch;

  /// 朗读按钮回调（启动/切换朗读，由 ReaderScreen 接线到 AudioNotifier）
  final VoidCallback onReadAloud;

  // [UI-fix v2.0.3 | 2026-08-08] MoreConfig 第①批消费点 — Qoder

  /// 亮度控件显隐（对标原版 showBrightnessView）
  final bool showBrightnessView;

  /// 进度条行为（'page'=调章内页 'chapter'=调章节，对标原版 progressBarBehavior）
  final String progressBehavior;

  /// 调章内页回调（progressBehavior='page' 时滑条拖动驱动 ReaderPageView 跳页）
  final ValueChanged<int>? onSeekPage;

  /// 工具栏样式跟随阅读页（对标原版 readBarStyleFollowPage/immersiveMenu）
  final bool styleFollowPage;

  const ReaderBottomBar({
    super.key,
    required this.onOpenCatalog,
    required this.onOpenSettings,
    required this.onOpenAdvancedConfig,
    required this.onOpenContentSearch,
    required this.onReadAloud,
    this.showBrightnessView = true,
    this.progressBehavior = 'chapter',
    this.onSeekPage,
    this.styleFollowPage = false,
  });

  @override
  ConsumerState<ReaderBottomBar> createState() => _ReaderBottomBarState();
}

class _ReaderBottomBarState extends ConsumerState<ReaderBottomBar> {
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
      if (!supported) return;
      final isAuto = await SystemBrightness.isAutoBrightness();
      final value = await SystemBrightness.getBrightness();
      if (!mounted) return;
      setState(() {
        _brightnessSupported = true;
        _autoBrightness = isAuto;
        _brightness = value;
      });
    } catch (e) {
      // [审计修复 §4.1] 平台通道不可用时（如测试环境）静默降级隐藏亮度行，
      // debugPrint 留痕便于排障 — Qoder
      debugPrint('亮度通道不可用，隐藏亮度行: $e');
    }
  }

  // [UI-fix v2.0.4 | 2026-08-08] 源操作菜单（_showSourceMenu/_chapterPay）
  // 已整体迁移至顶栏 ReaderTopBar 源名称徽章（对标原版 tv_source_action
  // 点击弹 sourceMenu），功能无丢失 — Qoder

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(readerNotifierProvider);
    final notifier = ref.read(readerNotifierProvider.notifier);
    // [UI-fix v2.0.1 | 2026-08-06] 朗读按钮激活：当前书朗读进行中时
    // 按钮切换为实心图标高亮 — Qoder
    final audio = ref.watch(audioNotifierProvider);
    final book = state.currentBook;
    final aloudActive = book != null &&
        audio.bookUrl == book.bookUrl &&
        audio.state != PlayerState.idle;

    // [UI-fix v2.0.3 | 2026-08-08] 进度条行为=调章内页时的章内分页信息
    // （页数来自跨章分页器，当前页=state.currentChapterPos）；未注册或
    // 单页时回退调章节滑条，不阻断 — Qoder
    final chapterPageCount =
        notifier.paginator.pageCountForChapter(state.currentChapterIndex);
    final usePageSeek = widget.progressBehavior == 'page' &&
        chapterPageCount > 1 &&
        widget.onSeekPage != null;
    final currentPage = state.currentChapterPos.clamp(
      0,
      chapterPageCount > 0 ? chapterPageCount - 1 : 0,
    );

    // [UI-fix v2.0.3 | 2026-08-08] 工具栏跟随页面：背景/前景色跟随阅读页
    // （对标原版 ReadMenu immersiveMenu）— Qoder
    final followColor = widget.styleFollowPage ? state.backgroundColor : null;
    final foreground = widget.styleFollowPage ? state.textColor : null;

    final bar = Positioned(
      bottom: 0,
      left: 0,
      right: 0,
      // [UI-fix v2.0.4 | 2026-08-08] 悬浮按钮行（对标原版 ll_floating_button：
      // fabSearch 居左 / fabNightTheme 居右；原版另有 fabAutoPage/fabReplaceRule，
      // Flutter 侧暂无自动翻页功能且替换规则入口在溢出菜单，不新增） — Qoder
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                FloatingActionButton(
                  mini: true,
                  heroTag: null,
                  tooltip: '全文搜索',
                  onPressed: widget.onOpenContentSearch,
                  child: const Icon(Icons.search),
                ),
                FloatingActionButton(
                  mini: true,
                  heroTag: null,
                  tooltip: state.isDarkBackground ? '日间模式' : '夜间模式',
                  onPressed: () => notifier.updateBackgroundColor(
                    state.isDarkBackground
                        ? ReaderBackground.white
                        : ReaderBackground.dark,
                  ),
                  child: Icon(
                    state.isDarkBackground
                        ? Icons.light_mode
                        : Icons.dark_mode,
                  ),
                ),
              ],
            ),
          ),
          Material(
        color: followColor ?? Theme.of(context).colorScheme.surface,
        // iOS 风格：无阴影 + hairline 顶边
        elevation: 0,
        shape: Border(
          top: BorderSide(
            color: widget.styleFollowPage
                ? state.textColor.withValues(alpha: 0.2)
                : (Theme.of(context).dividerTheme.color ??
                    Theme.of(context).dividerColor),
            width: 0.0,
          ),
        ),
        child: SafeArea(
          top: false,
          child: IconTheme(
            data: IconThemeData(color: foreground),
            child: TextButtonTheme(
              // 跟随页面时上/下一章按钮前景色改用页面文字色
              data: TextButtonThemeData(
                style: foreground == null
                    ? null
                    : TextButton.styleFrom(foregroundColor: foreground),
              ),
              child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 亮度行（对标 ll_brightness：自动亮度 + 亮度滑条）
              // [UI-fix v2.0.3 | 2026-08-08] showBrightnessView 关闭时隐藏 — Qoder
              if (_brightnessSupported && widget.showBrightnessView)
                Padding(
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
                          await SystemBrightness.setAutoBrightness(
                              !_autoBrightness);
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
                ),
              // 进度条（对标 tv_pre + seek_read_page + tv_next）
              // [UI-fix v2.0.3 | 2026-08-08] progressBarBehavior=page 时滑条
              // 调章内页（对标原版 UP_SEEK_BAR 后 seekReadPage 调页语义）— Qoder
              Padding(
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
                              onChanged: (value) =>
                                  widget.onSeekPage!(value.toInt()),
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
                              onChanged: (value) {
                                notifier.goToChapter(value.toInt());
                              },
                            ),
                    ),
                    TextButton(
                      onPressed: state.hasNextChapter
                          ? () => notifier.nextChapter()
                          : null,
                      child: Text(AppStrings.nextChapter),
                    ),
                  ],
                ),
              ),
              // 功能按钮（对标 ll_catalog/ll_read_aloud/ll_font/ll_setting）
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  _buildBottomAction(
                    context,
                    Icons.toc,
                    AppStrings.catalog,
                    widget.onOpenCatalog,
                    foreground: foreground,
                  ),
                  _buildBottomAction(
                    context,
                    // 对标 ll_read_aloud：启动朗读当前章（进行中时点击为播放/暂停切换）
                    aloudActive
                        ? Icons.record_voice_over
                        : Icons.record_voice_over_outlined,
                    AppStrings.readAloud,
                    widget.onReadAloud,
                    highlighted: aloudActive,
                    foreground: foreground,
                  ),
                  _buildBottomAction(
                    context,
                    Icons.palette_outlined,
                    AppStrings.interfaceSetting,
                    widget.onOpenSettings,
                    foreground: foreground,
                  ),
                  _buildBottomAction(
                    context,
                    Icons.settings,
                    AppStrings.settings,
                    // 对标 ll_setting：打开更多/高级设置面板
                    widget.onOpenAdvancedConfig,
                    foreground: foreground,
                  ),
                ],
              ),
              const SizedBox(height: 8),
            ],
              ),
            ),
          ),
        ),
          ),
        ],
      ),
    );
    return bar;
  }

  Widget _buildBottomAction(
    BuildContext context,
    IconData icon,
    String label,
    VoidCallback onTap, {
    bool highlighted = false,
    // [UI-fix v2.0.3 | 2026-08-08] 工具栏跟随页面时的前景色 — Qoder
    Color? foreground,
  }) {
    final highlightColor = Theme.of(context).colorScheme.primary;
    final baseColor = foreground;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 22,
              color: highlighted ? highlightColor : baseColor,
            ),
            const SizedBox(height: 2),
            Text(
              label,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: highlighted ? highlightColor : baseColor,
                  ),
            ),
          ],
        ),
      ),
    );
  }
}
