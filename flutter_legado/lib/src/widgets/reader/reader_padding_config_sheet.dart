import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;

import '../../screens/reader_config_panel.dart';
import '../ios_widgets.dart';

/// 页面边距配置（对标原版 PaddingConfigDialog + dialog_read_padding.xml）
///
/// - 页眉/正文/页脚三 Tab
/// - 四向 ± 步进（DetailSeekBar 语义：上/下 0-400，左/右 0-100）
/// - 左右联动开关、页眉/页脚显示分隔线开关
class ReaderPaddingConfigSheet extends ConsumerStatefulWidget {
  final ReaderAdvancedConfig config;
  final ValueChanged<ReaderAdvancedConfig>? onChanged;

  const ReaderPaddingConfigSheet({
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
        initialChildSize: 0.55,
        minChildSize: 0.4,
        maxChildSize: 0.85,
        builder: (_, scrollController) => SingleChildScrollView(
          controller: scrollController,
          child: ReaderPaddingConfigSheet(
            config: config,
            onChanged: onChanged,
          ),
        ),
      ),
    );
  }

  @override
  ConsumerState<ReaderPaddingConfigSheet> createState() =>
      _ReaderPaddingConfigSheetState();
}

class _ReaderPaddingConfigSheetState
    extends ConsumerState<ReaderPaddingConfigSheet> {
  late ReaderAdvancedConfig _config = widget.config.copy();
  PaddingRegion _region = PaddingRegion.body;
  bool _lockLr = false;

  @override
  void initState() {
    super.initState();
    _syncLockLrFromRegion();
  }

  void _syncLockLrFromRegion() {
    final left = _paddingFor(_region, _Side.left);
    final right = _paddingFor(_region, _Side.right);
    _lockLr = left == right;
  }

  void _commit() {
    unawaited(_config.save());
    widget.onChanged?.call(_config.copy());
    ref.read(readerAdvConfigProvider.notifier).apply(_config.copy());
    setState(() {});
  }

  double _paddingFor(PaddingRegion region, _Side side) {
    switch (region) {
      case PaddingRegion.header:
        switch (side) {
          case _Side.top:
            return _config.headerPaddingTop;
          case _Side.bottom:
            return _config.headerPaddingBottom;
          case _Side.left:
            return _config.headerPaddingLeft;
          case _Side.right:
            return _config.headerPaddingRight;
        }
      case PaddingRegion.body:
        switch (side) {
          case _Side.top:
            return _config.pageMarginTop;
          case _Side.bottom:
            return _config.pageMarginBottom;
          case _Side.left:
            return _config.pageMarginLeft;
          case _Side.right:
            return _config.pageMarginRight;
        }
      case PaddingRegion.footer:
        switch (side) {
          case _Side.top:
            return _config.footerPaddingTop;
          case _Side.bottom:
            return _config.footerPaddingBottom;
          case _Side.left:
            return _config.footerPaddingLeft;
          case _Side.right:
            return _config.footerPaddingRight;
        }
    }
  }

  void _setPadding(PaddingRegion region, _Side side, double value) {
    switch (region) {
      case PaddingRegion.header:
        switch (side) {
          case _Side.top:
            _config.headerPaddingTop = value;
          case _Side.bottom:
            _config.headerPaddingBottom = value;
          case _Side.left:
            _config.headerPaddingLeft = value;
          case _Side.right:
            _config.headerPaddingRight = value;
        }
      case PaddingRegion.body:
        switch (side) {
          case _Side.top:
            _config.pageMarginTop = value;
          case _Side.bottom:
            _config.pageMarginBottom = value;
          case _Side.left:
            _config.pageMarginLeft = value;
          case _Side.right:
            _config.pageMarginRight = value;
        }
      case PaddingRegion.footer:
        switch (side) {
          case _Side.top:
            _config.footerPaddingTop = value;
          case _Side.bottom:
            _config.footerPaddingBottom = value;
          case _Side.left:
            _config.footerPaddingLeft = value;
          case _Side.right:
            _config.footerPaddingRight = value;
        }
    }
  }

  void _adjust(_Side side, int delta) {
    final max = (side == _Side.left || side == _Side.right) ? 100.0 : 400.0;
    var value = (_paddingFor(_region, side) + delta).clamp(0.0, max);
    _setPadding(_region, side, value);
    if (_lockLr && (side == _Side.left || side == _Side.right)) {
      final other = side == _Side.left ? _Side.right : _Side.left;
      _setPadding(_region, other, value);
    }
    _commit();
  }

  void _resetRegion() {
    for (final side in _Side.values) {
      final key = switch (side) {
        _Side.top => 'top',
        _Side.bottom => 'bottom',
        _Side.left => 'left',
        _Side.right => 'right',
      };
      _setPadding(
        _region,
        side,
        ReaderAdvancedConfig.defaultPaddingFor(_region, key),
      );
    }
    _syncLockLrFromRegion();
    _commit();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Center(child: IosGrabber()),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: Text('页面边距',
                      style: theme.textTheme.titleMedium),
                ),
                IconButton(
                  tooltip: '恢复默认',
                  onPressed: _resetRegion,
                  icon: const Icon(Icons.restore),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                _regionTab(PaddingRegion.header, '页眉'),
                const SizedBox(width: 4),
                _regionTab(PaddingRegion.body, '正文'),
                const SizedBox(width: 4),
                _regionTab(PaddingRegion.footer, '页脚'),
              ],
            ),
            const SizedBox(height: 12),
            _seekRow('上边距', _Side.top, Icons.arrow_upward),
            _seekRow('下边距', _Side.bottom, Icons.arrow_downward),
            _seekRow('左边距', _Side.left, Icons.arrow_back),
            _seekRow('右边距', _Side.right, Icons.arrow_forward),
            SwitchListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: const Text('左右边距联动'),
              value: _lockLr,
              onChanged: (v) => setState(() => _lockLr = v),
            ),
            if (_region == PaddingRegion.header)
              SwitchListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: const Text('显示页眉分隔线'),
                value: _config.showHeaderLine,
                onChanged: (v) {
                  _config.showHeaderLine = v;
                  _commit();
                },
              )
            else if (_region == PaddingRegion.footer)
              SwitchListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: const Text('显示页脚分隔线'),
                value: _config.showFooterLine,
                onChanged: (v) {
                  _config.showFooterLine = v;
                  _commit();
                },
              ),
          ],
        ),
      ),
    );
  }

  Widget _regionTab(PaddingRegion region, String label) {
    final selected = _region == region;
    final theme = Theme.of(context);
    return Expanded(
      child: Material(
        color: selected
            ? theme.colorScheme.primary
            : Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: BorderSide(color: theme.colorScheme.outlineVariant),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: () {
            setState(() {
              _region = region;
              _syncLockLrFromRegion();
            });
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Text(
              label,
              textAlign: TextAlign.center,
              style: theme.textTheme.labelLarge?.copyWith(
                color: selected
                    ? theme.colorScheme.onPrimary
                    : theme.colorScheme.onSurface,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _seekRow(String label, _Side side, IconData icon) {
    final value = _paddingFor(_region, side).round();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Icon(icon, size: 18),
          const SizedBox(width: 8),
          SizedBox(width: 56, child: Text(label)),
          IconButton(
            visualDensity: VisualDensity.compact,
            onPressed: () => _adjust(side, -1),
            icon: const Icon(Icons.remove_circle_outline),
          ),
          SizedBox(
            width: 48,
            child: Text(
              '$value',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleSmall,
            ),
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            onPressed: () => _adjust(side, 1),
            icon: const Icon(Icons.add_circle_outline),
          ),
        ],
      ),
    );
  }
}

enum _Side { top, bottom, left, right }
