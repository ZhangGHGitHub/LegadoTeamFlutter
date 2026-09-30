import 'package:flutter/material.dart';

import '../../models/manga_config.dart';
import '../../screens/reader_comic/manga_auto_read.dart';
import '../../screens/reader_comic/manga_page_scale_type.dart';
import '../../screens/reader_comic/manga_scroll_mode.dart';

/// 漫画阅读配置底栏面板（对齐原版滤镜 / 电子纸 / 页脚 Dialog 入口结构）
///
/// 视觉：iOS 风格分组列表 + 底栏 sheet；功能键名对齐 PreferKey。
/// — GapAudit P0-3 | 2026-08-12
///
/// [P4-3 M3 修4] 按用户截图/参考版 MangaSettingsPanel 重组：
/// - 标题「漫画设置」→「漫画阅读设置」；
/// - 阅读模式：M2 下拉 → 5 按钮组（单页式（从左到右/从右到左/从上到下）/
///   条漫/条漫（页面有空隙），Wrap 换行、选中 primaryContainer 高亮，
///   对应 mangaScrollMode 1/2/3/4/5）；单页式保留页面适配下拉，
///   条漫新增「侧边留白」滑杆（0..45%，仅 isWebtoon 显示，新键
///   MangaConfigKeys.mangaSidePadding 持久化，漫画屏条漫渲染消费）；
/// - 页脚：M2 8 开关 + 对齐 segmented control → 页脚设置区
///   （左对齐/居中/隐藏页脚 三按钮快捷行 + 页脚预览条，按当前
///   footerConfig buildLabel 渲染样例；复用既有键，零新增字段）；
/// - 自动翻页卡/显示效果卡/色彩滤镜卡保留不动。
/// 「长按设为全局默认」语义登记不做（需书级/全局设置分层，残余差异
/// 见 P4-3 M3 汇报）。
class MangaConfigSheet extends StatefulWidget {
  final MangaColorFilterConfig colorFilter;
  final MangaFooterConfig footer;
  final bool enableEInk;
  final bool enableGray;
  final int eInkThreshold;
  /// [P4-3 E1] 翻页模式（对齐参考版 MangaScrollMode）
  final int scrollMode;
  final ValueChanged<MangaColorFilterConfig> onColorFilterChanged;
  final ValueChanged<MangaFooterConfig> onFooterChanged;
  final ValueChanged<bool> onEnableEInkChanged;
  final ValueChanged<bool> onEnableGrayChanged;
  final ValueChanged<int> onEInkThresholdChanged;
  /// [P4-3 E1] 翻页模式变更
  final ValueChanged<int> onScrollModeChanged;

  /// [P4-3 E3] 自动翻页开关当前值（会话态；null = 不渲染自动翻页区块）
  final bool? autoReadEnabled;

  /// [P4-3 E3] 自动翻页速度档 1..15（当前值）
  final int? autoReadSpeed;

  /// [P4-3 E3] 自动翻页开关变更（非 null 时渲染区块）
  final ValueChanged<bool>? onAutoReadChanged;

  /// [P4-3 E3] 自动翻页速度档变更（随开关显隐，见原版 L572-575）
  final ValueChanged<int>? onAutoReadSpeedChanged;

  /// [P4-3 E2] 分页适配类型 0..5（当前值；null = 默认 0）
  final int? pageScaleType;

  /// [P4-3 E2] 分页适配类型变更（非 null 且当前为单页模式时渲染下拉）
  final ValueChanged<int>? onPageScaleTypeChanged;

  /// [P4-3 M3 修4] 条漫侧边留白百分比 0..45（当前值；null = 默认 0）
  final int? sidePadding;

  /// [P4-3 M3 修4] 侧边留白变更（非 null 且当前为条漫模式时渲染滑杆，
  /// 对齐参考版 MangaSettingsPanel L339-400：isWebtoon → SettingSlider
  /// sidePaddingPercent 0..45；单页式不显示，保留页面适配下拉）
  final ValueChanged<int>? onSidePaddingChanged;

