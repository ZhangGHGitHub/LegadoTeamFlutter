import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;

import '../../l10n/app_strings.dart';
import '../../screens/reader_config_panel.dart';
import '../ios_widgets.dart';

/// 页眉/页脚提示项（对标原版 ReadTipConfig.tipValues）
class ReadTipOption {
  final int value;
  final String label;
  const ReadTipOption(this.value, this.label);
}

/// 阅读提示信息配置（对标原版 TipConfigDialog + dialog_tip_config.xml）
class ReaderTipConfigSheet extends ConsumerStatefulWidget {
  final ReaderAdvancedConfig config;
  final ValueChanged<ReaderAdvancedConfig>? onChanged;

  const ReaderTipConfigSheet({
    super.key,
    required this.config,
    this.onChanged,
  });

  static Future<void> show(
    BuildContext context, {
    required ReaderAdvancedConfig config,
    ValueChanged<ReaderAdvancedConfig>? onChanged,
  }) {
    return showModalBottomSheet<void>(      showDragHandle: false,

      context: context,
      isScrollControlled: true,
      builder: (_) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.72,
        minChildSize: 0.45,
        maxChildSize: 0.92,
        builder: (_, scrollController) => SingleChildScrollView(
          controller: scrollController,
          child: ReaderTipConfigSheet(
            config: config,
            onChanged: onChanged,
          ),
        ),
      ),
    );
  }

  @override
  ConsumerState<ReaderTipConfigSheet> createState() =>
      _ReaderTipConfigSheetState();
}

class _ReaderTipConfigSheetState extends ConsumerState<ReaderTipConfigSheet> {
  late final ReaderAdvancedConfig _config = widget.config.copy();

  List<ReadTipOption> get _tipOptions => [
    ReadTipOption(0, AppStrings.tipNone),
    ReadTipOption(7, AppStrings.bookNameTip),
    ReadTipOption(1, AppStrings.chapterNameTip),
    ReadTipOption(2, AppStrings.timeTip),
    ReadTipOption(3, AppStrings.batteryIconTip),
    ReadTipOption(10, AppStrings.batteryPercentTip),
    ReadTipOption(4, AppStrings.pageNumberTip),
    ReadTipOption(5, AppStrings.readProgressTip),
    ReadTipOption(11, AppStrings.chapterProgressTip),
    ReadTipOption(6, AppStrings.pageAndProgressTip),
    ReadTipOption(8, AppStrings.timeAndBatteryTip),
    ReadTipOption(9, AppStrings.timeAndBatteryPercentTip),
  ];

  Map<int, String> get _modeOptions => {
    0: AppStrings.hideWhenStatusBarShown,
    1: AppStrings.showLabel,
    2: AppStrings.hideLabel,
  };

  void _commit() {
    unawaited(_config.save());
    widget.onChanged?.call(_config.copy());
    ref.read(readerAdvConfigProvider.notifier).apply(_config.copy());
    setState(() {});
  }

  String _tipLabel(int value) {
    for (final o in _tipOptions) {
      if (o.value == value) return o.label;
    }
    return AppStrings.tipNone;
  }

