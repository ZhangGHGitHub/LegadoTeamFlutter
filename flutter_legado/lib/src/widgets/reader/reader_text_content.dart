import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show ValueChanged, ValueListenable;
import 'package:flutter/gestures.dart' show DragStartBehavior, kTouchSlop;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderBox, RenderParagraph;
import 'package:flutter/services.dart' show HapticFeedback;
import 'package:flutter_riverpod/flutter_riverpod.dart' show ProviderScope;

import '../../l10n/app_strings.dart';
import '../../models/highlight_style.dart';
import '../../screens/reader_config_panel.dart' show readerAdvConfigProvider;
import '../../utils/reader_inline_image.dart';
import '../../widgets/paragraph_layout_engine.dart';
import 'highlight_span_builder.dart';
import 'reader_bookmark_badge.dart';
import 'reader_inline_image_widget.dart';
import 'reader_text_selection.dart';
import 'review_column.dart';
import 'reader_page_chrome.dart';
import 'text_selection_panel.dart';

/// 段评角标点击（段落索引 1-based、评论数）
typedef ReviewTapCallback = void Function(int paragraphIndex, int count);

/// 阅读器正文排版渲染
///
/// 移植自安卓端 TextChapterLayout 的页面渲染逻辑：
/// - 首屏显示章节标题
/// - 正文使用排版引擎的分行结果渲染
/// - 支持两端对齐、首行缩进、中文避头尾
class ReaderTypographicPage extends StatelessWidget {
  final PageInfo? pageInfo;
  final int pageIndex;
  final int totalPages;
  final String? chapterTitle;

  /// [P2-2] 分页快照章节索引（加载冻结帧优先于阅读状态）
  final int? chapterIndex;

  final double fontSize;
  final double lineHeight;
  final double paragraphSpacing;
  final Color backgroundColor;
  final Color textColor;

  /// 全局页索引（跨章节连续编号，可选）
  final int? globalPageIndex;

  /// 全局总页数（可选）
  final int? globalTotalPages;

  // [UI-fix v2.0.3 | 2026-08-06] 页面内容边距接阅读配置（对标原版
  // ReadBookConfig 四向 padding），默认保持历史硬编码值 — Qoder
  final EdgeInsets contentPadding;

  // [UI-fix v2.0.3 | 2026-08-08] 长按选择文本开关（对标原版 selectText，
  // 关闭后长按正文不再弹出选区面板）— Qoder
  final bool selectText;

  // [UI-fix v2.0.4 | 2026-08-08] 分页页渲染补齐排版参数透传：字距/字体/
  // 两端对齐/字重（此前分页模式仅测量时生效、渲染未应用导致宽度不一致；
  // 字重对标原版 textBold → TextPaint.typeface 加粗/细体）— Qoder
  final double letterSpacing;
  final String? fontFamily;
  final bool justify;
  final FontWeight? fontWeight;

  // [C3 斜体 | Qoder UI] 正文斜体（与 fontWeight 同链路透传，测量/渲染同参）
  final FontStyle? fontStyle;

  // [UI-fix v2.0.59 | 2026-08-14] 页眉/页脚提示与标题样式 — Cursor UI
  final ReaderPageChromeConfig pageChrome;
  final ReaderTipContext tipContext;

  final Map<int, int>? reviewCounts;
  final ReviewTapCallback? onReviewTap;

  /// [批34] 本章高亮命中区间（UTF-16 章节全局偏移，互不重叠）
  final List<HighlightMatch> highlightMatches;

  /// [批4d] 本页是否有书签（角标不参与滚动模式，由调用方只在分页页传入）
  final bool showBookmarkBadge;

  /// [批4d] 角标自定义图相对标识（空/缺失回落默认琥珀）
  final String bookmarkBadgeImage;

  /// [批4d] 角标大小 dp（<=0 隐藏）
  final int bookmarkBadgeSize;

  // [R49 阶段C] 选区活跃状态/外部清选区信号/按下通报（透传 ReaderTextContent）
  final ValueChanged<bool>? onSelectionActiveChanged;
  final ValueListenable<int>? selectionClearSignal;
  final ValueChanged<bool>? onSelectionPointerDown;
  final VoidCallback? onSelectionStartRequested;

  // [批16] 正文图片渲染配置（字节加载/点击档位/预览回调）与章节标题图
  // 布局（首屏标题下方，高度已计入首页分页容量）。
  final ReaderImageRenderConfig imageConfig;
  final ReaderImageLayout? titleImageLayout;

  const ReaderTypographicPage({
    super.key,
    required this.pageInfo,
    required this.pageIndex,
    required this.totalPages,
    required this.chapterTitle,
    this.chapterIndex,
    required this.fontSize,
    required this.lineHeight,
    required this.paragraphSpacing,
    required this.backgroundColor,
    required this.textColor,
    this.globalPageIndex,
    this.globalTotalPages,
    this.contentPadding = const EdgeInsets.symmetric(
      horizontal: 20,
      vertical: 24,
    ),
    this.pageChrome = const ReaderPageChromeConfig(),
    this.tipContext = const ReaderTipContext(pageIndex: 0, totalPages: 1),
    this.selectText = true,
    this.letterSpacing = 0.0,
    this.fontFamily,
    this.justify = true,
    this.fontWeight,
    this.fontStyle,
    this.reviewCounts,
    this.onReviewTap,
    this.highlightMatches = const [],
    this.showBookmarkBadge = false,
    this.bookmarkBadgeImage = '',
    this.bookmarkBadgeSize = 10,
    this.imageConfig = const ReaderImageRenderConfig(),
    this.titleImageLayout,
    this.onSelectionActiveChanged,
    this.selectionClearSignal,
    this.onSelectionPointerDown,
    this.onSelectionStartRequested,
  });

