import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../../models/manga_config.dart';

/// 漫画阅读配置底栏面板（对齐原版滤镜 / 电子纸 / 页脚 Dialog 入口结构）
///
/// 视觉：iOS 风格分组列表 + 底栏 sheet；功能键名对齐 PreferKey。
/// — GapAudit P0-3 | 2026-08-12
class MangaConfigSheet extends StatefulWidget {
  final MangaColorFilterConfig colorFilter;
  final MangaFooterConfig footer;
  final bool enableEInk;
  final bool enableGray;
  final int eInkThreshold;
  final ValueChanged<MangaColorFilterConfig> onColorFilterChanged;
  final ValueChanged<MangaFooterConfig> onFooterChanged;
  final ValueChanged<bool> onEnableEInkChanged;
  final ValueChanged<bool> onEnableGrayChanged;
  final ValueChanged<int> onEInkThresholdChanged;

  const MangaConfigSheet({
    super.key,
    required this.colorFilter,
    required this.footer,
    required this.enableEInk,
    required this.enableGray,
    required this.eInkThreshold,
    required this.onColorFilterChanged,
    required this.onFooterChanged,
    required this.onEnableEInkChanged,
    required this.onEnableGrayChanged,
    required this.onEInkThresholdChanged,
  });

  static Future<void> show(
    BuildContext context, {
    required MangaColorFilterConfig colorFilter,
    required MangaFooterConfig footer,
    required bool enableEInk,
    required bool enableGray,
    required int eInkThreshold,
    required ValueChanged<MangaColorFilterConfig> onColorFilterChanged,
    required ValueChanged<MangaFooterConfig> onFooterChanged,
    required ValueChanged<bool> onEnableEInkChanged,
    required ValueChanged<bool> onEnableGrayChanged,
    required ValueChanged<int> onEInkThresholdChanged,
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
        onColorFilterChanged: onColorFilterChanged,
        onFooterChanged: onFooterChanged,
        onEnableEInkChanged: onEnableEInkChanged,
        onEnableGrayChanged: onEnableGrayChanged,
        onEInkThresholdChanged: onEInkThresholdChanged,
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
                '漫画设置',
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
                _section('页脚'),
                _card([
                  _switchTile(
                    title: '隐藏页脚',
                    value: _footer.hideFooter,
                    onChanged: (v) {
                      setState(() => _footer.hideFooter = v);
                      widget.onFooterChanged(_footer);
                    },
                  ),
                  _divider(),
                  _switchTile(
                    title: '隐藏章节名',
                    value: _footer.hideChapterName,
                    onChanged: (v) {
                      setState(() => _footer.hideChapterName = v);
                      widget.onFooterChanged(_footer);
                    },
                  ),
                  _divider(),
                  _switchTile(
                    title: '隐藏「章节」文案',
                    value: _footer.hideChapterLabel,
                    onChanged: (v) {
                      setState(() => _footer.hideChapterLabel = v);
                      widget.onFooterChanged(_footer);
                    },
                  ),
                  _divider(),
                  _switchTile(
                    title: '隐藏章节序号',
                    value: _footer.hideChapter,
                    onChanged: (v) {
                      setState(() => _footer.hideChapter = v);
                      widget.onFooterChanged(_footer);
                    },
                  ),
                  _divider(),
                  _switchTile(
                    title: '隐藏「页数」文案',
                    value: _footer.hidePageNumberLabel,
                    onChanged: (v) {
                      setState(() => _footer.hidePageNumberLabel = v);
                      widget.onFooterChanged(_footer);
                    },
                  ),
                  _divider(),
                  _switchTile(
                    title: '隐藏页数',
                    value: _footer.hidePageNumber,
                    onChanged: (v) {
                      setState(() => _footer.hidePageNumber = v);
                      widget.onFooterChanged(_footer);
                    },
                  ),
                  _divider(),
                  _switchTile(
                    title: '隐藏「总进度」文案',
                    value: _footer.hideProgressRatioLabel,
                    onChanged: (v) {
                      setState(() => _footer.hideProgressRatioLabel = v);
                      widget.onFooterChanged(_footer);
                    },
                  ),
                  _divider(),
                  _switchTile(
                    title: '隐藏总进度',
                    value: _footer.hideProgressRatio,
                    onChanged: (v) {
                      setState(() => _footer.hideProgressRatio = v);
                      widget.onFooterChanged(_footer);
                    },
                  ),
                  _divider(),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            '对齐',
                            // [深色主题 Batch A-1] #1C1C1E → onSurface
                            style: TextStyle(
                              fontSize: 16,
                              color: scheme.onSurface,
                            ),
                          ),
                        ),
                        CupertinoSlidingSegmentedControl<int>(
                          groupValue: _footer.footerOrientation ==
                                  MangaFooterConfig.alignCenter
                              ? MangaFooterConfig.alignCenter
                              : MangaFooterConfig.alignLeft,
                          children: const {
                            0: Padding(
                              padding: EdgeInsets.symmetric(horizontal: 10),
                              child: Text('靠左'),
                            ),
                            1: Padding(
                              padding: EdgeInsets.symmetric(horizontal: 10),
                              child: Text('居中'),
                            ),
                          },
                          onValueChanged: (v) {
                            if (v == null) return;
                            setState(() => _footer.footerOrientation = v);
                            widget.onFooterChanged(_footer);
                          },
                        ),
                      ],
                    ),
                  ),
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
