import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

/// [P4-3 M1] 漫画阅读器菜单组件（顶栏胶囊 / 两行悬浮底栏）
///
/// 取证（参考版 legado-with-MD3 MangaReaderOverlays.kt）：
/// - L95-111 配色槽位：MangaMenuSurfaceColor = surfaceContainerHigh（底栏
///   悬浮面）、MangaMenuButtonColor = surfaceContainerLow（胶囊/圆钮）、
///   tint = onSurfaceVariant、边框 = outlineVariant；
///   本实现按任务要求「主题化、非恒黑」：胶囊 = surfaceContainerLow、
///   底栏 = surfaceContainerHigh（75% 不透明度）、文字/图标 =
///   onSurfaceVariant、边框 = outlineVariant —— 亮色主题出浅色胶囊、
///   暗色主题自动出深色胶囊。
/// - L208-257 MangaMenuTopBar：顶栏**始终透明无表面背景**，只显示
///   悬浮胶囊（safeDrawing 顶边距 + 水平 16 / 垂直 4 padding，Row
///   spacedBy 16：返回圆钮 + 标题胶囊 weight1 + 合并操作胶囊）；
/// - L259-317 MangaTitleCapsule：高 40、stadium（RoundedCornerShape(50)）、
///   背景 surfaceContainerLow、水平 padding 12、双行 Column（书名
///   labelMediumEmphasized + 章名 labelSmall alpha 0.7，均
///   onSurfaceVariant 单行省略号）；
/// - L328-425 MangaMenuMergedActions：stadium 胶囊 Row 合并 40dp 点击区 /
///   20dp 图标按钮（参考版 换源|刷新|更多；本方 换源/更多 待 E8 源操作
///   面板，本波只放「刷新」键，不放假按钮）；
/// - L424-649 MangaMenuBottomBar（悬浮形态）：RoundedCornerShape(32) +
///   navigationBarsPadding + margin 水平/垂直 16、面 = surfaceContainerHigh、
///   1dp outlineVariant 描边；内 Column v-padding 16：
///   Row1 spacedBy 8（上一章 + 页进度滑条 weight1 + 下一章，h-padding 16），
///   Spacer 12，Row2 SpaceBetween（目录 | 自动阅读 | 翻页设置，h-padding 16）；
/// - L678-742 MangaMenuIconButton：40dp 圆钮（非玻璃态 = clip(CircleShape)
///   + 背景 surfaceContainerLow）、20dp 图标、contentDescription 语义；
///   Row2 的 ReaderMenuAction（ReaderMenuPrimitives L99-106）= 图标按钮
///   列表（图标 + 语义描述，无可见文字标签）。
///
/// 底栏按键语义（参考版 L596-636 + MangaReaderViewModel L244-253）：
/// - 上一章/下一章：PreviousChapter/NextChapter（边界由屏幕层守卫）；
/// - 滑条：value = 0 基页索引、范围 0..(pageCount-1).coerceAtLeast(1)、
///   steps = (pageCount-2).coerceAtLeast(0)、pageCount > 1 才可拖
///   （SeekToPage(it.toInt())）；
/// - 目录：OpenCatalog（弹目录 bottom sheet，见 manga_catalog_sheet.dart）；
/// - 自动：ToggleAutoRead（描述 = 停止/自动 随开关态，长按 =
///   OpenSettings(AUTO_READ)）；翻页设置：OpenSettings(READER)；
/// - 离线缓存键（参考版仅 cacheAvailable 时渲染）：我方无漫画离线缓存
///   功能，不放此键。

/// 40×40 圆形胶囊图标按钮（对齐参考版 MangaMenuIconButton L678-742）
///
/// 图标 20dp、tint onSurfaceVariant、背景 surfaceContainerLow 圆形；
/// [tooltip] 同时作为语义标签（对齐参考版 contentDescription）。
class MangaMenuIconButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback? onTap;
  final GestureLongPressCallback? onLongPress;

  const MangaMenuIconButton({
    super.key,
    required this.icon,
    required this.tooltip,
    this.onTap,
    this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      button: true,
      label: tooltip,
      child: Tooltip(
        message: tooltip,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          onLongPress: onLongPress,
          child: Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: scheme.surfaceContainerLow,
              shape: BoxShape.circle,
            ),
            child: Center(
              child: Icon(icon, size: 20, color: scheme.onSurfaceVariant),
            ),
          ),
        ),
      ),
    );
  }
}

/// 标题胶囊（对齐参考版 MangaTitleCapsule L259-317）
///
/// 高 40 stadium、背景 surfaceContainerLow、双行（书名 + 章名）单行省略号；
/// 内容块水平左置、垂直居中（参考版 Box `contentAlignment =
/// Alignment.CenterStart`），双行左对齐（[Column]
/// `crossAxisAlignment.start`，两行左缘对齐，窄行不居中漂移）；
/// [onTap] 为空时不可点击（参考版点击 = OpenBookInfo，本方无书籍信息面板
/// 入口，本波保持纯展示，见汇报「未做」项）。
class MangaTitleCapsule extends StatelessWidget {
  final String bookName;
  final String? chapterName;
  final VoidCallback? onTap;

