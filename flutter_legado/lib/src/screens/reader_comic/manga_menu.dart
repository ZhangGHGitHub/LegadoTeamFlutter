import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

/// [P4-3 M2] 漫画阅读器菜单组件（实心顶栏 / 悬浮进度行 + 贴底白条三键行）
///
/// **本批视觉基准 = 用户截图描述**（参考版 APK kazusa 3.26.15 漫画菜单）。
/// 本地参考源码快照（legado-with-MD3 MangaReaderOverlays.kt）滞后于用户 APK
/// —— 本地 grep 证实无 Miuix 漫画菜单 / 无 SkipPrevious 图标，故本批仅取
/// 语义与颜色角色依据（页脚 MangaFooter L108-152、Slider 分段 SeekToPage、
/// 键 intent、surface 色角色），形态以截图为准：
///
/// - 顶栏 [MangaMenuTopBar]：实心表面色（colorScheme.surfaceContainer，
///   浅色 = 浅灰 / 暗色自动暗）占满宽度，SafeArea 含状态栏区；
///   Row1 = 返回（图标无底、onSurface）+ Spacer + 右上图标组
///   （刷新 + 更多 more_vert 三点，onSurface、无胶囊底、间距均布——
///   参考版「换源」键我方无功能不放，E8 登记；「更多」= 打开页操作
///   底栏，复用既有页操作菜单）；Row2 标题区（左对齐 padding 16）=
///   书名大字（24sp w600 onSurface）+ 次行 Row（章节名 14sp
///   onSurfaceVariant 省略号 + Spacer + 源名 13sp onSurfaceVariant，
///   源名为 null/空不显示）；点击标题区 = 返回详情页（保留 M1 语义）。
/// - 底栏 [MangaMenuBottomBar]：两段分离（进度行悬浮于图上、白条贴底，
///   非 M1 一体化圆角面板）：
///   - 进度行：左右独立圆形白钮（surface 底 + 浮起阴影、直径 56；
///     图标 Symbols.skip_previous / skip_next，替换 M1 arrow 图标）+
///     中间白色胶囊（stadium 全圆角、surface、占余宽）内放 Slider——
///     thumb 自绘竖条（4.5dp 宽 × 胶囊高 60% 圆角竖条，primary 色，
///     参考版为深蓝竖条）、轨道透明、divisions 点串 primary 色
///     （参考版整串均匀蓝点）；拖动语义不变（SeekToPage），
///     pageCount = 1 时禁用保持；
///   - 贴底白条：全宽（colorScheme.surface、SafeArea bottom）三键均布：
///     目录（list，保留）/ 自动翻页（auto_mode，新增状态着色：开启
///     图标 primary 蓝、关闭 onSurface）/ 设置（settings 齿轮，
///     替换 M1 tune 图标，点击仍 = OpenSettings(READER) 翻页设置）。
///
/// 按键语义（M1 保留，对齐参考版 intent + MangaReaderViewModel L244-253）：
/// - 上一章/下一章：PreviousChapter/NextChapter（边界由屏幕层守卫）；
/// - 滑条：value = 0 基页索引、范围 0..(pageCount-1).coerceAtLeast(1)、
///   divisions = (pageCount-2)、pageCount > 1 才可拖（SeekToPage）；
/// - 目录：OpenCatalog（弹目录 bottom sheet，见 manga_catalog_sheet.dart）；
/// - 自动：ToggleAutoRead（描述 = 停止/自动 随开关态，长按 =
///   OpenSettings(AUTO_READ)）；翻页设置：OpenSettings(READER)；
/// - 离线缓存键（参考版仅 cacheAvailable 时渲染）：我方无漫画离线缓存
///   功能，不放此键。

/// 顶栏图标键（[P4-3 M2] 无底纯图标，onSurface，40dp 点击区）
///
/// 截图形态：实心顶栏内的图标键不带圆形/胶囊底，图标色 onSurface、
/// 无背景、间距均布；[tooltip] 同时作为语义标签。
class _MangaTopBarIcon extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback? onTap;

  const _MangaTopBarIcon({
    required this.icon,
    required this.tooltip,
    this.onTap,
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
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Icon(icon, size: 24, color: scheme.onSurface),
          ),
        ),
      ),
    );
  }
}