  @override
  Widget build(BuildContext context) {
    // 分页结果尚未就绪时显示加载状态
    final info = pageInfo;
    if (info == null) {
      return Center(
        child: Text(
          AppStrings.noContent,
          style: TextStyle(
            fontSize: fontSize,
            color: textColor.withValues(alpha: 0.5),
          ),
        ),
      );
    }

    final chrome = pageChrome;
    final showHeader = chrome.showPageHeader && chrome.hasHeaderTips;
    final showFooter = chrome.showPageFooter && chrome.hasFooterTips;
    final showTitle =
        pageIndex == 0 &&
        chapterTitle != null &&
        chrome.titleMode.clamp(0, 2) != 2;
    final titleAlign = switch (chrome.titleMode.clamp(0, 2)) {
      1 => TextAlign.center,
      _ => TextAlign.start,
    };

    final pageContent = Container(
      color: backgroundColor,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (showHeader)
            ReaderPageTipBar(
              padding: EdgeInsets.fromLTRB(
                chrome.headerPaddingLeft,
                chrome.headerPaddingTop,
                chrome.headerPaddingRight,
                chrome.headerPaddingBottom,
              ),
              leftTip: chrome.tipHeaderLeft,
              middleTip: chrome.tipHeaderMiddle,
              rightTip: chrome.tipHeaderRight,
              tipContext: tipContext,
              textColor: textColor,
              showDivider: chrome.showHeaderLine,
              dividerOnTop: false,
            ),
          Expanded(
            child: Padding(
              padding: contentPadding,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (showTitle)
                    Padding(
                      padding: EdgeInsets.only(
                        top: chrome.titleTopSpacing.toDouble(),
                        bottom: chrome.titleBottomSpacing.toDouble(),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Align(
                            alignment: titleAlign == TextAlign.center
                                ? Alignment.center
                                : Alignment.centerLeft,
                            child: Text(
                              chapterTitle!,
                              textAlign: titleAlign,
                              style: TextStyle(
                                fontSize: fontSize + chrome.titleSize,
                                fontWeight: FontWeight.bold,
                                color: textColor,
                                // [C3 标题字体] 与测量侧同参（effectiveTitleFontFamily
                                // 单源）；同时修复既有偏差：空=跟随正文字体，标题
                                // 随自定义正文自定义字体生效 — full-stack-engineer
                                fontFamily: effectiveTitleFontFamily(
                                  chrome,
                                  fontFamily,
                                ),
                              ),
                            ),
                          ),
                          // [批16] 章节标题图（`BookChapter.imgUrl`）：对齐上游
                          // TextChapterLayout.kt:326-380，首屏标题下方展示；
                          // 高度已由阅读页计入首页分页容量（同一布局单源）。
                          if (titleImageLayout != null)
                            Padding(
                              padding: const EdgeInsets.only(top: 6),
                              child: ReaderImageLineWidget(
                                layout: titleImageLayout!,
                                config: imageConfig,
                              ),
                            ),
                        ],
                      ),
                    ),
                  Expanded(
                    child: ClipRect(
                      // 防分页测量与渲染亚像素差导致的行溢出条纹
                      child: ReaderTextContent(
                        pageInfo: info,
                        fontSize: fontSize,
                        lineHeight: lineHeight,
                        paragraphSpacing: paragraphSpacing,
                        textColor: textColor,
                        selectText: selectText,
                        letterSpacing: letterSpacing,
                        fontFamily: fontFamily,
                        justify: justify,
                        fontWeight: fontWeight,
                        fontStyle: fontStyle,
                        reviewCounts: reviewCounts,
                        onReviewTap: onReviewTap,
                        highlightMatches: highlightMatches,
                        chapterIndex: chapterIndex,
                        chapterTitle: chapterTitle,
                        imageConfig: imageConfig,
                        onSelectionActiveChanged: onSelectionActiveChanged,
                        selectionClearSignal: selectionClearSignal,
                        onSelectionPointerDown: onSelectionPointerDown,
                        onSelectionStartRequested: onSelectionStartRequested,
                      ),
                    ),
                  ),
                  if (!showFooter)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Center(
                        child: Text(
                          _buildPageIndicator(),
                          style: TextStyle(
                            fontSize: 11,
                            color: textColor.withValues(alpha: 0.4),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          if (showFooter)
            ReaderPageTipBar(
              padding: EdgeInsets.fromLTRB(
                chrome.footerPaddingLeft,
                chrome.footerPaddingTop,
                chrome.footerPaddingRight,
                chrome.footerPaddingBottom,
              ),
              leftTip: chrome.tipFooterLeft,
              middleTip: chrome.tipFooterMiddle,
              rightTip: chrome.tipFooterRight,
              tipContext: tipContext,
              textColor: textColor,
              showDivider: chrome.showFooterLine,
              dividerOnTop: true,
            ),
        ],
      ),
    );
    // [批4d] 角标叠在整页内容上：顶部 = 页眉块高 + 正文 contentTop + 内缩
    // （path 自带顶部内缩，topInset 现为 0）；右侧 = 正文 right padding+6dp。
    if (!showBookmarkBadge || bookmarkBadgeSize <= 0) return pageContent;
    final badgeTop =
        ReaderPageLayoutMetrics.headerBlockHeight(context, chrome) +
        contentPadding.top +
        ReaderBookmarkBadgeGeometry.topInset;
    return Stack(
      fit: StackFit.expand,
      children: [
        pageContent,
        Positioned(
          top: badgeTop,
          right: contentPadding.right + ReaderBookmarkBadgeGeometry.rightInset,
          child: ReaderBookmarkBadge(
            size: bookmarkBadgeSize,
            image: bookmarkBadgeImage,
          ),
        ),
      ],
    );
  }

  /// 构建页码指示文本
  ///
  /// 格式："章内页/章总页" 或 "章内页/章总页 · 全局页/全局总页"
  String _buildPageIndicator() {
    final localIndicator = '${pageIndex + 1}/$totalPages';
    final gIndex = globalPageIndex;
    final gTotal = globalTotalPages;
    if (gIndex != null && gTotal != null && gTotal > 0) {
      return '$localIndicator · ${gIndex + 1}/$gTotal';
    }
    return localIndicator;
  }
}

/// 单页排版内容（逐行渲染，支持两端对齐）
///
/// 移植自 TextChapterLayout.kt 的 addCharsToLineFirst/Middle/Natural
///
/// [R49 阶段A] 由 StatelessWidget 改为 StatefulWidget：字符级选区状态是
/// 瞬时 UI 状态，放在本组件自己的 State（每个页面/滚动分片实例独立），
/// 不进 Riverpod、不落库、不进快照。构造参数保持完全兼容。
class ReaderTextContent extends StatefulWidget {
  final PageInfo pageInfo;
  final double fontSize;
  final double lineHeight;
  final double paragraphSpacing;
  final Color textColor;

  // [UI-fix v2.0.2 | 2026-08-06] 字距调节与字体选择接入渲染
  // （对标原版 ReadBookConfig.letterSpacing/textFont） — Qoder
  final double letterSpacing;
  final String? fontFamily;

  /// 两端对齐开关（对标 MoreConfig textFullJustify）
  final bool justify;

  // [UI-fix v2.0.3 | 2026-08-08] 长按选择文本开关（对标原版 selectText，
  // 关闭后长按不弹选区面板，对标 ReadView.textSelectAble 事件语义）— Qoder
  final bool selectText;

  // [UI-fix v2.0.4 | 2026-08-08] 文字字重（对标原版 textBold：中/粗/细，
  // null=正常字重）— Qoder
  final FontWeight? fontWeight;

  // [C3 斜体 | Qoder UI] 正文斜体（与 fontWeight 同链路透传，测量/渲染同参）
  final FontStyle? fontStyle;

  /// 段评摘要：段落索引 → 评论数（P2-9 ruleReview）
  final Map<int, int>? reviewCounts;

  /// 段评角标点击
  final ReviewTapCallback? onReviewTap;

  /// [批34] 本章高亮命中区间（UTF-16 章节全局偏移）
  final List<HighlightMatch> highlightMatches;

  /// [批32 P3-2] 父级已确认 [highlightMatches] 按 `start` 升序时为 true：
  /// 滚动模式整章 = N 个本组件，父级校验一次后下传，避免每页重复 O(m)
  /// 有序校验。null 表示未声明，本组件内部校验并按需排序一次。
  final bool? matchesStartSorted;

  /// [P2-2] 分页快照章节索引/标题（长按选区时优先于实时阅读状态）
  final int? chapterIndex;
  final String? chapterTitle;

  /// [批16] 正文图片渲染配置
  final ReaderImageRenderConfig imageConfig;

  /// [R49 阶段C] 选区活跃状态变化回调
  ///
  /// 父级（ReaderPageView）据此维护 `selectionActive` 单一状态源，
  /// 用于翻页层门控与阅读器点击分区抑制。true=存在非折叠选区。
  final ValueChanged<bool>? onSelectionActiveChanged;

  /// [R49 阶段C] 外部清选区信号（自增触发；翻页/换章/空白点击）
  ///
  /// 不在 build 期同步清（Overlay 收起需在帧外），由父级在安全时机自增。
  final ValueListenable<int>? selectionClearSignal;

  /// [R49 阶段C] 选区/手柄区域的指针按下通报
  ///
  /// [onHandle] 为 true：按在手柄热区上（选区保留，仅抑制点击分区）；
  /// 为 false：按下了正文非手柄位置（选区已由本组件清除）。
  final ValueChanged<bool>? onSelectionPointerDown;

  /// [R49 阶段C] 新起选前请求父级清除其它正文实例的旧选区
  ///
  /// 滚动模式整章 = N 个 [ReaderTextContent]，选区是实例级瞬时状态；
  /// 起选前广播清理保证同一时刻只有一处选区（与参考版单选区语义一致）。
  final VoidCallback? onSelectionStartRequested;

  const ReaderTextContent({
    super.key,
    required this.pageInfo,
    required this.fontSize,
    required this.lineHeight,
    required this.paragraphSpacing,
    required this.textColor,
    this.letterSpacing = 0.0,
    this.fontFamily,
    this.justify = true,
    this.selectText = true,
    this.fontWeight,
    this.fontStyle,
    this.reviewCounts,
    this.onReviewTap,
    this.highlightMatches = const [],
    this.matchesStartSorted,
    this.chapterIndex,
    this.chapterTitle,
    this.imageConfig = const ReaderImageRenderConfig(),
    this.onSelectionActiveChanged,
    this.selectionClearSignal,
    this.onSelectionPointerDown,
    this.onSelectionStartRequested,
  });

  @override
  State<ReaderTextContent> createState() => ReaderTextContentState();
}

/// [R49 阶段A] 正文渲染 + 字符级选区
///
/// 承重约束：分页/行高由 `ParagraphLayoutEngine` 单源决定，渲染只是逐行
/// `Text`。本 State **不改变任何布局尺寸**：
/// - 不替换 `Text`/`Text.rich`，不改 `SizedBox(height: line.height)`；
/// - 只通过只读探测（[_LineProbe] 记录行 context）向真实
///   `RenderParagraph` 要命中/选区几何；
/// - 灰块用根 Stack 的 `CustomPaint` + `IgnorePointer` 叠加绘制。
class ReaderTextContentState extends State<ReaderTextContent> {
  /// 当前选区（章节 UTF-16 偏移，端点含端）
  final ValueNotifier<ReaderTextSelection?> _selection =
      ValueNotifier<ReaderTextSelection?>(null);

  /// 手柄拖拽状态（驱动手柄跟随手指重绘，不重建文字树）
  final ValueNotifier<_HandleDragState?> _handleDrag =
      ValueNotifier<_HandleDragState?>(null);

  /// 灰块/手柄绘制层坐标基准（根 Stack）
  final GlobalKey _contentStackKey = GlobalKey(
    debugLabel: 'reader-selection-stack',
  );

  /// 行探测句柄（每次 build 重建；只写 context，不触发重建）
  List<_LineHandle> _lineHandles = const [];

  /// 手柄热区几何（根 Stack 局部坐标；选区变化后一帧同步）
  _SelectionGeometry? _handleGeometry;

  /// 长按起点全局坐标（拖动扩展的 kTouchSlop 门控）
  Offset? _longPressOrigin;

  /// 本次长按是否按在手柄上（按在手柄上时失竞/取消不得清选区）
  bool _longPressOnHandle = false;

  /// 当前浮条控制器（非模态；手柄拖拽期间收起，松手后重弹）
  ReaderSelectionToolbarHandle? _toolbar;

  /// 手柄拖动振动节流（参考 TextHandleMove，避免每字符触发马达）
  DateTime _lastHandleHapticAt = DateTime.fromMillisecondsSinceEpoch(0);

  /// 几何同步防抖（同一帧内多次选区变化只同步一次）
  bool _handleSyncScheduled = false;

  /// [R49 阶段C] 最近一次上报给父级的选区活跃状态（避免重复回调）
  bool _lastReportedSelectionActive = false;

  // 兼容既有 build 代码的字段读取（与 widget 字段同义）。
  PageInfo get pageInfo => widget.pageInfo;
  double get fontSize => widget.fontSize;
  double get lineHeight => widget.lineHeight;
  double get paragraphSpacing => widget.paragraphSpacing;
  Color get textColor => widget.textColor;
  double get letterSpacing => widget.letterSpacing;
  String? get fontFamily => widget.fontFamily;
  bool get justify => widget.justify;
  bool get selectText => widget.selectText;
  FontWeight? get fontWeight => widget.fontWeight;
  FontStyle? get fontStyle => widget.fontStyle;
  Map<int, int>? get reviewCounts => widget.reviewCounts;
  ReviewTapCallback? get onReviewTap => widget.onReviewTap;
  List<HighlightMatch> get highlightMatches => widget.highlightMatches;
  bool? get matchesStartSorted => widget.matchesStartSorted;
  int? get chapterIndex => widget.chapterIndex;
  String? get chapterTitle => widget.chapterTitle;
  ReaderImageRenderConfig get imageConfig => widget.imageConfig;

  /// 选区（测试/后续步骤读取）
  @visibleForTesting
  ReaderTextSelection? get debugSelection => _selection.value;

  /// 选区文本（按需计算；图片占位符已剔除）
  @visibleForTesting
  String? get debugSelectionText {
    final selection = _selection.value;
    if (selection == null || selection.isCollapsed) return null;
    return readerSelectionText(pageInfo, selection);
  }

  /// 浮条是否可见（测试读取；浮条已非模态）
  @visibleForTesting
  bool get debugToolbarVisible => _toolbar?.isVisible ?? false;

  /// 起点/终点手柄热区（测试读取，根 Stack 局部坐标；已按 P2-1 互斥）
  @visibleForTesting
  Rect? get debugStartHandleHitRect {
    final geometry = _handleGeometry;
    return geometry == null ? null : _resolveHandleHitRects(geometry).$1;
  }

  @visibleForTesting
  Rect? get debugEndHandleHitRect {
    final geometry = _handleGeometry;
    return geometry == null ? null : _resolveHandleHitRects(geometry).$2;
  }

  /// 手柄数量（0 = 无选区；2 = 起点 + 终点 pin 手柄）
  @visibleForTesting
  int get debugHandleCount => _handleGeometry == null ? 0 : 2;

  /// 当前正在拖动的手柄（'start' / 'end'；未拖动为 null）
  @visibleForTesting
  String? get debugDraggingSide => _handleDrag.value?.side.name;

  /// 两只手柄的空心圆圆心（全局坐标，起点在前）
  @visibleForTesting
  List<Offset> debugHandleCentersGlobal() {
    final selection = _selection.value;
    final root = _contentStackKey.currentContext?.findRenderObject();
    if (selection == null || root is! RenderBox) return const <Offset>[];
    final geometry = _computeSelectionGeometry(selection);
    if (geometry == null) return const <Offset>[];
    return [
      root.localToGlobal(geometry.start.circleCenter),
      root.localToGlobal(geometry.end.circleCenter),
    ];
  }

  @override
  void initState() {
    super.initState();
    widget.selectionClearSignal?.addListener(_handleSelectionClearSignal);
  }

  @override
  void didUpdateWidget(covariant ReaderTextContent oldWidget) {
    super.didUpdateWidget(oldWidget);
    // [R49 阶段C] 外部清选区信号换绑（父级重建时才可能变化）
    if (oldWidget.selectionClearSignal != widget.selectionClearSignal) {
      oldWidget.selectionClearSignal?.removeListener(
        _handleSelectionClearSignal,
      );
      widget.selectionClearSignal?.addListener(_handleSelectionClearSignal);
    }
    // 页码/内容/排版参数任一变化都会让章节偏移失效：清选区防串页。
    final geometryChanged =
        !identical(oldWidget.pageInfo, widget.pageInfo) ||
        oldWidget.fontSize != widget.fontSize ||
        oldWidget.lineHeight != widget.lineHeight ||
        oldWidget.paragraphSpacing != widget.paragraphSpacing ||
        oldWidget.letterSpacing != widget.letterSpacing ||
        oldWidget.fontFamily != widget.fontFamily ||
        oldWidget.justify != widget.justify ||
        oldWidget.fontWeight != widget.fontWeight ||
        oldWidget.fontStyle != widget.fontStyle;
    if (geometryChanged || (oldWidget.selectText && !widget.selectText)) {
      _clearSelection();
    }
  }

  @override
  void dispose() {
    widget.selectionClearSignal?.removeListener(_handleSelectionClearSignal);
    _toolbar?.dismiss();
    _toolbar = null;
    // [R49 阶段C] 失活必须显式复位门控，避免翻页层被永久短路
    _reportSelectionActive(false);
    _selection.dispose();
    _handleDrag.dispose();
    super.dispose();
  }

  void _handleSelectionClearSignal() {
    if (!mounted) return;
    _clearSelection();
  }

  /// [R49 阶段C] 上报选区活跃状态（仅在状态翻转时回调）
  void _reportSelectionActive(bool active) {
    if (active == _lastReportedSelectionActive) return;
    _lastReportedSelectionActive = active;
    widget.onSelectionActiveChanged?.call(active);
  }

  void _syncSelectionActive() {
    final selection = _selection.value;
    _reportSelectionActive(selection != null && !selection.isCollapsed);
  }

  void _setSelection(ReaderTextSelection? next) {
    if (_selection.value == next) return;
    _selection.value = next;
    _syncSelectionActive();
    _scheduleHandleSync();
  }

  void _clearSelection() {
    _longPressOrigin = null;
    _longPressOnHandle = false;
    _handleDrag.value = null;
    _dismissToolbar();
    _setSelection(null);
  }

  void _dismissToolbar() {
    final handle = _toolbar;
    _toolbar = null;
    handle?.dismiss();
  }

  /// 选区变化后一帧同步手柄热区几何
  ///
  /// 手柄绘制本身在 paint 时按真实 `RenderParagraph` 现算；只有热区需要
  /// 参与布局（`Positioned`），因此在选区稳定后同步即可。拖拽期间手势已
  /// 被捕获，热区无需跟随，跳过 rebuild。
  void _scheduleHandleSync() {
    if (_handleSyncScheduled) return;
    _handleSyncScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _handleSyncScheduled = false;
      if (!mounted) return;
      if (_handleDrag.value != null) return;
      final selection = _selection.value;
      final next = (selection == null || selection.isCollapsed)
          ? null
          : _computeSelectionGeometry(selection);
      if (next == null && _handleGeometry == null) return;
      setState(() => _handleGeometry = next);
    });
  }