  Future<void> _pickTip(
    String title,
    int current,
    ValueChanged<int> onPick,
  ) async {
    final picked = await showDialog<int>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text(title),
        children: [
          for (final o in _tipOptions)
            ListTile(
              title: Text(o.label),
              trailing: current == o.value
                  ? Icon(Icons.check, color: Theme.of(ctx).colorScheme.primary)
                  : null,
              onTap: () => Navigator.pop(ctx, o.value),
            ),
        ],
      ),
    );
    if (picked != null) onPick(picked);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Center(child: IosGrabber()),
            const SizedBox(height: 12),
            Text(AppStrings.readingTipInfo,
                style: theme.textTheme.titleMedium),
            const SizedBox(height: 12),
            Text(AppStrings.bodyTitleLabel, style: theme.textTheme.titleSmall),
            SegmentedButton<int>(
              segments: [
                ButtonSegment(
                    value: 0, label: Text(AppStrings.alignLeft)),
                ButtonSegment(
                    value: 1, label: Text(AppStrings.alignCenter)),
                ButtonSegment(value: 2, label: Text(AppStrings.hideLabel)),
              ],
              selected: {_config.titleMode.clamp(0, 2)},
              onSelectionChanged: (sel) {
                _config.titleMode = sel.first;
                _commit();
              },
            ),
            _stepRow(AppStrings.titleSizeLabel, _config.titleSize, 0, 20, (v) {
              _config.titleSize = v;
              _commit();
            }),
            _stepRow(
                AppStrings.titleTopSpacing, _config.titleTopSpacing, 0, 100, (v) {
              _config.titleTopSpacing = v;
              _commit();
            }),
            _stepRow(
                AppStrings.titleBottomSpacing,
                _config.titleBottomSpacing,
                0,
                100,
                (v) {
              _config.titleBottomSpacing = v;
              _commit();
            }),
            const Divider(height: 24),
            Text(AppStrings.headerLabel, style: theme.textTheme.titleSmall),
            _modeRow(AppStrings.headerDisplay, _config.headerMode, (v) {
              _config.headerMode = v;
              _commit();
            }),
            _tipRow(AppStrings.headerLeft, _config.tipHeaderLeft, (v) {
              _config.tipHeaderLeft = v;
              _commit();
            }),
            _tipRow(AppStrings.headerMiddle, _config.tipHeaderMiddle, (v) {
              _config.tipHeaderMiddle = v;
              _commit();
            }),
            _tipRow(AppStrings.headerRight, _config.tipHeaderRight, (v) {
              _config.tipHeaderRight = v;
              _commit();
            }),
            const Divider(height: 24),
            Text(AppStrings.footerLabel, style: theme.textTheme.titleSmall),
            _modeRow(AppStrings.footerDisplay, _config.footerMode, (v) {
              _config.footerMode = v;
              _commit();
            }),
            _tipRow(AppStrings.footerLeft, _config.tipFooterLeft, (v) {
              _config.tipFooterLeft = v;
              _commit();
            }),
            _tipRow(AppStrings.footerMiddle, _config.tipFooterMiddle, (v) {
              _config.tipFooterMiddle = v;
              _commit();
            }),
            _tipRow(AppStrings.footerRight, _config.tipFooterRight, (v) {
              _config.tipFooterRight = v;
              _commit();
            }),
            const SizedBox(height: 8),
            Text(
              AppStrings.legacyStatusBarHint,
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            SwitchListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: Text(AppStrings.showBattery),
              value: _config.showBattery,
              onChanged: (v) {
                _config.showBattery = v;
                _commit();
              },
            ),
            SwitchListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: Text(AppStrings.showTime),
              value: _config.showTime,
              onChanged: (v) {
                _config.showTime = v;
                _commit();
              },
            ),
            SwitchListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: Text(AppStrings.showProgress),
              value: _config.showProgress,
              onChanged: (v) {
                _config.showProgress = v;
                _commit();
              },
            ),
            SwitchListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: Text(AppStrings.showChapterName),
              value: _config.showChapterName,
              onChanged: (v) {
                _config.showChapterName = v;
                _commit();
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _modeRow(String label, int current, ValueChanged<int> onPick) {
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      title: Text(label),
      trailing: Text(_modeOptions[current.clamp(0, 2)] ?? AppStrings.showLabel),
      onTap: () async {
        final picked = await showDialog<int>(
          context: context,
          builder: (ctx) => SimpleDialog(
            title: Text(label),
            children: [
              for (final e in _modeOptions.entries)
                ListTile(
                  title: Text(e.value),
                  trailing: current == e.key
                      ? Icon(Icons.check,
                          color: Theme.of(ctx).colorScheme.primary)
                      : null,
                  onTap: () => Navigator.pop(ctx, e.key),
                ),
            ],
          ),
        );
        if (picked != null) onPick(picked);
      },
    );
  }

  Widget _tipRow(String label, int current, ValueChanged<int> onPick) {
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      title: Text(label),
      trailing: Text(_tipLabel(current)),
      onTap: () => _pickTip(label, current, onPick),
    );
  }

  Widget _stepRow(
    String label,
    int value,
    int min,
    int max,
    ValueChanged<int> onChanged,
  ) {
    return Row(
      children: [
        Expanded(child: Text(label)),
        IconButton(
          visualDensity: VisualDensity.compact,
          onPressed: value > min ? () => onChanged(value - 1) : null,
          icon: const Icon(Icons.remove_circle_outline),
        ),
        Text('$value'),
        IconButton(
          visualDensity: VisualDensity.compact,
          onPressed: value < max ? () => onChanged(value + 1) : null,
          icon: const Icon(Icons.add_circle_outline),
        ),
      ],
    );
  }
}