/// 顶栏（[P4-3 M2] 实心 AppBar 式，按用户截图重构）
///
/// 实心表面色（colorScheme.surfaceContainer，浅色 = 浅灰 / 暗色自动暗）
/// 占满宽度，SafeArea 含状态栏区：
/// - Row1：返回（无底图标）+ Spacer + 右上图标组（刷新 + 更多 more_vert
///   三点，无胶囊底、间距均布——参考版「换源」键我方无功能不放，
///   E8 登记；「更多」= 打开页操作底栏，复用既有页操作菜单）；
/// - Row2 标题区（左对齐，padding 16）：书名大字（24sp w600 onSurface）
///   + 次行 Row（章节名 14sp onSurfaceVariant 省略号 + Spacer + 源名
///   13sp onSurfaceVariant，源名 null/空不显示）；
/// - 点击标题区 = 返回详情页（保留 M1 语义：onOpenBookInfo ?? onBack）。
class MangaMenuTopBar extends StatelessWidget {
  final String bookName;
  final String? chapterName;

  /// [P4-3 M2] 源名（书源显示名；null/空 = 次行右端不显示，仅显章节名）
  final String? sourceName;

  final VoidCallback onBack;
  final VoidCallback onRefresh;

  /// [P4-3 M2] 「更多」键（打开页操作底栏，复用既有页操作菜单）
  final VoidCallback onMore;

  /// 标题区点击（缺省回退 [onBack] = 返回详情页，保留 M1 语义）
  final VoidCallback? onOpenBookInfo;