  /// 长按起选：定位到按压点所在行/字符，按词边界扩成整词
  void _startSelectionAt(Offset globalPosition) {
    // 按在手柄热区上时交给手柄拖拽，不重新起选
    _longPressOnHandle = _isInHandleHitRegion(globalPosition);
    if (_longPressOnHandle) {
      _longPressOrigin = null;
      return;
    }
    // [R49 阶段C] 先广播清理其它正文实例的旧选区（滚动模式整章 N 个
    // chunk）：本实例也在广播中被清，随后重新建立本次选区与长按起点，
    // 保证同一时刻只有一处选区。
    widget.onSelectionStartRequested?.call();
    _longPressOrigin = globalPosition;
    final hit = _hitTestPage(globalPosition, requireLineHeight: true);
    if (hit == null) {
      _setSelection(null);
      return;
    }
    _setSelection(readerSelectionForWordAt(hit.handle.map, hit.localOffset));
  }

  /// 长按被取消（他人赢得手势竞技场）
  ///
  /// 按在手柄上时（手柄拖拽赢得竞技场会把长按判负）不得清选区，否则
  /// 手柄刚起手选区就消失。
  void _cancelLongPress() {
    if (_longPressOnHandle) {
      _longPressOnHandle = false;
      return;
    }
    _clearSelection();
  }

  /// 长按拖动：超过 kTouchSlop 后按字符级扩展端点
  void _extendSelectionTo(Offset globalPosition) {
    final origin = _longPressOrigin;
    if (origin == null) return;
    if ((globalPosition - origin).distance < kTouchSlop) {
      return;
    }
    final current = _selection.value;
    if (current == null) return;
    final hit = _hitTestPage(globalPosition);
    if (hit == null) return;
    final map = hit.handle.map;
    if (!map.isSelectable) return;
    var local = hit.localOffset.clamp(0, map.text.length - 1);
    // 吸附到字形簇边界（代理对/组合附加符号不拆分）
    local = readerAlignToClusterStart(map.text, local);
    final first = map.firstSelectableLocal;
    if (local < first) local = first;
    if (local >= map.text.length) return;
    final chapter = map.localToChapter(local);
    if (chapter == current.focus) return;
    _setSelection(current.copyWith(focus: chapter));
  }

  // ===== 手柄拖拽（步骤 3） =====