  const MangaConfigSheet({
    super.key,
    required this.colorFilter,
    required this.footer,
    required this.enableEInk,
    required this.enableGray,
    required this.eInkThreshold,
    required this.scrollMode,
    required this.onColorFilterChanged,
    required this.onFooterChanged,
    required this.onEnableEInkChanged,
    required this.onEnableGrayChanged,
    required this.onEInkThresholdChanged,
    required this.onScrollModeChanged,
    this.autoReadEnabled,
    this.autoReadSpeed,
    this.onAutoReadChanged,
    this.onAutoReadSpeedChanged,
    this.pageScaleType,
    this.onPageScaleTypeChanged,
    this.sidePadding,
    this.onSidePaddingChanged,
  });

  static Future<void> show(
    BuildContext context, {
    required MangaColorFilterConfig colorFilter,
    required MangaFooterConfig footer,
    required bool enableEInk,
    required bool enableGray,
    required int eInkThreshold,
    required int scrollMode,
    required ValueChanged<MangaColorFilterConfig> onColorFilterChanged,
    required ValueChanged<MangaFooterConfig> onFooterChanged,
    required ValueChanged<bool> onEnableEInkChanged,
    required ValueChanged<bool> onEnableGrayChanged,
    required ValueChanged<int> onEInkThresholdChanged,
    required ValueChanged<int> onScrollModeChanged,
    // [P4-3 E3] 自动翻页（可选；不传则不渲染区块，既有调用方不受影响）
    bool? autoReadEnabled,
    int? autoReadSpeed,
    ValueChanged<bool>? onAutoReadChanged,
    ValueChanged<int>? onAutoReadSpeedChanged,
    // [P4-3 E2] 分页适配类型（可选；不传则不渲染下拉，既有调用方不受影响）
    int? pageScaleType,
    ValueChanged<int>? onPageScaleTypeChanged,
    // [P4-3 M3 修4] 条漫侧边留白（可选；不传则不渲染滑杆，既有调用方不受影响）
    int? sidePadding,
    ValueChanged<int>? onSidePaddingChanged,
  }) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => MangaConfigSheet(
        colorFilter: colorFilter,
        footer: footer,
        enableEInk: enableEInk,
        enableGray: enableGray,
        eInkThreshold: eInkThreshold,
        scrollMode: scrollMode,
        onColorFilterChanged: onColorFilterChanged,
        onFooterChanged: onFooterChanged,
        onEnableEInkChanged: onEnableEInkChanged,
        onEnableGrayChanged: onEnableGrayChanged,
        onEInkThresholdChanged: onEInkThresholdChanged,
        onScrollModeChanged: onScrollModeChanged,
        autoReadEnabled: autoReadEnabled,
        autoReadSpeed: autoReadSpeed,
        onAutoReadChanged: onAutoReadChanged,
        onAutoReadSpeedChanged: onAutoReadSpeedChanged,
        pageScaleType: pageScaleType,
        onPageScaleTypeChanged: onPageScaleTypeChanged,
        sidePadding: sidePadding,
        onSidePaddingChanged: onSidePaddingChanged,
      ),
    );
  }

  @override
  State<MangaConfigSheet> createState() => _MangaConfigSheetState();
}

class _MangaConfigSheetState extends State<MangaConfigSheet> {
  late MangaColorFilterConfig _filter;
  late MangaFooterConfig _footer;
  late bool _eInk;
  late bool _gray;
  late int _threshold;
  /// [P4-3 E1] 翻页模式
  late int _scrollMode;

  /// [P4-3 E3] 自动翻页开关（区块仅在上游提供回调时渲染）
  late bool _autoRead;

  /// [P4-3 E3] 自动翻页速度档
  late int _autoReadSpeed;

  /// [P4-3 E2] 分页适配类型 0..5
  late int _pageScaleType;

  /// [P4-3 M3 修4] 条漫侧边留白百分比 0..45
  late int _sidePadding;

  /// 是否渲染「自动翻页」区块（上游显式接线时才渲染，
  /// 保证既有未接线的 sheet 用法/测试不受影响）
  bool get _showAutoReadSection => widget.onAutoReadChanged != null;