  const MangaMenuTopBar({
    super.key,
    required this.bookName,
    this.chapterName,
    this.sourceName,
    required this.onBack,
    required this.onRefresh,
    required this.onMore,
    this.onOpenBookInfo,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final chapter = chapterName?.trim() ?? '';
    final source = sourceName?.trim() ?? '';
    final hasChapter = chapter.isNotEmpty;
    final hasSource = source.isNotEmpty;
    return SafeArea(
      // 实心顶栏含状态栏区（截图：SafeArea 上缘覆盖状态栏）
      bottom: false,
      child: Container(
        // 实心表面色占满宽度（浅色主题 = 浅灰，暗色自动暗）
        color: scheme.surfaceContainer,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Row1：返回 + Spacer + 右上图标组（刷新 + 更多，间距均布）
            Row(
              children: [
                _MangaTopBarIcon(
                  icon: Symbols.arrow_back_rounded,
                  tooltip: '返回',
                  onTap: onBack,
                ),
                const Spacer(),
                _MangaTopBarIcon(
                  icon: Symbols.refresh_rounded,
                  tooltip: '刷新',
                  onTap: onRefresh,
                ),
                const SizedBox(width: 8),
                _MangaTopBarIcon(
                  // 「更多」= 打开页操作底栏（复用既有页操作菜单，真实功能）；
                  // 参考版「换源」键我方无功能，不放（E8 登记）
                  icon: Symbols.more_vert_rounded,
                  tooltip: '更多',
                  onTap: onMore,
                ),
              ],
            ),
            // Row2 标题区（左对齐 padding 16）：书名大字 + 次行（章名 + 源名）；
            // 点击 = 返回详情页（保留现有语义）
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: onOpenBookInfo ?? onBack,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // 书名大字（~24sp w600 onSurface，截图形态）
                    Text(
                      bookName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.w600,
                        color: scheme.onSurface,
                      ),
                    ),
                    const SizedBox(height: 4),
                    // 次行：章节名（~14sp onSurfaceVariant 省略号）+ Spacer +
                    // 源名（~13sp onSurfaceVariant，右端；null/空不显示）
                    Row(
                      mainAxisAlignment:
                          hasChapter ? MainAxisAlignment.start : MainAxisAlignment.end,
                      children: [
                        if (hasChapter)
                          Flexible(
                            child: Text(
                              chapter,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 14,
                                color: scheme.onSurfaceVariant,
                              ),
                            ),
                          ),
                        if (hasChapter && hasSource) const Spacer(),
                        if (hasSource)
                          Text(
                            source,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 13,
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// [P4-3 M2] 底栏两段尺寸常量（供屏幕层页脚上抬适配；两段分离、非一体化面板）
/// 进度行高（左右圆形白钮直径，截图 ~52-56dp 取 56）
const double kMangaProgressRowHeight = 56;

/// 贴底白条高（三键行）
const double kMangaBottomBarHeight = 56;

/// 进度行与白条之间的间隙
const double kMangaBottomSegmentGap = 8;

/// 进度胶囊高（胶囊内 Slider 区域；thumb 竖条高 = 此高 × 60%）
const double kMangaProgressCapsuleHeight = 44;

/// 进度行圆形白钮（surface 底 + 浮起阴影，直径 [kMangaProgressRowHeight]）
///
/// 图标 [Symbols.skip_previous] / [Symbols.skip_next]（替换 M1 箭头），
/// 图标色 onSurface；[tooltip] 同时作为语义标签。
class _MangaCircleButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  const _MangaCircleButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
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
          child: Container(
            width: kMangaProgressRowHeight,
            height: kMangaProgressRowHeight,
            decoration: BoxDecoration(
              // 白色圆钮：surface 底（暗色主题自动为暗色表面）
              color: scheme.surface,
              shape: BoxShape.circle,
              // 浮起阴影（截图：圆钮浮起于漫画内容上）
              boxShadow: const [
                BoxShadow(
                  color: Color(0x26000000),
                  blurRadius: 8,
                  offset: Offset(0, 2),
                ),
              ],
            ),
            child: Center(
              child: Icon(icon, size: 28, color: scheme.onSurface),
            ),
          ),
        ),
      ),
    );
  }
}

/// 自绘竖条 Slider thumb（[P4-3 M2] 截图：参考版深蓝竖条贴左形态）
///
/// ~4.5dp 宽 × 胶囊高 60% 的圆角竖条，primary 色（启用）/ 38% alpha
/// primary（禁用，pageCount = 1），配色按 enableAnimation 插值
/// （对齐 SDK [RoundSliderThumbShape] 的 ColorTween 模式）。
class _MangaBarThumbShape extends SliderComponentShape {
  /// 竖条宽（截图 ~4-5dp）
  static const double barWidth = 4.5;

  /// 竖条高 = 胶囊高 [kMangaProgressCapsuleHeight] × 60%
  static double get barHeight => kMangaProgressCapsuleHeight * 0.6;

  @override
  Size getPreferredSize(
    bool isEnabled,
    bool isDiscrete, {
    TextPainter? labelPainter,
    double? textScaleFactor,
  }) {
    return Size(barWidth, barHeight);
  }

  @override
  void paint(
    PaintingContext context,
    Offset center, {
    required Animation<double> activationAnimation,
    required Animation<double> enableAnimation,
    required bool isDiscrete,
    required TextPainter labelPainter,
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required TextDirection textDirection,
    required double value,
    required double textScaleFactor,
    required Size sizeWithOverflow,
  }) {
    assert(sliderTheme.disabledThumbColor != null);
    assert(sliderTheme.thumbColor != null);
    // 竖条配色：禁用 → 启用 按 enableAnimation 插值（SDK 同款模式）
    final color = ColorTween(
      begin: sliderTheme.disabledThumbColor,
      end: sliderTheme.thumbColor,
    ).evaluate(enableAnimation)!;
    final rect = Rect.fromCenter(
      center: center,
      width: barWidth,
      height: barHeight,
    );
    final corner = Radius.circular(barWidth / 2);
    context.canvas.drawRRect(
      RRect.fromRectAndCorners(
        rect,
        topLeft: corner,
        topRight: corner,
        bottomLeft: corner,
        bottomRight: corner,
      ),
      Paint()..color = color,
    );
  }
}

/// 进度胶囊（白色 stadium 全圆角，占余宽，内放分段 SeekToPage 滑条）
///
/// 滑条：thumb = [_MangaBarThumbShape] 自绘竖条（primary）、轨道透明
/// （trackHeight 0 = 不绘制轨道）、divisions 点串 primary 色（参考版
/// 整串均匀蓝点：active 段实心 primary、inactive 段 40% alpha primary）；
/// 拖动语义不变（SeekToPage），pageCount = 1 时禁用保持。
class _MangaProgressCapsule extends StatelessWidget {
  final double pageValue;
  final double pageMax;
  final int? divisions;
  final bool pageEnabled;
  final String readingPageDescription;
  final void Function(int page) onSeekPage;