  /// 抓手柄起手
  ///
  /// [R49 回修 P0-1] 三点约束（否则多行页上抓可见圆柄会落到下一行）：
  /// 1. `GestureDetector` 必须用 [DragStartBehavior.down]：`start` 下
  ///    `onPanStart` 给的是过完 slop 的位置（SDK `monodrag.dart` 里
  ///    `_initialPosition += delta`），`grabOffset` 会偏一个 slop；
  /// 2. `grabOffset` = 按下点 − 手柄逻辑圆心，后续落点一律先换算回
  ///    「逻辑中心」（`pointer − grabOffset`），手柄才贴手；
  /// 3. **起手不落点**：圆心 = 行底 + 7dp，行与行零间隙首尾相接，按下点
  ///    必然落在下一行矩形内；此处若按原始坐标落点会立刻跳一行（设计
  ///    §5.5 / 参考版 `handleHasMoved` 守卫）。
  void _beginHandleDrag(_HandleSide side, Offset globalPosition) {
    final selection = _selection.value;
    final geometry = _handleGeometry;
    final root = _contentStackKey.currentContext?.findRenderObject();
    if (selection == null || geometry == null || root is! RenderBox) return;
    final line = side == _HandleSide.start ? geometry.start : geometry.end;
    // 起点手柄控制文档顺序靠前的端点（内部仍按 anchor/focus 语义换名）
    final endpointIsAnchor = side == _HandleSide.start
        ? selection.isForward
        : !selection.isForward;
    final local = root.globalToLocal(globalPosition);
    _handleDrag.value = _HandleDragState(
      side: side,
      endpointIsAnchor: endpointIsAnchor,
      pointer: local,
      grabOffset: local - line.circleCenter,
    );
    // 抓手柄即收起浮条（参考 dismissSelectionMenu）
    _dismissToolbar();
  }

  void _updateHandleDrag(Offset globalPosition) {
    final drag = _handleDrag.value;
    if (drag == null) return;
    final root = _contentStackKey.currentContext?.findRenderObject();
    if (root is! RenderBox) return;
    final local = root.globalToLocal(globalPosition);
    _handleDrag.value = drag.copyWithPointer(local);
    _applyHandleDrag(local, drag.grabOffset, drag.endpointIsAnchor);
  }

  /// 手柄拖到新位置：换算回「逻辑中心」后反查字符偏移
  ///
  /// [pointer] / [grabOffset] 均为根 Stack 局部坐标。落点 = 指针 − 抓取
  /// 偏移（回到手柄圆心），再下移一个圆半径（圆心在行底 + 半径，减掉后
  /// 回到所属行内部），与设计 §5.5 `cursorY = global.dy - radius` 及参考
  /// 版 `ReaderCanvasSurface.kt` 一致。吸附字形簇边界。
  void _applyHandleDrag(
    Offset pointer,
    Offset grabOffset,
    bool endpointIsAnchor,
  ) {
    final current = _selection.value;
    if (current == null) return;
    final root = _contentStackKey.currentContext?.findRenderObject();
    if (root is! RenderBox) return;
    final logical = pointer - grabOffset;
    final hit = _hitTestPage(
      root.localToGlobal(
        Offset(logical.dx, logical.dy - kReaderSelectionHandleRadius),
      ),
    );
    if (hit == null) return;
    final map = hit.handle.map;
    if (!map.isSelectable) return;
    var local = hit.localOffset.clamp(0, map.text.length - 1);
    local = readerAlignToClusterStart(map.text, local);
    final first = map.firstSelectableLocal;
    if (local < first) local = first;
    if (local >= map.text.length) return;
    final chapter = map.localToChapter(local);
    final next = endpointIsAnchor
        ? current.withAnchor(chapter)
        : current.withFocus(chapter);
    if (next == current) return;
    _setSelection(next);
    _maybeHandleHaptic();
  }

  void _endHandleDrag() {
    _handleDrag.value = null;
    _scheduleHandleSync();
    // 松手后按新选区重新弹出浮条（参考 ReaderCanvasSurface.kt:1380-1388）
    _showSelectionToolbar();
  }

  void _cancelHandleDrag() {
    _handleDrag.value = null;
    _scheduleHandleSync();
  }

  /// 手柄拖动振动（selectVibrator 开启时节流 60ms）
  void _maybeHandleHaptic() {
    final now = DateTime.now();
    if (now.difference(_lastHandleHapticAt).inMilliseconds < 60) return;
    bool enabled;
    try {
      // 叶子组件不强制要求 ProviderScope（部分渲染测试直接挂载）
      enabled =
          ProviderScope.containerOf(context, listen: false)
              .read(readerAdvConfigProvider)
              ?.selectVibrator ??
          false;
    } catch (_) {
      enabled = false;
    }
    if (!enabled) return;
    _lastHandleHapticAt = now;
    HapticFeedback.selectionClick();
  }

  // ===== 浮条（非模态） =====

  /// 按当前选区弹出浮条：动作作用于选区文本，锚定选区矩形
  void _showSelectionToolbar() {
    final selection = _selection.value;
    if (selection == null || selection.isCollapsed) return;
    final selectedText = readerSelectionText(pageInfo, selection);
    if (selectedText.trim().isEmpty) return;
    final overlayContext = _contentStackKey.currentContext;
    if (overlayContext == null || !overlayContext.mounted) return;
    final geometry = _computeSelectionGeometry(selection);
    final root = _contentStackKey.currentContext?.findRenderObject();
    Rect? bounds;
    Offset anchor;
    if (geometry != null && root is RenderBox) {
      bounds = Rect.fromPoints(
        root.localToGlobal(geometry.bounds.topLeft),
        root.localToGlobal(geometry.bounds.bottomRight),
      );
      anchor = bounds.center;
    } else {
      anchor = _longPressOrigin ?? Offset.zero;
    }
    final paragraph = _paragraphAt(selection.start);
    final paragraphText = paragraph == null
        ? null
        : _paragraphPlainText(paragraph);
    final localStart = (paragraph == null || paragraphText == null)
        ? null
        : _localIndexInParagraph(
            paragraph,
            paragraphText,
            selection,
            selectedText,
          );
    _dismissToolbar();
    _toolbar = ReaderSelectionToolbar.show(
      overlayContext,
      anchor: anchor,
      // 兼容字段：整段文本（"更多"面板的段落上下文/选区文本缺失时回退）
      text: paragraphText ?? selectedText,
      chapterPos: paragraph?.startIndex ?? selection.start,
      chapterIndex: chapterIndex,
      chapterTitle: chapterTitle,
      selectedText: selectedText,
      selectionStartChapterPos: selection.start,
      selectionEndChapterPos: selection.endExclusive,
      paragraphText: paragraphText,
      paragraphChapterPos: paragraph?.startIndex,
      selectionStartInParagraph: localStart,
      selectionBounds: bounds,
      // [R49 回修 P1-1] 执行动作 / 进「更多」面板后由浮条回调清页面选区
      // （设计 §5.5）；`onDismiss` 只收 Overlay，外部点击/抓手柄仍保留选区。
      onExecuted: () {
        if (mounted) _clearSelection();
      },
    );
  }

  /// 选区起点所在段落
  ParagraphInfo? _paragraphAt(int chapterOffset) {
    for (final para in pageInfo.paragraphs) {
      if (chapterOffset >= para.startIndex && chapterOffset <= para.endIndex) {
        return para;
      }
    }
    for (final para in pageInfo.paragraphs) {
      if (_paragraphPlainText(para).trim().isNotEmpty) return para;
    }
    return null;
  }

  /// 段落渲染文本（与长按面板同口径：行拼接，剔除行内图片占位符）
  String _paragraphPlainText(ParagraphInfo para) {
    final buffer = StringBuffer();
    for (final line in para.lines) {
      buffer.write(
        line.words.join('').replaceAll(readerImagePlaceholderChar, ''),
      );
    }
    return buffer.toString();
  }

  /// 选区起点在段落渲染文本中的下标（"更多"面板初值）
  ///
  /// 含行内图片/逐字符映射的段落映射非线性，返回 null 让面板回退整段。
  int? _localIndexInParagraph(
    ParagraphInfo para,
    String paragraphText,
    ReaderTextSelection selection,
    String selectedText,
  ) {
    for (final line in para.lines) {
      if (line.inlineImages.isNotEmpty || line.chapterOffsets != null) {
        return null;
      }
    }
    if (selection.start < para.startIndex) return null;
    if (selection.endExclusive > para.endIndex) return null;
    final indent = paragraphText.length - paragraphText.trimLeft().length;
    final local = indent + (selection.start - para.startIndex);
    if (local < 0) return null;
    if (local + selectedText.length > paragraphText.length) return null;
    if (paragraphText.substring(local, local + selectedText.length) !=
        selectedText) {
      return null;
    }
    return local;
  }

  /// 根层指针按下：非手柄位置清选区并收起浮条（参考 tap 空白清选区）
  ///
  /// [R49 阶段C] 同时向父级通报本次按下已被选区消费：
  /// - 手柄热区：保留选区，仅抑制阅读器点击分区（手柄拖拽由手势竞技场处理）；
  /// - 其他位置：先清选区，再通报抑制（否则同一次点击会接着触发菜单/翻页）。
  void _handleRootPointerDown(PointerDownEvent event) {
    final onHandle = _isInHandleHitRegion(event.position);
    if (onHandle) {
      if (_selection.value != null) {
        widget.onSelectionPointerDown?.call(true);
      }
      return;
    }
    if (_selection.value == null && _toolbar == null) return;
    _clearSelection();
    widget.onSelectionPointerDown?.call(false);
  }

  /// 全局坐标是否落在手柄热区内（与 `_buildHandleHitBox` 同口径）
  bool _isInHandleHitRegion(Offset globalPosition) {
    final geometry = _handleGeometry;
    if (geometry == null) return false;
    final root = _contentStackKey.currentContext?.findRenderObject();
    if (root is! RenderBox || !root.hasSize) return false;
    final local = root.globalToLocal(globalPosition);
    final (startRect, endRect) = _resolveHandleHitRects(geometry);
    return startRect.contains(local) || endRect.contains(local);
  }