  /// 是否渲染「页面适配」下拉：上游接线且当前为单页模式才渲染
  /// （对齐参考版 L372-386：条漫模式改显侧边距滑杆；
  /// 面板内切回单页模式后本项随 [_scrollMode] 变化自动出现）
  bool get _showPageScale =>
      widget.onPageScaleTypeChanged != null &&
      MangaScrollModes.isPaged(_scrollMode);

  /// [P4-3 M3 修4] 是否渲染「侧边留白」滑杆：上游接线且当前为条漫
  /// （对齐参考版 L339-400：isWebtoon → SettingSlider 0..45；
  /// 面板内切到条漫模式后本项随 [_scrollMode] 变化自动出现）
  bool get _showSidePadding =>
      widget.onSidePaddingChanged != null &&
      MangaScrollModes.isWebtoon(_scrollMode);

  @override
  void initState() {
    super.initState();
    _filter = MangaColorFilterConfig(
      r: widget.colorFilter.r,
      g: widget.colorFilter.g,
      b: widget.colorFilter.b,
      a: widget.colorFilter.a,
      l: widget.colorFilter.l,
    );
    _footer = MangaFooterConfig.fromJson(widget.footer.toJson());
    _eInk = widget.enableEInk;
    _gray = widget.enableGray;
    _threshold = widget.eInkThreshold;
    _scrollMode = widget.scrollMode;
    _autoRead = widget.autoReadEnabled ?? false;
    _autoReadSpeed = widget.autoReadSpeed ?? MangaAutoRead.defaultValue;
    _pageScaleType = widget.pageScaleType ?? MangaPageScaleType.defaultValue;
    _sidePadding = (widget.sidePadding ?? 0).clamp(0, 45);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final bottom = MediaQuery.paddingOf(context).bottom;
    return Container(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * 0.88,
      ),
      decoration: BoxDecoration(
        // [深色主题 Batch A-1] iOS 硬编码浅色调色板 #F2F2F7 → scheme 槽位
        // （亮色 def = #E2E2E2，暗色 def = #646464，跟随主题自动切换）
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.vertical(top: Radius.circular(14)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: 8),
          Container(
            width: 36,
            height: 5,
            decoration: BoxDecoration(
              // [深色主题 Batch A-1] 拖动把手 #C7C7CC → outlineVariant（中性描边槽位）
              color: scheme.outlineVariant,
              borderRadius: BorderRadius.circular(3),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 14, 20, 8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                // [P4-3 M3 修4] 标题对齐参考版 MangaSettingsPanel
                // 「漫画阅读设置」（M2 旧称「漫画设置」）
                '漫画阅读设置',
                // [深色主题 Batch A-1] 标题 #1C1C1E → onSurface
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w600,
                  color: scheme.onSurface,
                ),
              ),
            ),
          ),
          Flexible(
            child: ListView(
              padding: EdgeInsets.fromLTRB(16, 0, 16, 16 + bottom),
              children: [
                // [P4-3 M3 修4] 阅读模式：5 按钮组（单页式 ×3 + 条漫 ×2，
                // Wrap 换行，选中 primaryContainer 高亮，对齐用户截图；
                // 替代 M2「翻页模式」下拉）+ 模式条件行：单页式保留页面适配
                // 下拉、条漫新增侧边留白滑杆（0..45%，对齐参考版
                // SettingSlider sidePaddingPercent 仅 isWebtoon 显示）
                _section('阅读模式'),
                _card([
                  _modeButtonGroup(),
                  if (_showPageScale) ...[
                    _divider(),
                    _dropdownTile(
                      title: '页面适配',
                      value: _pageScaleType,
                      options: MangaPageScaleType.options,
                      labelOf: MangaPageScaleType.labelOf,
                      onChanged: (v) {
                        setState(() => _pageScaleType = v);
                        widget.onPageScaleTypeChanged!(v);
                      },
                    ),
                  ],
                  // [P4-3 M3 修4] 侧边留白（条漫专属；参考版 fraction =
                  // 1 - p*2/100 ⇔ 每侧 padding = p% × 视口宽，漫画屏
                  // 条漫渲染路径消费此值）
                  if (_showSidePadding) ...[
                    _divider(),
                    _sliderTile(
                      title: '侧边留白',
                      value: _sidePadding.toDouble(),
                      min: 0,
                      max: 45,
                      label: '$_sidePadding%',
                      onChanged: (v) {
                        final rounded = v.round().clamp(0, 45);
                        if (rounded == _sidePadding) return;
                        setState(() => _sidePadding = rounded);
                        widget.onSidePaddingChanged!(rounded);
                      },
                    ),
                  ],
                ]),
                // [P4-3 E3] 自动翻页（对齐参考版 AutoReadSettingsContent
                // MangaSettingsPanel L755-767：开关 + 速度滑杆 1..15；
                // 速度项随开关显隐，对齐原版 ReadMangaActivity L572-575）
                if (_showAutoReadSection) ...[
                  _section('自动翻页'),
                  _card([
                    _switchTile(
                      title: '自动翻页',
                      subtitle: '单页式定时翻页；条漫定时滚动',
                      value: _autoRead,
                      onChanged: (v) {
                        setState(() => _autoRead = v);
                        widget.onAutoReadChanged!(v);
                      },
                    ),
                    if (_autoRead) ...[
                      _divider(),
                      _sliderTile(
                        title: '自动速度',
                        value: _autoReadSpeed.toDouble(),
                        min: MangaAutoRead.minSpeed.toDouble(),
                        max: MangaAutoRead.maxSpeed.toDouble(),
                        label: '$_autoReadSpeed 档',
                        onChanged: (v) {
                          final rounded = v
                              .round()
                              .clamp(MangaAutoRead.minSpeed,
                                  MangaAutoRead.maxSpeed);
                          if (rounded == _autoReadSpeed) return;
                          setState(() => _autoReadSpeed = rounded);
                          widget.onAutoReadSpeedChanged?.call(_autoReadSpeed);
                        },
                      ),
                    ],
                  ]),
                ],
                _section('显示效果'),
                _card([
                  _switchTile(
                    title: '灰度',
                    value: _gray,
                    onChanged: (v) {
                      setState(() {
                        _gray = v;
                        if (v) _eInk = false;
                      });
                      widget.onEnableGrayChanged(_gray);
                      if (v) widget.onEnableEInkChanged(false);
                    },
                  ),
                  _divider(),
                  _switchTile(
                    title: '电子纸',
                    subtitle: '灰度近似；阈值已持久化',
                    value: _eInk,
                    onChanged: (v) {
                      setState(() {
                        _eInk = v;
                        if (v) _gray = false;
                      });
                      widget.onEnableEInkChanged(_eInk);
                      if (v) widget.onEnableGrayChanged(false);
                    },
                  ),
                  if (_eInk) ...[
                    _divider(),
                    _sliderTile(
                      title: '电子纸阈值',
                      value: _threshold.toDouble(),
                      min: 0,
                      max: 255,
                      label: '$_threshold',
                      onChanged: (v) {
                        setState(() => _threshold = v.round());
                        widget.onEInkThresholdChanged(_threshold);
                      },
                    ),
                  ],
                ]),
                _section('色彩滤镜'),
                _card([
                  _sliderTile(
                    title: '亮度',
                    value: _filter.l.toDouble(),
                    min: 0,
                    max: 255,
                    label: '${_filter.l}',
                    onChanged: (v) {
                      setState(() => _filter.l = v.round());
                      widget.onColorFilterChanged(_filter);
                    },
                  ),
                  _divider(),
                  _sliderTile(
                    title: 'R',
                    value: _filter.r.toDouble(),
                    min: 0,
                    max: 255,
                    label: '${_filter.r}',
                    onChanged: (v) {
                      setState(() => _filter.r = v.round());
                      widget.onColorFilterChanged(_filter);
                    },
                  ),
                  _divider(),
                  _sliderTile(
                    title: 'G',
                    value: _filter.g.toDouble(),
                    min: 0,
                    max: 255,
                    label: '${_filter.g}',
                    onChanged: (v) {
                      setState(() => _filter.g = v.round());
                      widget.onColorFilterChanged(_filter);
                    },
                  ),
                  _divider(),
                  _sliderTile(
                    title: 'B',
                    value: _filter.b.toDouble(),
                    min: 0,
                    max: 255,
                    label: '${_filter.b}',
                    onChanged: (v) {
                      setState(() => _filter.b = v.round());
                      widget.onColorFilterChanged(_filter);
                    },
                  ),
                  _divider(),
                  _sliderTile(
                    title: 'A',
                    value: _filter.a.toDouble(),
                    min: 0,
                    max: 255,
                    label: '${_filter.a}',
                    onChanged: (v) {
                      setState(() => _filter.a = v.round());
                      widget.onColorFilterChanged(_filter);
                    },
                  ),
                ]),
                // [P4-3 M3 修4] 页脚设置区（对齐用户截图快捷行：三按钮
                // 左对齐/居中/隐藏页脚 + 页脚预览条，替代 M2 8 开关 +
                // 对齐 segmented control；复用既有键 footerOrientation /
                // hideFooter，字段零新增；「长按设为全局默认」语义登记
                // 不做——需书级/全局设置分层，残余差异汇报注明）
                _section('页脚设置'),
                _card([
                  _footerQuickRow(),
                  _divider(),
                  _footerPreview(),
                ]),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _section(String title) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 16, 4, 8),
      child: Text(
        title.toUpperCase(),
        // [深色主题 Batch A-1] 分组标题 #8E8E93 → onSurfaceVariant
        style: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w500,
          color: scheme.onSurfaceVariant,
          letterSpacing: 0.2,
        ),
      ),
    );
  }

  Widget _card(List<Widget> children) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        // [深色主题 Batch A-1] 白卡 → surface（暗色 def = #424242）
        color: scheme.surface,
        borderRadius: BorderRadius.circular(12),
      ),
      clipBehavior: Clip.antiAlias,
      // [深色主题 Batch A-1] 内层透明 Material：框架 debug 断言
      // 「ListTile background color or ink splashes may be invisible」要求
      // ListTile 的最近 Material 祖先之间不得出现带背景的 DecoratedBox
      // （本卡片即此类容器）；按框架提示包一层零视觉影响的透明 Material
      //（卡片底色仍由外层 Container 的 scheme 槽位决定，外观不变）
      child: Material(
        type: MaterialType.transparency,
        child: Column(children: children),
      ),
    );
  }

  // [深色主题 Batch A-1] 分隔线 #E5E5EA → outlineVariant
  Widget _divider() {
    final scheme = Theme.of(context).colorScheme;
    return Divider(height: 1, indent: 16, color: scheme.outlineVariant);
  }

  /// [P4-3 E1] 下拉选择行（标题 + 选项下拉；对齐参考版阅读模式下拉）
  Widget _dropdownTile({
    required String title,
    required int value,
    required List<int> options,
    required String Function(int) labelOf,
    required ValueChanged<int> onChanged,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
      child: Row(
        children: [
          Expanded(
            child: Text(
              title,
              // 标题 #1C1C1E → onSurface（深色主题槽位）
              style: TextStyle(fontSize: 16, color: scheme.onSurface),
            ),
          ),
          DropdownButton<int>(
            value: options.contains(value) ? value : options.first,
            items: options
                .map((o) => DropdownMenuItem<int>(
                      value: o,
                      child: Text(
                        labelOf(o),
                        style: TextStyle(
                          fontSize: 14,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ))
                .toList(),
            // DropdownButton.onChanged 为 ValueChanged<int?>?（可为 null）
            onChanged: (v) {
              if (v != null) onChanged(v);
            },
          ),
        ],
      ),
    );
  }

  /// [P4-3 M3 修4] 阅读模式 5 按钮组（单页式 ×3 + 条漫 ×2，按值 1..5
  /// 顺序，Wrap 换行；选中 = primaryContainer 底 + onPrimaryContainer
  /// 字 w600，未选 = 透明底 + onSurfaceVariant 字，对齐用户截图形态）
  Widget _modeButtonGroup() {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: MangaScrollModes.buttonOptions.map((mode) {
          final selected = mode == _scrollMode;
          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () {
              if (mode == _scrollMode) return;
              setState(() => _scrollMode = mode);
              widget.onScrollModeChanged(mode);
            },
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 120),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              decoration: BoxDecoration(
                color: selected ? scheme.primaryContainer : Colors.transparent,
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(
                MangaScrollModes.buttonLabelOf(mode),
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                  color: selected
                      ? scheme.onPrimaryContainer
                      : scheme.onSurfaceVariant,
                ),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }

  /// [P4-3 M3 修4] 页脚快捷行（三按钮：左对齐/居中/隐藏页脚；
  /// 选中态 = primaryContainer 高亮，同 [_modeButtonGroup] 形态；
  /// 点「隐藏页脚」置 hideFooter，点对齐键置对应 orientation 并
  /// 取消隐藏——三键互斥可切换，全部复用既有 footer 键）
  Widget _footerQuickRow() {
    final scheme = Theme.of(context).colorScheme;
    final isCenter =
        _footer.footerOrientation == MangaFooterConfig.alignCenter;
    final entries = <(String, bool, VoidCallback)>[
      (
        '左对齐',
        !isCenter && !_footer.hideFooter,
        () {
          setState(() {
            _footer.footerOrientation = MangaFooterConfig.alignLeft;
            _footer.hideFooter = false;
          });
          widget.onFooterChanged(_footer);
        },
      ),
      (
        '居中',
        isCenter && !_footer.hideFooter,
        () {
          setState(() {
            _footer.footerOrientation = MangaFooterConfig.alignCenter;
            _footer.hideFooter = false;
          });
          widget.onFooterChanged(_footer);
        },
      ),
      (
        '隐藏页脚',
        _footer.hideFooter,
        () {
          setState(() => _footer.hideFooter = !_footer.hideFooter);
          widget.onFooterChanged(_footer);
        },
      ),
    ];
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: entries.map((e) {
        final selected = e.$2;
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: e.$3,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: BoxDecoration(
              color: selected ? scheme.primaryContainer : Colors.transparent,
              borderRadius: BorderRadius.circular(20),
            ),
            child: Text(
              e.$1,
              style: TextStyle(
                fontSize: 14,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                color: selected
                    ? scheme.onPrimaryContainer
                    : scheme.onSurfaceVariant,
              ),
            ),
          ),
        );
      }).toList(),
    );
  }

  /// [P4-3 M3 修4] 页脚预览条（按当前 footerConfig 用 buildLabel 渲染
  /// 样例文案：hideFooter → 「页脚已隐藏」提示；否则样例
  /// chapterName=第三话 / 第 1/45 章 / 第 4/30 页 的组装结果，
  /// 对齐随 footerOrientation 左/居中；内容为空时显占位提示）
  Widget _footerPreview() {
    final scheme = Theme.of(context).colorScheme;
    final label = _footer.buildLabel(
      chapterName: '第三话',
      chapterIndex: 0,
      chapterSize: 45,
      pageIndex: 3,
      imageCount: 30,
    );
    final text = _footer.hideFooter
        ? '页脚已隐藏'
        : (label.isEmpty ? '（页脚内容为空）' : label);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(
          text,
          textAlign: _footer.footerOrientation ==
                  MangaFooterConfig.alignCenter
              ? TextAlign.center
              : TextAlign.left,
          style: TextStyle(
            fontSize: 12,
            color: scheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }

  Widget _switchTile({
    required String title,
    String? subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return SwitchListTile.adaptive(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16),
      title: Text(title, style: const TextStyle(fontSize: 16)),
      subtitle: subtitle == null
          ? null
          : Text(
              subtitle,
              // [深色主题 Batch A-1] 副标题 #8E8E93 → onSurfaceVariant
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
      value: value,
      onChanged: onChanged,
    );
  }

  Widget _sliderTile({
    required String title,
    required double value,
    required double min,
    required double max,
    required String label,
    required ValueChanged<double> onChanged,
  }) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  // [深色主题 Batch A-1] 滑杆标题 #1C1C1E → onSurface
                  style: TextStyle(
                    fontSize: 16,
                    color: Theme.of(context).colorScheme.onSurface,
                  ),
                ),
              ),
              Text(
                label,
                // [深色主题 Batch A-1] 滑杆数值 #8E8E93 → onSurfaceVariant
                style: TextStyle(
                  fontSize: 14,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
          Slider(
            value: value.clamp(min, max),
            min: min,
            max: max,
            onChanged: onChanged,
          ),
        ],
      ),
    );
  }
}