  const _MangaProgressCapsule({
    required this.pageValue,
    required this.pageMax,
    required this.divisions,
    required this.pageEnabled,
    required this.readingPageDescription,
    required this.onSeekPage,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      height: kMangaProgressCapsuleHeight,
      decoration: BoxDecoration(
        // 白色胶囊：surface 底 + 全圆角（stadium）+ 浮起阴影
        color: scheme.surface,
        borderRadius: BorderRadius.circular(kMangaProgressCapsuleHeight / 2),
        boxShadow: const [
          BoxShadow(
            color: Color(0x26000000),
            blurRadius: 8,
            offset: Offset(0, 2),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20),
        // 局部 SliderTheme（只影响本胶囊滑条，不动应用级滑条主题）：
        // 竖条 thumb + 透明轨道 + primary 点串 + 无数值气泡
        child: SliderTheme(
          data: SliderThemeData(
            // 轨道透明：trackHeight 0 → SDK 轨道绘制直接 no-op
            trackHeight: 0,
            thumbShape: _MangaBarThumbShape(),
            overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
            tickMarkShape: const RoundSliderTickMarkShape(tickMarkRadius: 2),
            thumbColor: scheme.primary,
            disabledThumbColor: scheme.primary.withValues(alpha: 0.38),
            overlayColor: scheme.primary.withValues(alpha: 0.12),
            // 点串配色（截图整串均匀蓝点）：thumb 左侧 active 段
            // 实心 primary、右侧 inactive 段 40% alpha primary
            activeTickMarkColor: scheme.primary,
            inactiveTickMarkColor: scheme.primary.withValues(alpha: 0.4),
          ),
          child: Slider(
            value: pageValue.clamp(0.0, pageMax),
            min: 0,
            max: pageMax,
            divisions: divisions,
            // 轨道透明后 active/inactive 轨不绘制，仅留合法色
            activeColor: scheme.primary,
            inactiveColor: scheme.surface,
            onChanged: pageEnabled ? (v) => onSeekPage(v.round()) : null,
            // 无障碍描述（对齐参考版 readingPageDescription）
            semanticFormatterCallback: (_) => readingPageDescription,
            // 参考版无数值气泡（本 SDK 默认 onlyForDiscrete 常显，显式关闭）
            showValueIndicator: ShowValueIndicator.never,
          ),
        ),
      ),
    );
  }
}

/// 三键行按键（白条内，图标 28 / 点击区 40×40 透明）
///
/// [iconColor] 支持状态着色（自动键：开启 = primary 蓝，关闭 = onSurface）；
/// [tooltip] 同时作为语义标签。
class _MangaBottomBarKey extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final Color iconColor;
  final VoidCallback onTap;
  final GestureLongPressCallback? onLongPress;

  const _MangaBottomBarKey({
    required this.icon,
    required this.tooltip,
    required this.iconColor,
    required this.onTap,
    this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: tooltip,
      child: Tooltip(
        message: tooltip,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          onLongPress: onLongPress,
          child: SizedBox(
            width: 40,
            height: 40,
            child: Icon(icon, size: 28, color: iconColor),
          ),
        ),
      ),
    );
  }
}