  /// 按全局坐标找最近行，并换算行内字符下标
  ///
  /// [requireLineHeight] 为 true 时长按点必须在行高范围内（参考版
  /// `snapToText` 语义：行间空隙可吸附，超出 1 行高则不算命中）。
  _LineHit? _hitTestPage(
    Offset globalPosition, {
    bool requireLineHeight = false,
  }) {
    _LineHandle? best;
    var bestDistance = double.infinity;
    for (final handle in _lineHandles) {
      if (!handle.map.isSelectable) continue;
      final paragraph = handle.paragraph;
      if (paragraph == null || !paragraph.hasSize) continue;
      final origin = paragraph.localToGlobal(Offset.zero);
      final rect = origin & paragraph.size;
      final dy = globalPosition.dy < rect.top
          ? rect.top - globalPosition.dy
          : (globalPosition.dy > rect.bottom
                ? globalPosition.dy - rect.bottom
                : 0.0);
      if (dy < bestDistance) {
        bestDistance = dy;
        best = handle;
      }
    }
    if (best == null) return null;
    final paragraph = best.paragraph;
    if (paragraph == null || !paragraph.hasSize) return null;
    if (requireLineHeight && bestDistance > paragraph.size.height) {
      return null;
    }
    final position = paragraph.getPositionForOffset(
      paragraph.globalToLocal(globalPosition),
    );
    return _LineHit(handle: best, localOffset: position.offset);
  }

  /// 选区 → 各相交行的灰块矩形（根 Stack 局部坐标）
  ///
  /// 几何直接问已渲染的 `RenderParagraph`，保证两端对齐额外字距、悬挂
  /// `Transform`、行内图片实际宽度与"看到什么选什么"一致。
  List<Rect> _computeHighlightRects(ReaderTextSelection selection) {
    final root = _contentStackKey.currentContext?.findRenderObject();
    if (root is! RenderBox || !root.hasSize) return const <Rect>[];
    final rects = <Rect>[];
    for (final handle in _lineHandles) {
      final map = handle.map;
      final range = map.localRangeFor(selection.start, selection.endExclusive);
      if (range == null) continue;
      final paragraph = handle.paragraph;
      if (paragraph == null || !paragraph.hasSize) continue;
      final boxes = paragraph.getBoxesForSelection(
        TextSelection(baseOffset: range.$1, extentOffset: range.$2),
        boxHeightStyle: ui.BoxHeightStyle.includeLineSpacingMiddle,
      );
      for (final box in boxes) {
        final boxRect = box.toRect();
        if (boxRect.isEmpty) continue;
        final topLeft = paragraph.localToGlobal(
          boxRect.topLeft,
          ancestor: root,
        );
        final bottomRight = paragraph.localToGlobal(
          boxRect.bottomRight,
          ancestor: root,
        );
        rects.add(Rect.fromPoints(topLeft, bottomRight));
      }
    }
    return rects;
  }

  /// 选区两端手柄几何 + 选区整体矩形（根 Stack 局部坐标）
  ///
  /// 起点手柄 x = 首个相交行首个 box 的 left，终点手柄 x = 末个相交行末个
  /// box 的 right；竖线上下端取该行 `RenderParagraph` 的实际行框（与参考
  /// `ReaderCanvasSurface.kt:1783-1830` 的 pin 手柄同语义）。
  _SelectionGeometry? _computeSelectionGeometry(
    ReaderTextSelection selection,
  ) {
    final root = _contentStackKey.currentContext?.findRenderObject();
    if (root is! RenderBox || !root.hasSize) return null;
    final stackHeight = root.size.height;
    _HandleLine? start;
    _HandleLine? end;
    Rect? bounds;
    for (final handle in _lineHandles) {
      final map = handle.map;
      final range = map.localRangeFor(selection.start, selection.endExclusive);
      if (range == null) continue;
      final paragraph = handle.paragraph;
      if (paragraph == null || !paragraph.hasSize) continue;
      final lineTop = paragraph.localToGlobal(
        Offset.zero,
        ancestor: root,
      ).dy;
      final lineBottom = lineTop + paragraph.size.height;
      final circleCenterY = _handleCircleCenterY(lineBottom, stackHeight);
      final boxes = paragraph.getBoxesForSelection(
        TextSelection(baseOffset: range.$1, extentOffset: range.$2),
        boxHeightStyle: ui.BoxHeightStyle.includeLineSpacingMiddle,
      );
      for (final box in boxes) {
        final boxRect = box.toRect();
        if (boxRect.isEmpty) continue;
        final topLeft = paragraph.localToGlobal(
          boxRect.topLeft,
          ancestor: root,
        );
        final bottomRight = paragraph.localToGlobal(
          boxRect.bottomRight,
          ancestor: root,
        );
        final rect = Rect.fromPoints(topLeft, bottomRight);
        start ??= _HandleLine(
          x: rect.left,
          top: lineTop,
          bottom: lineBottom,
          circleCenterY: circleCenterY,
        );
        end = _HandleLine(
          x: rect.right,
          top: lineTop,
          bottom: lineBottom,
          circleCenterY: circleCenterY,
        );
        bounds = bounds == null ? rect : bounds.expandToInclude(rect);
      }
    }
    if (start == null || end == null || bounds == null) return null;
    return _SelectionGeometry(start: start, end: end, bounds: bounds);
  }

  /// pin 空心圆的圆心 y
  ///
  /// [R49 回修 P2-2] 默认挂在行底下方一个半径（与参考版一致）。但分页正文
  /// 被 `ClipRect` 裁剪，`RenderBox.hitTest` 又要求落点在 Stack 自身尺寸
  /// 内：选区末行恰是本页最后一行时，`行底 + 7dp` 会跑出正文框，圆与热区
  /// 既看不到也点不到。这里把圆心钳到 `正文框底 - 半径`（圆整体留在框内，
  /// 竖线仍画在原行框）；正文只有一行高时不再内缩。
  double _handleCircleCenterY(double lineBottom, double stackHeight) {
    final preferred = lineBottom + kReaderSelectionHandleRadius;
    final limit = stackHeight - kReaderSelectionHandleRadius;
    if (preferred <= limit || limit < kReaderSelectionHandleRadius) {
      return preferred;
    }
    return limit;
  }

