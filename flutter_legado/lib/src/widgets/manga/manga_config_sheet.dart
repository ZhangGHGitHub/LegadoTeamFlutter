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
    final bottom = MediaQuery.paddingOf(context).bottom;
    return Container(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * 0.88,
      ),
      decoration: const BoxDecoration(
        color: Color(0xFFF2F2F7),
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
              color: const Color(0xFFC7C7CC),
              borderRadius: BorderRadius.circular(3),
            ),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(20, 14, 20, 8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                '漫画设置',
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF1C1C1E),
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
                        const Expanded(
                          child: Text(
                            '对齐',
                            style: TextStyle(
                              fontSize: 16,
                              color: Color(0xFF1C1C1E),
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
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 16, 4, 8),
      child: Text(
        title.toUpperCase(),
        style: const TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w500,
          color: Color(0xFF8E8E93),
          letterSpacing: 0.2,
        ),
      ),
    );
  }

  Widget _card(List<Widget> children) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(children: children),
    );
  }

  Widget _divider() => const Divider(height: 1, indent: 16, color: Color(0xFFE5E5EA));

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
              style: const TextStyle(fontSize: 12, color: Color(0xFF8E8E93)),
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
                  style: const TextStyle(fontSize: 16, color: Color(0xFF1C1C1E)),
                ),
              ),
              Text(
                label,
                style: const TextStyle(fontSize: 14, color: Color(0xFF8E8E93)),
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
