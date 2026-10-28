import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;

import '../../screens/reader_config_panel.dart';
import '../ios_widgets.dart';

/// 页面边距配置（对标原版 PaddingConfigDialog + dialog_read_padding.xml）
///
/// - 页眉/正文/页脚三 Tab
/// - 四向「滑块 + 数值 + 加减」（DetailSeekBar 语义：上/下 0-400，左/右 0-100）
/// - 左右联动开关（三 Tab 通用）、正文「上下边距联动」开关
///   （对标原版 `ReadBookConfig.paddingTopBottomLinked`，仅正文 Tab 显示）
/// - 页眉/页脚显示分隔线开关
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
    return showModalBottomSheet<void>(      showDragHandle: false,

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
  late final ReaderAdvancedConfig _config = widget.config.copy();
  PaddingRegion _region = PaddingRegion.body;
  bool _lockLr = false;

  /// 正文上下边距联动（批33：对标原版 paddingTopBottomLinked）
  bool _lockTb = false;

  /// 拖动实时预览节流计时器（批33b，~150ms 推送一次共享 Provider）
  Timer? _livePreviewTimer;

  /// 拖动预览节流间隔（对齐原版 `bodyThrottle` 的拖动节流语义）
  static const _livePreviewInterval = Duration(milliseconds: 150);

  @override
  void initState() {
    super.initState();
    _syncLockLrFromRegion();
    _lockTb = _config.paddingTopBottomLinked;
  }

  @override
  void dispose() {
    _livePreviewTimer?.cancel();
    super.dispose();
  }

  void _syncLockLrFromRegion() {
    final left = _paddingFor(_region, _Side.left);
    final right = _paddingFor(_region, _Side.right);
    _lockLr = left == right;
  }

  void _commit() {
    // 提交前丢弃在途预览，避免节流回调在落盘后再推一次旧快照
    _cancelLivePreview();
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

  /// 一次写入并处理联动镜像（批33）
  ///
  /// 联动口径对齐原版 `PaddingConfigDialog.applyEdit`：
  /// - 左右联动：左/右任一变化镜像另一侧（三 Tab 均生效）；
  /// - 上下联动：仅正文 Tab，上/下任一变化镜像另一侧。
  void _applyWithLink(_Side side, double value) {
    _setPadding(_region, side, value);
    if (_lockLr && (side == _Side.left || side == _Side.right)) {
      final other = side == _Side.left ? _Side.right : _Side.left;
      _setPadding(_region, other, value);
    }
    if (_lockTb &&
        _region == PaddingRegion.body &&
        (side == _Side.top || side == _Side.bottom)) {
      final other = side == _Side.top ? _Side.bottom : _Side.top;
      _setPadding(_region, other, value);
    }
  }

  /// 步进 / 滑条终值：写配置 + 立即落盘并推送共享 Provider
  void _adjust(_Side side, int delta) {
    final value = (_paddingFor(_region, side) + delta).clamp(0.0, _maxFor(side));
    _applyWithLink(side, value);
    _commit();
  }

  /// 滑条拖动中：更新内存并重绘；按 ~150ms 节流推送共享 Provider 做
  /// 实时预览（不落盘、不触发 onChanged，避免每帧写盘）
  ///
  /// [批33b] 对齐原版 `PaddingConfigDialog.liveApply` + `bodyThrottle`：
  /// 拖动期间正文实时跟随，但写盘/回调只在 `onChangeEnd`（[_commitValue]）
  /// 统一执行一次。
  void _dragValue(_Side side, double value) {
    _applyWithLink(side, value.clamp(0.0, _maxFor(side)));
    setState(() {});
    _scheduleLivePreview();
  }

  /// 滑条终值：落盘并推送（对齐原版 onChanged 最终提交语义）
  void _commitValue(_Side side, double value) {
    _applyWithLink(side, value.clamp(0.0, _maxFor(side)));
    _commit();
  }

  /// 节流调度：在途计时器存在时仅更新内存，不再叠加定时器
  void _scheduleLivePreview() {
    if (_livePreviewTimer != null) return;
    _livePreviewTimer = Timer(_livePreviewInterval, () {
      _livePreviewTimer = null;
      if (!mounted) return;
      // 推送触发时刻的最新内存配置（拖动仍在继续时下个 _dragValue 会
      // 重新排程，保证拖动过程约每 150ms 刷新一次预览）
      ref.read(readerAdvConfigProvider.notifier).apply(_config.copy());
    });
  }

  /// 取消在途预览（提交/销毁时调用）
  void _cancelLivePreview() {
    _livePreviewTimer?.cancel();
    _livePreviewTimer = null;
  }

  /// 单侧上限：上/下 0-400，左/右 0-100（沿用既有范围，避免行为回退）
  double _maxFor(_Side side) =>
      (side == _Side.left || side == _Side.right) ? 100.0 : 400.0;

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
    // 对齐原版 askResetRegion：重置正文时联动开关也回到默认（关闭）
    if (_region == PaddingRegion.body) {
      _config.paddingTopBottomLinked = false;
      _lockTb = false;
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
            _padRow('上边距', _Side.top, Icons.arrow_upward),
            _padRow('下边距', _Side.bottom, Icons.arrow_downward),
            _padRow('左边距', _Side.left, Icons.arrow_back),
            _padRow('右边距', _Side.right, Icons.arrow_forward),
            SwitchListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: const Text('左右边距联动'),
              value: _lockLr,
              onChanged: (v) => setState(() => _lockLr = v),
            ),
            // 上下联动仅正文 Tab 可见（对齐原版 swLockTb 的 Region.BODY 判定）
            if (_region == PaddingRegion.body)
              SwitchListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: const Text('上下边距联动'),
                value: _lockTb,
                onChanged: (v) {
                  _config.paddingTopBottomLinked = v;
                  _lockTb = v;
                  // 开启即以上边距为准镜像下边距（对齐原版
                  // finalApply(Side.TOP, dsbTop.progress)）
                  if (v) {
                    _setPadding(
                      PaddingRegion.body,
                      _Side.bottom,
                      _paddingFor(PaddingRegion.body, _Side.top),
                    );
                  }
                  _commit();
                },
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

  /// 单侧边距行：图标 + 标签 + 滑条 + 数值 + 加减
  ///
  /// [批33] 由「仅 ±1 步进」升级为「滑块 + 步进器」（参考版
  /// TinySliderSettingItem 形态）：滑条负责快速调节，加减保留 1 步微调；
  /// 范围仍为上/下 0-400、左/右 0-100（不改变既有行为）。
  Widget _padRow(String label, _Side side, IconData icon) {
    final max = _maxFor(side);
    final value = _paddingFor(_region, side).clamp(0.0, max);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Icon(icon, size: 18),
          const SizedBox(width: 8),
          SizedBox(width: 48, child: Text(label)),
          Expanded(
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 3,
                thumbShape:
                    const RoundSliderThumbShape(enabledThumbRadius: 6),
                overlayShape:
                    const RoundSliderOverlayShape(overlayRadius: 12),
                // 0-400 档位若画刻度会过密，参考版滑条形态不带刻度
                tickMarkShape: SliderTickMarkShape.noTickMark,
              ),
              child: Slider(
                value: value,
                min: 0,
                max: max,
                divisions: max.round(),
                label: value.round().toString(),
                onChanged: (v) => _dragValue(side, v),
                onChangeEnd: (v) => _commitValue(side, v),
              ),
            ),
          ),
          SizedBox(
            width: 34,
            child: Text(
              value.round().toString(),
              textAlign: TextAlign.end,
              style: Theme.of(context).textTheme.titleSmall,
            ),
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            tooltip: '减少',
            onPressed: () => _adjust(side, -1),
            icon: const Icon(Icons.remove_circle_outline),
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            tooltip: '增加',
            onPressed: () => _adjust(side, 1),
            icon: const Icon(Icons.add_circle_outline),
          ),
        ],
      ),
    );
  }
}

enum _Side { top, bottom, left, right }