  @override
  Widget build(BuildContext context) {
    final selectionColor = Theme.of(
      context,
    ).colorScheme.primary.withValues(alpha: 0.28);
    // [UI_SYNC_REFACTOR S4 修 | 2026-09-06] 两端对齐的可用宽改用实际布局
    // 约束——此前硬编码屏宽-40，自定义页面边距（contentPadding ≠ 20×2）
    // 时对齐目标宽与渲染约束错位，拉伸后行宽超约束被裁（行尾吞字）— Qoder
    return LayoutBuilder(
      builder: (context, constraints) {
        final widgets = <Widget>[];
        // [R49] 本次 build 的行探测句柄（图片行不参与文字选区）
        final handles = <_LineHandle>[];
        final availableWidth = constraints.maxWidth;
        // [批32 P3-1/P3-2] 整页只排序/校验一次并复用：排序后游标恢复可用
        // （乱序输入不再逐行排序兜底）；父级已确认有序时跳过本页 O(m) 校验。
        final orderedMatches = matchesStartSorted == true
            ? highlightMatches
            : sortHighlightMatchesByStart(highlightMatches);
        var lineMatchCursor = 0;

        for (var paraIdx = 0; paraIdx < pageInfo.paragraphs.length; paraIdx++) {
          final para = pageInfo.paragraphs[paraIdx];

          // 段落间距（非第一段时添加）
          if (paraIdx > 0 && lineHeight > 0) {
            widgets.add(SizedBox(height: paragraphSpacing));
          }

          // 逐行渲染
          final lineWidgets = <Widget>[];
          for (var lineIdx = 0; lineIdx < para.lines.length; lineIdx++) {
            final line = para.lines[lineIdx];
            final isLastLine = lineIdx == para.lines.length - 1;
            final isSingleLine = para.lines.length == 1;

            // [批16] 独立图片行：不参与文字对齐/字距，按图片布局渲染
            if (line.imageLayout != null) {
              lineWidgets.add(
                ReaderImageLineWidget(
                  layout: line.imageLayout!,
                  config: imageConfig,
                ),
              );
              continue;
            }

            final text = line.words.join('');
            // 两端对齐：非最后一行、非单行，且下一行仍是文本行。
            // [批16 设备回修 P3] 文本块被图片行截断时，块末行按自然左对齐，
            // 避免图片上方「前文字。」被拉伸成居中观感。
            double extraLetterSpacing = 0.0;
            final nextIsText =
                lineIdx + 1 < para.lines.length &&
                para.lines[lineIdx + 1].imageLayout == null;
            // [UI-fix v2.0.2 | 2026-08-06] 关闭两端对齐时不再拉伸字距
            // （对标 MoreConfig textFullJustify 开关） — Qoder
            final shouldJustify =
                justify && !isLastLine && !isSingleLine && nextIsText;
            if (shouldJustify && line.width > 0) {
              if (line.width < availableWidth) {
                final gapCount = line.words.length - 1;
                if (gapCount > 0) {
                  extraLetterSpacing = (availableWidth - line.width) / gapCount;
                  // 限制最大字间距避免过度拉伸
                  extraLetterSpacing = extraLetterSpacing.clamp(
                    0.0,
                    fontSize * 0.5,
                  );
                }
              }
            }

            final lineTextStyle = TextStyle(
              fontSize: fontSize,
              height: lineHeight,
              color: textColor,
              fontFamily: fontFamily,
              fontWeight: fontWeight,
              fontStyle: fontStyle,
              letterSpacing: (letterSpacing + extraLetterSpacing) != 0
                  ? letterSpacing + extraLetterSpacing
                  : null,
            );

            // 命中游标：end <= 本行正文起点的命中与本行及后续行无关。
            // [批32 P3-1] 入口排序后列表恒有序，游标始终可推进。
            if (line.highlightMapped && orderedMatches.isNotEmpty) {
              while (lineMatchCursor < orderedMatches.length &&
                  orderedMatches[lineMatchCursor].end <=
                      line.chapterStartIndex) {
                lineMatchCursor++;
              }
            }
            final lineBodyLength =
                text.length - line.highlightSkip.clamp(0, text.length);
            final lineHasHighlight =
                orderedMatches.isNotEmpty &&
                line.highlightMapped &&
                lineMatchCursor < orderedMatches.length &&
                orderedMatches[lineMatchCursor].start <
                    line.chapterStartIndex + lineBodyLength;

            // [批16] 含行内图片的行：占位符替换为 WidgetSpan，文字分段
            // 继承同一行样式/高亮
            final lineText = line.inlineImages.isNotEmpty
                ? _buildInlineImageLine(
                    line,
                    text,
                    lineTextStyle,
                    matches: orderedMatches,
                    searchFrom: lineMatchCursor,
                  )
                // [批34] 命中行改 Text.rich：按章节全局偏移切分 span，只应用
                // 不影响字体度量的样式（颜色/背景/下划线/删除线）— full-stack-engineer
                : !lineHasHighlight
                ? Text(
                    text,
                    style: lineTextStyle,
                    maxLines: 1,
                    overflow: TextOverflow.clip,
                  )
                : Text.rich(
                    TextSpan(
                      children: buildHighlightedLineSpans(
                        text: text,
                        chapterStart: line.chapterStartIndex,
                        highlightSkip: line.highlightSkip,
                        matches: orderedMatches,
                        searchFrom: lineMatchCursor,
                        assumeStartSorted: true,
                      ),
                    ),
                    style: lineTextStyle,
                    maxLines: 1,
                    overflow: TextOverflow.clip,
                  );

            lineWidgets.add(
              SizedBox(
                // [批16] 行高取排版结果（纯文本恒为 fontSize*lineHeight；
                // 行内小图行按图片显示高度抬升）
                height: line.height,
                // [UI-fix v2.0.5 | 2026-08-10] 段首标点悬挂行：放宽宽度约束至
                // availableWidth + hangingWidth 避免裁剪，行起点左移 hangingWidth
                // 使起始引号悬挂进缩进区（对齐原版 TextLine.hangingPunctuation
                // 语义）— Reasonix
                // [R49] 行文本外层仅加一层不产生 RenderObject 的探测
                // （_LineProbe），不改任何尺寸/约束。
                child: line.hangingWidth > 0
                    ? OverflowBox(
                        alignment: Alignment.centerLeft,
                        maxWidth: availableWidth + line.hangingWidth,
                        child: Transform.translate(
                          offset: Offset(-line.hangingWidth, 0),
                          child: _LineProbe(
                            handle: _registerLine(
                              handles,
                              line,
                              paraIdx,
                              lineIdx,
                            ),
                            child: lineText,
                          ),
                        ),
                      )
                    : _LineProbe(
                        handle: _registerLine(handles, line, paraIdx, lineIdx),
                        child: lineText,
                      ),
              ),
            );
          }

          // [UI-fix v2.0.1 | 2026-08-06] 段落级长按入口：弹出选区操作面板
          // （对齐原版 ReadView.onLongPress → showTextActionMenu；P0-1 审计修复）
          // [UI-fix v2.0.3 | 2026-08-08] selectText 关闭时移除长按入口 — Qoder
          final paraText = para.lines
              .map(
                (l) =>
                    l.words.join('').replaceAll(readerImagePlaceholderChar, ''),
              )
              .join();
          final reviewCount =
              (para.isParagraphEnd &&
                  para.chapterParagraphIndex > 0 &&
                  reviewCounts != null)
              ? (reviewCounts![para.chapterParagraphIndex] ?? 0)
              : 0;
          final paragraphBody = Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: lineWidgets,
          );
          // [UI_SYNC_REFACTOR S6 | 2026-09-08] 长按交互改造（用户裁决 A：
          // 对齐参考版浮窗）：长按段落于按压点浮出工具条（复制/分享/浏览器/
          // 朗读/书签/更多）；「更多」打开保留的段落面板（替换/高亮/词典/
          // 搜正文/精细选区增强动作不丢失）。
          // 注：SelectionArea 在阅读器 PageView 手势栈下长按不触发
          // （组件测试正常/真机不触发，探针实证父级赢得竞技场），故采用
          // 长按点 Overlay 浮条方案，形态对齐且行为确定 — Qoder
          Widget paragraphContent = reviewCount > 0
              ? Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Expanded(child: paragraphBody),
                    ReviewColumnBadge(
                      count: reviewCount,
                      onTap: onReviewTap == null
                          ? null
                          : () => onReviewTap!(
                              para.chapterParagraphIndex,
                              reviewCount,
                            ),
                    ),
                  ],
                )
              : paragraphBody;
          if (selectText && paraText.trim().isNotEmpty) {
            paragraphContent = GestureDetector(
              // [R49 阶段B] 长按起选（灰块 + 2 只手柄），释放后按选区浮出
              // 非模态浮条（动作作用于选区文本）；手柄拖拽由叠加层接管 —
              // full-stack-engineer
              onLongPressStart: (details) =>
                  _startSelectionAt(details.globalPosition),
              onLongPressMoveUpdate: (details) =>
                  _extendSelectionTo(details.globalPosition),
              onLongPressEnd: (_) => _showSelectionToolbar(),
              onLongPressCancel: _cancelLongPress,
              child: paragraphContent,
            );
          }
          widgets.add(paragraphContent);
        }