  const MangaTitleCapsule({
    super.key,
    required this.bookName,
    this.chapterName,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        height: 40,
        decoration: BoxDecoration(
          color: scheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          // 参考版 Box contentAlignment = Alignment.CenterStart：
          // 内容块水平左置（start）、垂直居中；双行再互相左对齐，
          // 避免窄行（章名）在宽行（书名）下居中漂移造成两行错位
          child: Align(
            alignment: Alignment.centerLeft,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 书名（参考版 labelMediumEmphasized：14sp 强调体）
                Text(
                  bookName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                // 章名（参考版 labelSmall alpha 0.7；空白不渲染第二行）
                if ((chapterName?.trim().isEmpty ?? true) == false)
                  Text(
                    chapterName!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11,
                      color: scheme.onSurfaceVariant.withValues(alpha: 0.7),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 顶栏（对齐参考版 MangaMenuTopBar L208-257）
///
/// 透明悬浮：返回圆钮 + 标题胶囊（weight 1）+ 合并操作胶囊（本波仅
/// 「刷新」键；换源/更多待 E8 源操作面板）。
class MangaMenuTopBar extends StatelessWidget {
  final String bookName;
  final String? chapterName;
  final VoidCallback onBack;
  final VoidCallback onRefresh;
  final VoidCallback? onOpenBookInfo;

  const MangaMenuTopBar({
    super.key,
    required this.bookName,
    this.chapterName,
    required this.onBack,
    required this.onRefresh,
    this.onOpenBookInfo,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SafeArea(
      bottom: false,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        child: Row(
          children: [
            MangaMenuIconButton(
              icon: Symbols.arrow_back_rounded,
              tooltip: '返回',
              onTap: onBack,
            ),
            const SizedBox(width: 16),
            Expanded(
              child: MangaTitleCapsule(
                bookName: bookName,
                chapterName: chapterName,
                // 参考版标题胶囊点击 = OpenBookInfo；本方无该面板入口时
                // 回退为返回（保持可点语义，不造新功能）
                onTap: onOpenBookInfo ?? onBack,
              ),
            ),
            const SizedBox(width: 16),
            // 合并操作胶囊（参考版 换源|刷新|更多；本波仅刷新，
            // 换源/更多键待 E8 源操作面板，不放假按钮）
            Container(
              height: 40,
              decoration: BoxDecoration(
                color: scheme.surfaceContainerLow,
                borderRadius: BorderRadius.circular(20),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  MangaMenuIconButton(
                    icon: Symbols.refresh_rounded,
                    tooltip: '刷新',
                    onTap: onRefresh,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 底栏（对齐参考版 MangaMenuBottomBar 悬浮形态 L424-649）
///
/// 悬浮圆角面板（radius 32 + margin 16 + 导航栏内边距）：
/// - Row1：上一章 / 页进度滑条（weight 1）/ 下一章（spacedBy 8）；
/// - Row2：目录 / 自动（停止） / 翻页设置（SpaceBetween 均布）。
class MangaMenuBottomBar extends StatelessWidget {
  /// 上一章（屏幕层守卫：无上一章时 no-op）
  final VoidCallback onPrevChapter;

  /// 下一章（屏幕层守卫：无下一章时 no-op）
  final VoidCallback onNextChapter;

  /// 滑条当前值（0 基逻辑页索引；对齐参考版 value = currentPage）
  final double pageValue;

  /// 滑条最大值（(pageCount-1).coerceAtLeast(1)，对齐参考版 valueRange）
  final double pageMax;

  /// 滑条分段数（pageCount > 1 时 = pageCount-1；null = 连续）
  final int? divisions;

  /// 滑条是否可拖（pageCount > 1，对齐参考版 enabled）
  final bool pageEnabled;

  /// 滑条无障碍描述（参考版 readingPageDescription，如「页数 2/3」）
  final String readingPageDescription;

  /// 滑条拖动 → 跳页（参考版 SeekToPage(it.toInt())）
  final void Function(int page) onSeekPage;

  /// 目录键（参考版 OpenCatalog）
  final VoidCallback onOpenCatalog;

  /// 自动阅读开关态（决定键描述 停止/自动，对齐参考版 L606-610）
  final bool autoReadEnabled;

  /// 自动键点击（参考版 ToggleAutoRead）
  final VoidCallback onToggleAutoRead;

  /// 自动键长按（参考版 OpenSettings(AUTO_READ)）
  final VoidCallback onOpenAutoSettings;

  /// 翻页设置键（参考版 OpenSettings(READER)）
  final VoidCallback onOpenPageSettings;

  const MangaMenuBottomBar({
    super.key,
    required this.onPrevChapter,
    required this.onNextChapter,
    required this.pageValue,
    required this.pageMax,
    required this.divisions,
    required this.pageEnabled,
    required this.readingPageDescription,
    required this.onSeekPage,
    required this.onOpenCatalog,
    required this.autoReadEnabled,
    required this.onToggleAutoRead,
    required this.onOpenAutoSettings,
    required this.onOpenPageSettings,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SafeArea(
      top: false,
      child: Container(
        // 参考版 floating：navigationBarsPadding + padding(16, 16)
        margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        decoration: BoxDecoration(
          // 任务要求：底栏 = surfaceContainerHigh（75% 不透明度）+ 1dp 描边
          color: scheme.surfaceContainerHigh.withValues(alpha: 0.75),
          borderRadius: BorderRadius.circular(32),
          border: Border.all(color: scheme.outlineVariant, width: 1),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 16),
              child: Padding(
                // Row1：上一章 / 滑条 / 下一章（h-padding 16，spacedBy 8）
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  children: [
                    MangaMenuIconButton(
                      icon: Symbols.arrow_back_rounded,
                      tooltip: '上一章',
                      onTap: onPrevChapter,
                    ),
                    const SizedBox(width: 8),
                    // 页进度滑条（参考版 ReadMenuSlider → AppSlider 视觉：
                    // 小 thumb + 细轨道 + 均匀分段点，无数值气泡）。
                    // 本 SDK MD3 默认滑条 = 20px 大 thumb / 4px 轨道 /
                    // onlyForDiscrete 数值气泡，局部 SliderTheme 包裹对齐
                    // （只影响本底栏滑条，不动应用级滑条主题）
                    Expanded(
                      child: SliderTheme(
                        data: SliderThemeData(
                          trackHeight: 2,
                          thumbShape: const RoundSliderThumbShape(
                            enabledThumbRadius: 6,
                            disabledThumbRadius: 6,
                          ),
                          overlayShape: const RoundSliderOverlayShape(
                            overlayRadius: 14,
                          ),
                          tickMarkShape: const RoundSliderTickMarkShape(
                            tickMarkRadius: 2,
                          ),
                          thumbColor: scheme.onSurfaceVariant,
                          disabledThumbColor: scheme.onSurfaceVariant
                              .withValues(alpha: 0.38),
                          overlayColor:
                              scheme.onSurfaceVariant.withValues(alpha: 0.12),
                          // 分段点配色（浅/暗主题均可见）：active 轨道
                          // （onSurfaceVariant 色）上放 outlineVariant 点、
                          // inactive 轨道（outlineVariant 色）上放
                          // onSurfaceVariant 点
                          activeTickMarkColor: scheme.outlineVariant,
                          inactiveTickMarkColor: scheme.onSurfaceVariant,
                        ),
                        child: Slider(
                          value: pageValue.clamp(0.0, pageMax),
                          min: 0,
                          max: pageMax,
                          divisions: divisions,
                          activeColor: scheme.onSurfaceVariant,
                          inactiveColor: scheme.outlineVariant,
                          onChanged:
                              pageEnabled ? (v) => onSeekPage(v.round()) : null,
                          // 无障碍描述（对齐参考版 readingPageDescription；
                          // 本 SDK Slider 用 semanticFormatterCallback 承载）
                          semanticFormatterCallback: (_) =>
                              readingPageDescription,
                          // 参考版 Compose/Miuix 滑条无数值气泡；本 SDK 默认
                          // onlyForDiscrete 会常显页码气泡，显式关闭
                          showValueIndicator: ShowValueIndicator.never,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    MangaMenuIconButton(
                      icon: Symbols.arrow_forward_rounded,
                      tooltip: '下一章',
                      onTap: onNextChapter,
                    ),
                  ],
                ),
              ),
            ),
            // Spacer 12（参考版 L600 Spacer(Modifier.height(12.dp))）
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
              child: Row(
                // Row2：目录 / 自动（停止）/ 翻页设置（SpaceBetween 均布）
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  MangaMenuIconButton(
                    icon: Symbols.list_rounded,
                    tooltip: '目录',
                    onTap: onOpenCatalog,
                  ),
                  MangaMenuIconButton(
                    icon: Symbols.auto_mode_rounded,
                    // 参考版 L606-610：开 = 「停止」，关 = 「自动」
                    tooltip: autoReadEnabled ? '停止' : '自动',
                    onTap: onToggleAutoRead,
                    onLongPress: onOpenAutoSettings,
                  ),
                  MangaMenuIconButton(
                    icon: Symbols.tune_rounded,
                    tooltip: '翻页设置',
                    onTap: onOpenPageSettings,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }
}
