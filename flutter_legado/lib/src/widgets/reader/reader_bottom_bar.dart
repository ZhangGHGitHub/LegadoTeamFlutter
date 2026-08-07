import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;

import '../../l10n/app_strings.dart';
import '../../models/book.dart';
import '../../models/book_source.dart';
import '../../providers/audio/audio_notifier.dart';
import '../../providers/providers.dart';
import '../../providers/reader/reader_notifier.dart';
import '../../routes.dart';
import '../../screens/source_edit_screen.dart';
import '../../screens/source_login_screen.dart';
import '../../services/system_brightness.dart';

/// 阅读器底部工具栏
///
/// 对齐安卓原版 ReadMenu 底部栏（view_read_menu.xml）：
/// 亮度行（自动亮度+亮度滑条）+ 上一章/章节进度条/下一章
/// + 目录/朗读/界面/设置四功能按钮
class ReaderBottomBar extends ConsumerStatefulWidget {
  final VoidCallback onOpenCatalog;
  final VoidCallback onOpenSettings;
  final VoidCallback onOpenAdvancedConfig;

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

  // ===== [UI-fix v2.0.2 | 2026-08-06] 源操作菜单（对标原版 ReadMenu
  // sourceMenu：登录源/章节购买/编辑源/禁用源） — Qoder =====

  /// 显示源操作菜单（先查书源详情获取登录地址等）
  Future<void> _showSourceMenu(BuildContext context, Book book) async {
    final api = ref.read(bookApiProvider);
    final sourceUrl = book.origin;
    // 查找当前书籍对应书源（失败时仍提供编辑/禁用入口）
    BookSource? source;
    try {
      final sources = await api.getBookSources();
      for (final s in sources) {
        if (s.bookSourceUrl == sourceUrl) {
          source = s;
          break;
        }
      }
    } catch (_) {
      // 书源列表不可用时降级：登录项隐藏，其余入口保留
    }
    if (!context.mounted) return;

    final loginUrl = source?.loginUrl ?? '';
    final sourceName =
        (source?.bookSourceName ?? book.originName).trim();

    final action = await showMenu<String>(
      context: context,
      position: const RelativeRect.fromLTRB(0, 0, 16, 120),
      items: [
        if (loginUrl.isNotEmpty)
          const PopupMenuItem(value: 'login', child: Text('登录源')),
        // 本地书隐藏章节购买项（对标原版 isLocal 短路）— Qoder
        if (book.origin != BookType.localTag)
          const PopupMenuItem(value: 'chapterPay', child: Text('章节购买')),
        const PopupMenuItem(value: 'editSource', child: Text('编辑源')),
        const PopupMenuItem(value: 'disableSource', child: Text('禁用源')),
      ],
    );
    if (action == null || !context.mounted) return;

    switch (action) {
      case 'login':
        // 对标原版 menu_login → 登录 V2 页面
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => SourceLoginScreen(
              sourceUrl: sourceUrl,
              sourceName: sourceName,
              loginUrl: loginUrl,
            ),
          ),
        );
      case 'chapterPay':
        // [UI-fix v2.0.3 | 2026-08-08] 章节购买接线（契约 §2.43.2），
        // 移除原 TODO 占位 — Qoder
        await _chapterPay(context, book);
      case 'editSource':
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => SourceEditScreen(sourceUrl: sourceUrl),
          ),
        );
      case 'disableSource':
        try {
          await api.disableBookSource(sourceUrl);
          if (context.mounted) {
            _snack(context, '已禁用书源：$sourceName');
          }
        } catch (e) {
          if (context.mounted) _snack(context, '禁用书源失败: $e');
        }
    }
  }

  void _snack(BuildContext context, String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  // [UI-fix v2.0.3 | 2026-08-08] 章节购买（契约 §2.43.2，对照 Kotlin
  // ReadBookActivity.payAction 的 onSuccess 三分支）：
  // url → 内置浏览器打开购买页；success → 提示购买成功并重载当前章
  // （Rust 侧已清章节缓存）；none → 提示无需购买；异常 → 错误提示 — Qoder
  Future<void> _chapterPay(BuildContext context, Book book) async {
    final api = ref.read(bookApiProvider);
    final chapterIndex =
        ref.read(readerNotifierProvider).currentChapterIndex;
    _snack(context, '正在执行章节购买…');
    try {
      final result = await api.chapterPayAction(
        bookUrl: book.bookUrl,
        chapterIndex: chapterIndex,
      );
      if (!context.mounted) return;
      switch (result.kind) {
        case 'url':
          // 购买页地址：内置浏览器打开（对标原版 WebViewActivity，
          // 标题为 chapter_pay 字符串）
          Navigator.of(context).pushNamed(
            AppRoutes.browser,
            arguments: <String, String>{
              'url': result.value,
              'title': '章节购买',
            },
          );
        case 'success':
          // 购买成功：重载当前章正文（参考编辑保存后的重载路径）；
          // 重载失败不影响购买结果提示
          try {
            await ref
                .read(readerNotifierProvider.notifier)
                .reloadChapterContent();
          } catch (e) {
            debugPrint('购买成功后重载章节失败: $e');
          }
          if (context.mounted) _snack(context, '购买成功');
        default:
          // kind=none：本地书短路/书源未配置 payAction/不支持
          _snack(context, '当前章节无需购买或书源未配置购买动作');
      }
    } catch (e) {
      // 对标原版 onError：执行购买操作出错
      if (context.mounted) _snack(context, '章节购买失败: $e');
    }
  }

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
      child: Material(
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
              // [UI-fix v2.0.2 | 2026-08-06] 源操作行（对标原版
              // tvSourceAction：本地书隐藏） — Qoder
              if (book != null && book.origin != BookType.localTag)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Row(
                    children: [
                      Icon(
                        Icons.link,
                        size: 16,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          (book.originName.isNotEmpty
                                  ? book.originName
                                  : '书籍来源')
                              ,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ),
                      TextButton(
                        onPressed: () => _showSourceMenu(context, book),
                        child: const Text('源菜单'),
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