        _lineHandles = handles;
        // [R49] 根 Stack 用 passthrough 把父约束原样传给 Column：布局尺寸
        // 与改造前逐像素一致；灰块与手柄都是 Positioned.fill + IgnorePointer
        // 的纯叠加绘制层，不参与布局；手柄热区是两个独立的小 Positioned，
        // 覆盖不到整页，因此不影响正文点击。
        return Listener(
          // 空白处按下即清选区（参考 tap 空白）：translucent 让指针继续
          // 传递，不抢阅读器点击分区/长按。
          behavior: HitTestBehavior.translucent,
          onPointerDown: _handleRootPointerDown,
          child: Stack(
            key: _contentStackKey,
            fit: StackFit.passthrough,
            children: [
              Positioned.fill(
                child: IgnorePointer(
                  child: CustomPaint(
                    key: const ValueKey('reader-selection-highlight'),
                    painter: ReaderSelectionHighlightPainter(
                      repaint: _selection,
                      color: selectionColor,
                      rectsBuilder: () {
                        final selection = _selection.value;
                        if (selection == null || selection.isCollapsed) {
                          return const <Rect>[];
                        }
                        return _computeHighlightRects(selection);
                      },
                    ),
                  ),
                ),
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: widgets,
              ),
              if (selectText) ..._buildSelectionHandleLayers(),
            ],
          ),
        );
      },
    );
  }

  /// [R49] 手柄绘制层 + 两个 28dp 胶囊热区
  ///
  /// 绘制层在文字之上（参考版 pin 手柄压在正文上）；热区只在选区激活时
  /// 挂载，尺寸跟随手柄几何，不改动任何正文尺寸。
  List<Widget> _buildSelectionHandleLayers() {
    final geometry = _handleGeometry;
    final hits = geometry == null ? null : _resolveHandleHitRects(geometry);
    return [
      Positioned.fill(
        child: IgnorePointer(
          child: CustomPaint(
            key: const ValueKey('reader-selection-handles'),
            painter: _ReaderSelectionHandlesPainter(
              repaint: Listenable.merge([_selection, _handleDrag]),
              color: Theme.of(context).colorScheme.primary,
              geometryBuilder: () {
                final selection = _selection.value;
                if (selection == null || selection.isCollapsed) return null;
                return _computeSelectionGeometry(selection);
              },
              dragBuilder: () => _handleDrag.value,
            ),
          ),
        ),
      ),
      if (hits != null) ...[
        _buildHandleHitBox(_HandleSide.start, hits.$1),
        _buildHandleHitBox(_HandleSide.end, hits.$2),
      ],
    ];
  }

  /// 两只手柄的可用热区（根 Stack 局部坐标）
  ///
  /// [R49 回修 P2-1] 默认各自 56dp 胶囊（竖线 + 圆整体可抓）。但两只手柄
  /// 靠得很近时热区会重叠，`RenderStack` 命中的是后绘制的末端热区 → 起点
  /// pin 实际不可抓（单汉字选区、或相邻两行且 x 相近时都会发生）。这里按
  /// 「离哪只圆心更近就归哪只」切分重叠区：
  /// - 圆心横向分离更大（同一行的短选区）→ 在中点纵向切一刀；
  /// - 否则两 pin 分处相邻行 → 在两圆心中点横向切一刀；
  /// - 两圆心距离 < 2×半径时两只可见圆本身已重叠，无法可靠判定，保持原样。
  ///
  /// 判定规则等价于「按下点取最近 pin」，且每只可见圆仍完整落在自己的
  /// 热区内（可见即可抓）。
  (Rect, Rect) _resolveHandleHitRects(_SelectionGeometry geometry) {
    final start = geometry.start;
    final end = geometry.end;
    final startRect = start.hitRect;
    final endRect = end.hitRect;
    if (!startRect.overlaps(endRect)) return (startRect, endRect);
    final dx = (end.x - start.x).abs();
    final dy = (end.circleCenterY - start.circleCenterY).abs();
    const minSeparation = kReaderSelectionHandleRadius * 2;
    if (dx >= minSeparation && dx >= dy) {
      final midX = (start.x + end.x) / 2;
      Rect cut(Rect rect, double centerX) => centerX <= midX
          ? Rect.fromLTRB(rect.left, rect.top, midX, rect.bottom)
          : Rect.fromLTRB(midX, rect.top, rect.right, rect.bottom);
      return (cut(startRect, start.x), cut(endRect, end.x));
    }
    if (dy >= minSeparation) {
      final midY = (start.circleCenterY + end.circleCenterY) / 2;
      Rect cut(Rect rect, double centerY) => centerY <= midY
          ? Rect.fromLTRB(rect.left, rect.top, rect.right, midY)
          : Rect.fromLTRB(rect.left, midY, rect.right, rect.bottom);
      return (cut(startRect, start.circleCenterY),
          cut(endRect, end.circleCenterY));
    }
    return (startRect, endRect);
  }

  Widget _buildHandleHitBox(_HandleSide side, Rect rect) {
    return Positioned(
      left: rect.left,
      top: rect.top,
      width: rect.width,
      height: rect.height,
      child: GestureDetector(
        key: ValueKey('reader-selection-handle-${side.name}'),
        behavior: HitTestBehavior.translucent,
        // [R49 回修 P0-1] 取真实按下点：默认 `start` 给的是过完 pan slop
        // 的位置，抓柄瞬间 grabOffset 会偏一个 slop（手柄跳一下）。
        dragStartBehavior: DragStartBehavior.down,
        onPanStart: (details) =>
            _beginHandleDrag(side, details.globalPosition),
        onPanUpdate: (details) => _updateHandleDrag(details.globalPosition),
        onPanEnd: (_) => _endHandleDrag(),
        onPanCancel: _cancelHandleDrag,
        child: const SizedBox.expand(),
      ),
    );
  }

  /// 登记一行探测句柄（build 期间只写 State 字段，不触发重建）
  _LineHandle _registerLine(
    List<_LineHandle> handles,
    LineInfo line,
    int paragraphIndex,
    int lineIndex,
  ) {
    final handle = _LineHandle(
      map: ReaderLineSelectionMap(line),
      paragraphIndex: paragraphIndex,
      lineIndex: lineIndex,
    );
    handles.add(handle);
    return handle;
  }

  /// 构建含行内图片的文本行（占位符 → WidgetSpan）
  ///
  /// 排版按占位符宽度断行，渲染用同宽 WidgetSpan 替换，保证行宽与分页
  /// 结果一致；文字分段沿用同一行样式，高亮按分段偏移映射。
  Widget _buildInlineImageLine(
    LineInfo line,
    String text,
    TextStyle style, {
    required List<HighlightMatch> matches,
    int searchFrom = 0,
  }) {
    final spans = <InlineSpan>[];
    var segmentStart = 0;
    var imageIndex = 0;
    for (var i = 0; i < text.length; i++) {
      if (text.codeUnitAt(i) != 0xFFFC) continue;
      if (i > segmentStart) {
        spans.addAll(
          _inlineTextSpans(
            line,
            text.substring(segmentStart, i),
            segmentStart,
            matches: matches,
            searchFrom: searchFrom,
          ),
        );
      }
      if (imageIndex < line.inlineImages.length) {
        final layout = line.inlineImages[imageIndex];
        spans.add(
          WidgetSpan(
            alignment: PlaceholderAlignment.middle,
            child: ReaderInlineImageWidget(
              image: layout.image,
              width: layout.width,
              height: layout.height,
              config: imageConfig,
            ),
          ),
        );
      }
      imageIndex++;
      segmentStart = i + 1;
    }
    if (segmentStart < text.length) {
      spans.addAll(
        _inlineTextSpans(
          line,
          text.substring(segmentStart),
          segmentStart,
          matches: matches,
          searchFrom: searchFrom,
        ),
      );
    }
    return Text.rich(
      TextSpan(children: spans),
      style: style,
      maxLines: 1,
      overflow: TextOverflow.clip,
    );
  }

  /// 行内图片行的文字分段 span（高亮偏移按分段起点换算）
  List<InlineSpan> _inlineTextSpans(
    LineInfo line,
    String segment,
    int offsetInLine, {
    required List<HighlightMatch> matches,
    int searchFrom = 0,
  }) {
    if (matches.isEmpty || !line.highlightMapped) {
      return [TextSpan(text: segment)];
    }
    // [批16 三审 P2-5] 行内图片占位符对应整段 `<img>` 标签，优先用逐字符
    // 章节偏移映射；无映射时回落既有线性公式。
    final mapped = line.chapterOffsetAt(offsetInLine);
    final chapterStart =
        mapped ?? line.chapterStartIndex + (offsetInLine - line.highlightSkip);
    return buildHighlightedLineSpans(
      text: segment,
      chapterStart: chapterStart < 0 ? 0 : chapterStart,
      highlightSkip: 0,
      matches: matches,
      searchFrom: searchFrom,
      assumeStartSorted: true,
    );
  }
}

/// [R49] 行探测句柄：只记录行 context 与映射，不持有 RenderObject
///
/// 不使用 GlobalKey：`buildPage(i)` 会同时构建隐藏边界页与 live 页，
/// 状态内自建的句柄天然按实例隔离，不会重复注册。
class _LineHandle {
  _LineHandle({
    required this.map,
    required this.paragraphIndex,
    required this.lineIndex,
  });

  final ReaderLineSelectionMap map;
  final int paragraphIndex;
  final int lineIndex;
  BuildContext? context;

  /// 该行真实渲染的 `RenderParagraph`（未挂载/已失活返回 null）
  RenderParagraph? get paragraph {
    final ctx = context;
    if (ctx == null || !ctx.mounted) return null;
    final object = ctx.findRenderObject();
    return object is RenderParagraph ? object : null;
  }
}

/// 命中结果：目标行 + 行内 UTF-16 下标
class _LineHit {
  const _LineHit({required this.handle, required this.localOffset});

  final _LineHandle handle;
  final int localOffset;
}

/// 行文本外层探测：不产生 RenderObject、不改变约束
class _LineProbe extends StatelessWidget {
  const _LineProbe({required this.handle, required this.child});

  final _LineHandle handle;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    // 只写探测字段（不 setState），供手势阶段查询真实几何。
    handle.context = context;
    return child;
  }
}

/// [R49] 选区灰块绘制（只叠加绘制，不参与布局/不改变任何尺寸）
///
/// 回调由 `ValueNotifier<ReaderTextSelection?>` 驱动 `repaint`，选区变化
/// 时不重建文字树。
class ReaderSelectionHighlightPainter extends CustomPainter {
  ReaderSelectionHighlightPainter({
    required Listenable repaint,
    required this.color,
    required this.rectsBuilder,
  }) : super(repaint: repaint);

  final Color color;
  final List<Rect> Function() rectsBuilder;

  @override
  void paint(Canvas canvas, Size size) {
    final rects = rectsBuilder();
    if (rects.isEmpty) return;
    final paint = Paint()..color = color;
    for (final rect in rects) {
      if (rect.isEmpty) continue;
      canvas.drawRect(rect, paint);
    }
  }

  @override
  bool shouldRepaint(covariant ReaderSelectionHighlightPainter oldDelegate) {
    return oldDelegate.color != color ||
        oldDelegate.rectsBuilder != rectsBuilder;
  }

  /// 测试用：当前应绘制的灰块矩形
  @visibleForTesting
  List<Rect> debugRects() => rectsBuilder();
}

/// [R49] 手柄侧别（起点 pin / 终点 pin）
enum _HandleSide { start, end }

/// [R49] 一只 pin 手柄的竖线几何（根 Stack 局部坐标）
@immutable
class _HandleLine {
  const _HandleLine({
    required this.x,
    required this.top,
    required this.bottom,
    required this.circleCenterY,
  });

  /// 竖线 x（起点 = 首行首个 box 左端；终点 = 末行末个 box 右端）
  final double x;

  /// 竖线上端（行框顶）
  final double top;

  /// 竖线下端（行框底）
  final double bottom;

  /// 空心圆圆心 y（默认行底 + 半径；页底末行内缩，见 `_handleCircleCenterY`）
  final double circleCenterY;

  /// 空心圆圆心（挂在行底下方一个半径处，与参考版一致）
  Offset get circleCenter => Offset(x, circleCenterY);

  /// 28dp 胶囊热区外接矩形（竖线 + 圆整体可抓）
  Rect get hitRect => Rect.fromLTRB(
    x - kReaderSelectionHandleHitRadius,
    top - kReaderSelectionHandleHitRadius,
    x + kReaderSelectionHandleHitRadius,
    circleCenterY + kReaderSelectionHandleHitRadius,
  );
}