/// 底栏（[P4-3 M2] 两段分离：进度行悬浮于图上 + 贴底白条，非 M1 一体化面板）
///
/// - 进度行（悬浮）：左右独立圆形白钮（surface 底 + 浮起阴影、直径
///   [kMangaProgressRowHeight]、图标 skip_previous / skip_next，替换
///   M1 箭头）+ 中间白色胶囊（stadium 全圆角、占余宽）内放 Slider
///   （竖条 thumb primary / 轨道透明 / divisions 点串 primary）；
/// - 贴底白条（[kMangaBottomBarHeight] 高、colorScheme.surface、
///   SafeArea bottom）：三键均布 = 目录（list，保留）/ 自动（auto_mode，
///   状态着色：开启 primary 蓝、关闭 onSurface）/ 设置（settings 齿轮，
///   替换 M1 tune，点击仍 = OpenSettings(READER) 翻页设置）；
/// - 段间间隙 [kMangaBottomSegmentGap]；语义保留（SeekToPage /
///   ToggleAutoRead 描述 停止/自动 随开关态、长按 OpenSettings(AUTO_READ) /
///   OpenSettings(READER)，离线缓存键不放）。
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

  /// 自动阅读开关态（决定键描述 停止/自动 与图标着色 primary/onSurface）
  final bool autoReadEnabled;

  /// 自动键点击（参考版 ToggleAutoRead）
  final VoidCallback onToggleAutoRead;

  /// 自动键长按（参考版 OpenSettings(AUTO_READ)）
  final VoidCallback onOpenAutoSettings;

  /// 翻页设置键（设置齿轮，参考版 OpenSettings(READER)）
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
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 段1：进度行（悬浮于漫画内容上方）
          Padding(
            padding: const EdgeInsets.fromLTRB(
              16,
              12,
              16,
              kMangaBottomSegmentGap,
            ),
            child: Row(
              children: [
                _MangaCircleButton(
                  icon: Symbols.skip_previous_rounded,
                  tooltip: '上一章',
                  onTap: onPrevChapter,
                ),
                const SizedBox(width: 8),
                // 白色胶囊占余宽（stadium 全圆角 + 浮起阴影 + 分段滑条）
                Expanded(
                  child: _MangaProgressCapsule(
                    pageValue: pageValue,
                    pageMax: pageMax,
                    divisions: divisions,
                    pageEnabled: pageEnabled,
                    readingPageDescription: readingPageDescription,
                    onSeekPage: onSeekPage,
                  ),
                ),
                const SizedBox(width: 8),
                _MangaCircleButton(
                  icon: Symbols.skip_next_rounded,
                  tooltip: '下一章',
                  onTap: onNextChapter,
                ),
              ],
            ),
          ),
          // 段2：贴底白条（全宽 surface，三键均布；SafeArea bottom 由
          // 外层 SafeArea 承担导航栏内边距）
          Container(
            height: kMangaBottomBarHeight,
            color: scheme.surface,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                _MangaBottomBarKey(
                  icon: Symbols.list_rounded,
                  tooltip: '目录',
                  iconColor: scheme.onSurface,
                  onTap: onOpenCatalog,
                ),
                _MangaBottomBarKey(
                  icon: Symbols.auto_mode_rounded,
                  // 参考版 L606-610：开 = 「停止」，关 = 「自动」
                  tooltip: autoReadEnabled ? '停止' : '自动',
                  // 状态着色（截图：开启图标变 primary 蓝，关闭 onSurface）
                  iconColor:
                      autoReadEnabled ? scheme.primary : scheme.onSurface,
                  onTap: onToggleAutoRead,
                  onLongPress: onOpenAutoSettings,
                ),
                _MangaBottomBarKey(
                  // 设置齿轮（替换 M1 tune 图标），点击 = 翻页设置
                  icon: Symbols.settings_rounded,
                  tooltip: '翻页设置',
                  iconColor: scheme.onSurface,
                  onTap: onOpenPageSettings,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
