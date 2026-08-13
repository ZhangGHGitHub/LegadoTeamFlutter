import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;

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
    return showModalBottomSheet<void>(
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
  late ReaderAdvancedConfig _config = widget.config.copy();

  static const _tipOptions = [
    ReadTipOption(0, '无'),
    ReadTipOption(7, '书名'),
    ReadTipOption(1, '章节名'),
    ReadTipOption(2, '时间'),
    ReadTipOption(3, '电量图标'),
    ReadTipOption(10, '电量百分比'),
    ReadTipOption(4, '页码'),
    ReadTipOption(5, '阅读进度'),
    ReadTipOption(11, '章节进度'),
    ReadTipOption(6, '页码+进度'),
    ReadTipOption(8, '时间+电量'),
    ReadTipOption(9, '时间+电量%'),
  ];

  static const _modeOptions = {
    0: '状态栏显示时隐藏',
    1: '显示',
    2: '隐藏',
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
    return '无';
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
            Text('阅读提示信息', style: theme.textTheme.titleMedium),
            const SizedBox(height: 12),
            Text('正文标题', style: theme.textTheme.titleSmall),
            SegmentedButton<int>(
              segments: const [
                ButtonSegment(value: 0, label: Text('居左')),
                ButtonSegment(value: 1, label: Text('居中')),
                ButtonSegment(value: 2, label: Text('隐藏')),
              ],
              selected: {_config.titleMode.clamp(0, 2)},
              onSelectionChanged: (sel) {
                _config.titleMode = sel.first;
                _commit();
              },
            ),
            _stepRow('标题字号', _config.titleSize, 0, 20, (v) {
              _config.titleSize = v;
              _commit();
            }),
            _stepRow('标题上边距', _config.titleTopSpacing, 0, 100, (v) {
              _config.titleTopSpacing = v;
              _commit();
            }),
            _stepRow('标题下边距', _config.titleBottomSpacing, 0, 100, (v) {
              _config.titleBottomSpacing = v;
              _commit();
            }),
            const Divider(height: 24),
            Text('页眉', style: theme.textTheme.titleSmall),
            _modeRow('页眉显示', _config.headerMode, (v) {
              _config.headerMode = v;
              _commit();
            }),
            _tipRow('页眉左', _config.tipHeaderLeft, (v) {
              _config.tipHeaderLeft = v;
              _commit();
            }),
            _tipRow('页眉中', _config.tipHeaderMiddle, (v) {
              _config.tipHeaderMiddle = v;
              _commit();
            }),
            _tipRow('页眉右', _config.tipHeaderRight, (v) {
              _config.tipHeaderRight = v;
              _commit();
            }),
            const Divider(height: 24),
            Text('页脚', style: theme.textTheme.titleSmall),
            _modeRow('页脚显示', _config.footerMode, (v) {
              _config.footerMode = v;
              _commit();
            }),
            _tipRow('页脚左', _config.tipFooterLeft, (v) {
              _config.tipFooterLeft = v;
              _commit();
            }),
            _tipRow('页脚中', _config.tipFooterMiddle, (v) {
              _config.tipFooterMiddle = v;
              _commit();
            }),
            _tipRow('页脚右', _config.tipFooterRight, (v) {
              _config.tipFooterRight = v;
              _commit();
            }),
            const SizedBox(height: 8),
            Text(
              '兼容旧版：下方开关同步控制顶部状态条（隐藏工具栏时）',
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            SwitchListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: const Text('显示电量'),
              value: _config.showBattery,
              onChanged: (v) {
                _config.showBattery = v;
                _commit();
              },
            ),
            SwitchListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: const Text('显示时间'),
              value: _config.showTime,
              onChanged: (v) {
                _config.showTime = v;
                _commit();
              },
            ),
            SwitchListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: const Text('显示进度'),
              value: _config.showProgress,
              onChanged: (v) {
                _config.showProgress = v;
                _commit();
              },
            ),
            SwitchListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: const Text('显示章节名'),
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
      trailing: Text(_modeOptions[current.clamp(0, 2)] ?? '显示'),
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