/// [R49] 选区两端手柄 + 选区整体矩形（浮条锚定用）
@immutable
class _SelectionGeometry {
  const _SelectionGeometry({
    required this.start,
    required this.end,
    required this.bounds,
  });

  final _HandleLine start;
  final _HandleLine end;

  /// 所有相交行 box 的并集（根 Stack 局部坐标）
  final Rect bounds;
}

/// [R49] 手柄拖拽状态
@immutable
class _HandleDragState {
  const _HandleDragState({
    required this.side,
    required this.endpointIsAnchor,
    required this.pointer,
    required this.grabOffset,
  });

  final _HandleSide side;

  /// 被拖端点是否为选区 anchor（起点手柄控制文档顺序靠前的端点）
  final bool endpointIsAnchor;

  /// 当前指针（根 Stack 局部坐标，用于手柄跟随手指绘制）
  final Offset pointer;

  /// 按下时「指针 - 逻辑圆心」的偏移（局部坐标）
  final Offset grabOffset;

  _HandleDragState copyWithPointer(Offset value) => _HandleDragState(
    side: side,
    endpointIsAnchor: endpointIsAnchor,
    pointer: value,
    grabOffset: grabOffset,
  );
}

/// [R49] 选区 pin 手柄绘制（2dp 竖线 + 行底 7dp 空心圆）
///
/// 对齐参考版 `ReaderCanvasSurface.kt:1783-1830`：竖线从行框顶画到行框底，
/// 空心圆圆心挂在 `行底 + 半径`；拖拽中的手柄按手指位移整体平移（竖线与
/// 圆是同一只手柄）。纯叠加绘制，不参与布局、不改变任何正文尺寸。
class _ReaderSelectionHandlesPainter extends CustomPainter {
  _ReaderSelectionHandlesPainter({
    required Listenable repaint,
    required this.color,
    required this.geometryBuilder,
    required this.dragBuilder,
  }) : super(repaint: repaint);

  final Color color;
  final _SelectionGeometry? Function() geometryBuilder;
  final _HandleDragState? Function() dragBuilder;

  @override
  void paint(Canvas canvas, Size size) {
    final geometry = geometryBuilder();
    if (geometry == null) return;
    final drag = dragBuilder();
    final linePaint = Paint()
      ..color = color
      ..strokeWidth = kReaderSelectionHandleStrokeWidth
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;
    final fillPaint = Paint()..color = Colors.white;
    final circlePaint = Paint()
      ..color = color
      ..strokeWidth = kReaderSelectionHandleStrokeWidth
      ..style = PaintingStyle.stroke;
    for (final side in _HandleSide.values) {
      final line = side == _HandleSide.start ? geometry.start : geometry.end;
      var delta = Offset.zero;
      if (drag != null && drag.side == side) {
        // 与参考一致：按「按下时手指相对圆心的偏移」保持手柄贴在手指上
        delta = (drag.pointer - drag.grabOffset) - line.circleCenter;
      }
      final x = line.x + delta.dx;
      final top = line.top + delta.dy;
      final bottom = line.bottom + delta.dy;
      canvas.drawLine(Offset(x, top), Offset(x, bottom), linePaint);
      // 圆心取几何里的实际值（页底末行已内缩到正文框内，见 P2-2）
      final center = Offset(x, line.circleCenterY + delta.dy);
      canvas.drawCircle(center, kReaderSelectionHandleRadius, fillPaint);
      canvas.drawCircle(center, kReaderSelectionHandleRadius, circlePaint);
    }
  }

  @override
  bool shouldRepaint(covariant _ReaderSelectionHandlesPainter oldDelegate) {
    return oldDelegate.color != color ||
        oldDelegate.geometryBuilder != geometryBuilder ||
        oldDelegate.dragBuilder != dragBuilder;
  }
}

/// 滚动模式下的段落渲染（未分页时使用，应用配置的段落间距）
class ReaderParagraphs extends StatelessWidget {
  final String content;

  /// [P2-2] 分页快照章节索引/标题（滚动模式长按选区使用，避免冻结帧错章）
  final int? chapterIndex;
  final String? chapterTitle;

  final double fontSize;
  final double lineHeight;
  final double paragraphSpacing;
  final Color textColor;

  // [UI-fix v2.0.2 | 2026-08-06] 滚动回退渲染同步字距/字体 — Qoder
  final double letterSpacing;
  final String? fontFamily;

  // [UI-fix v2.0.3 | 2026-08-08] 长按选择文本开关 — Qoder
  final bool selectText;

  // [UI-fix v2.0.4 | 2026-08-08] 文字字重（对标原版 textBold）— Qoder
  final FontWeight? fontWeight;

  // [C3 斜体 | Qoder UI] 正文斜体（与 fontWeight 同链路透传，测量/渲染同参）
  final FontStyle? fontStyle;

  /// 本章高亮命中区间（UTF-16 章节全局偏移）
  ///
  /// [批32 P3-1] 允许乱序输入：build 入口用
  /// [sortHighlightMatchesByStart] 排序一次后复用。
  final List<HighlightMatch> highlightMatches;

  const ReaderParagraphs({
    super.key,
    required this.content,
    this.chapterIndex,
    this.chapterTitle,
    required this.fontSize,
    required this.lineHeight,
    required this.paragraphSpacing,
    required this.textColor,
    this.letterSpacing = 0.0,
    this.fontFamily,
    this.selectText = true,
    this.fontWeight,
    this.fontStyle,
    this.highlightMatches = const [],
  });

  @override
  Widget build(BuildContext context) {
    final paragraphs = content.split('\n');
    // [P2-2 低成本] 滚动模式无分页 ParagraphInfo：按行累计段首偏移，
    // 传给选区面板（此前恒 0，笔记/高亮锚点全落在章首）
    var offset = 0;
    // [批32 P3-1] 高亮命中列表在入口只排序/校验一次并复用：排序后段落
    // 按章节顺序推进时游标恒可用，避免每段重复 O(m) 校验（乱序时还会
    // 每段重排 → 整章 O(段落数 × m log m)）。
    final orderedMatches = sortHighlightMatchesByStart(highlightMatches);
    var matchCursor = 0;
    final items = <Widget>[];
    for (var index = 0; index < paragraphs.length; index++) {
      final raw = paragraphs[index];
      // [批32 P3-3] CRLF：`split('\n')` 会把 '\r' 留在段尾。分页路径
      // `_splitParagraphsWithOffsets` 按 `\r?\n` 切分并 trim，滚动回退
      // 渲染需剔除段尾 '\r'，否则跨段/跨行手动高亮会把不可见的 '\r'
      // 也包进样式（下划线/背景），与分页模式不一致。
      final hasCr = raw.endsWith('\r');
      final p = hasCr ? raw.substring(0, raw.length - 1) : raw;
      final leading = p.length - p.trimLeft().length;
      final paragraphChapterPos = offset + leading;
      // 段落正文在章节中的半开区间 [offset, offset + p.length)：段间
      // 换行符不在 p 内。CRLF 的 '\r' 已从 p 剔除，下方 offset 累计需
      // 同时补回被剔除的 1 个 '\r' 与 1 个 '\n'，否则后续段落偏移错位。
      final paragraphEnd = offset + p.length;
      if (orderedMatches.isNotEmpty) {
        while (matchCursor < orderedMatches.length &&
            orderedMatches[matchCursor].end <= offset) {
          matchCursor++;
        }
      }
      final hasHighlight =
          orderedMatches.isNotEmpty &&
          p.isNotEmpty &&
          matchCursor < orderedMatches.length &&
          orderedMatches[matchCursor].start < paragraphEnd;
      final paragraphStyle = TextStyle(
        fontSize: fontSize,
        height: lineHeight,
        color: textColor,
        fontFamily: fontFamily,
        // [UI-fix v2.0.4 | 2026-08-08] 字重接线 — Qoder
        fontWeight: fontWeight,
        fontStyle: fontStyle,
        letterSpacing: letterSpacing != 0 ? letterSpacing : null,
      );
      items.add(
        // [UI-fix v2.0.1 | 2026-08-06] 滚动回退模式段落级长按入口
        // [UI-fix v2.0.3 | 2026-08-08] selectText 关闭时移除长按入口 — Qoder
        GestureDetector(
          onLongPress: (p.trim().isEmpty || !selectText)
              ? null
              : () => TextSelectionPanel.show(
                  context,
                  text: p,
                  chapterPos: paragraphChapterPos,
                  chapterIndex: chapterIndex,
                  chapterTitle: chapterTitle,
                ),
          child: Padding(
            padding: EdgeInsets.only(bottom: paragraphSpacing),
            // 无命中的段落保持原 Text 渲染路径（不建多余 span 树）。
            child: hasHighlight
                ? Text.rich(
                    TextSpan(
                      children: buildHighlightedParagraphSpans(
                        text: p,
                        chapterStart: offset,
                        matches: orderedMatches,
                        searchFrom: matchCursor,
                        assumeStartSorted: true,
                      ),
                    ),
                    style: paragraphStyle,
                  )
                : Text(p.isEmpty ? ' ' : p, style: paragraphStyle),
          ),
        ),
      );
      // +1 为 '\n'；CRLF 段尾 '\r' 已被剔除，额外 +1 保持章节偏移对齐。
      offset += p.length + 1 + (hasCr ? 1 : 0);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: items,
    );
  }
}
