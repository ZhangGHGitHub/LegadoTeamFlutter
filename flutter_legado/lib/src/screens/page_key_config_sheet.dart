// 自定义翻页键设置（批4b）
//
// 参考 `PageKeySheet.kt:62-110` / `PageKeyConfigSheet.kt:62-110`：
// 上一页/下一页两组 keyCode、按下即追加（BACK/DEL 不录制）、清空/确定。
// 本实现用 ModalBottomSheet + chips；打开即 setKeyRecording(true)，
// 关闭/取消 setKeyRecording(false)。非 Android 仅提示、不录制。
//
// 编写：全栈工程师（批4b） ｜ 2026-11-04
import 'dart:async';

import 'package:flutter/material.dart';

import '../services/platform_bridge_service.dart';
import '../utils/page_key_codes.dart';
import 'reader_config_panel.dart';

class PageKeyConfigSheet extends StatefulWidget {
  final ReaderAdvancedConfig config;
  final ValueChanged<ReaderAdvancedConfig> onChanged;

  const PageKeyConfigSheet({
    super.key,
    required this.config,
    required this.onChanged,
  });

  static Future<void> show(
    BuildContext context, {
    required ReaderAdvancedConfig config,
    required ValueChanged<ReaderAdvancedConfig> onChanged,
  }) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withValues(alpha: 0.35),
      builder: (_) => PageKeyConfigSheet(config: config, onChanged: onChanged),
    );
  }

  @override
  State<PageKeyConfigSheet> createState() => _PageKeyConfigSheetState();
}

class _PageKeyConfigSheetState extends State<PageKeyConfigSheet> {
  late final ReaderAdvancedConfig _working = widget.config.copy();
  late List<int> _prev = PageKeyCodes.parse(widget.config.prevKeyCodes);
  late List<int> _next = PageKeyCodes.parse(widget.config.nextKeyCodes);
  StreamSubscription<int>? _recordSub;
  int _activeGroup = 0; // 0=prev 1=next

  bool get _supported =>
      PlatformBridgeService.instance.pageKeyCaptureSupported;

  @override
  void initState() {
    super.initState();
    final bridge = PlatformBridgeService.instance;
    _recordSub = bridge.pageKeyRecordStream.listen(_onRecordKey);
    if (_supported) unawaited(bridge.setKeyRecording(true));
  }

  @override
  void dispose() {
    unawaited(_recordSub?.cancel());
    if (_supported) {
      unawaited(PlatformBridgeService.instance.setKeyRecording(false));
    }
    super.dispose();
  }

  void _onRecordKey(int keyCode) {
    if (!mounted) return;
    final target = _activeGroup == 0 ? _prev : _next;
    final next = PageKeyCodes.append(PageKeyCodes.encode(target), keyCode);
    setState(() {
      if (_activeGroup == 0) {
        _prev = PageKeyCodes.parse(next);
      } else {
        _next = PageKeyCodes.parse(next);
      }
    });
  }

  void _confirm() {
    _working.prevKeyCodes = PageKeyCodes.encode(_prev);
    _working.nextKeyCodes = PageKeyCodes.encode(_next);
    widget.onChanged(_working.copy());
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      key: const ValueKey('page-key-sheet'),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: scheme.surfaceContainerLow,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 8, 8),
                child: Row(
                  children: [
                    const Icon(Icons.keyboard_outlined),
                    const SizedBox(width: 10),
                    Text(
                      '自定义翻页键',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const Spacer(),
                    IconButton(
                      tooltip: '关闭',
                      icon: const Icon(Icons.close),
                      onPressed: () => Navigator.pop(context),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: EdgeInsets.fromLTRB(
                  16,
                  0,
                  16,
                  16 + MediaQuery.viewPaddingOf(context).bottom,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _buildGroup(
                      index: 0,
                      title: '上一页按键',
                      codes: _prev,
                    ),
                    const SizedBox(height: 12),
                    _buildGroup(
                      index: 1,
                      title: '下一页按键',
                      codes: _next,
                    ),
                    const SizedBox(height: 12),
                    Text(
                      '按下要设置的按键（可多个）',
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                    if (!_supported) ...[
                      const SizedBox(height: 4),
                      Text(
                        '仅 Android 生效',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                    const SizedBox(height: 8),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        TextButton(
                          key: const ValueKey('page-key-cancel'),
                          onPressed: () => Navigator.pop(context),
                          child: const Text('取消'),
                        ),
                        const SizedBox(width: 8),
                        FilledButton(
                          key: const ValueKey('page-key-confirm'),
                          onPressed: _confirm,
                          child: const Text('确定'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildGroup({
    required int index,
    required String title,
    required List<int> codes,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final active = _activeGroup == index;
    return InkWell(
      key: ValueKey('page-key-group-$index'),
      onTap: () => setState(() => _activeGroup = index),
      borderRadius: BorderRadius.circular(16),
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          color: active
              ? scheme.primaryContainer.withValues(alpha: 0.35)
              : scheme.surfaceContainer,
          border: Border.all(
            color: active ? scheme.primary : scheme.outlineVariant,
            width: active ? 1.5 : 1,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(title, style: Theme.of(context).textTheme.titleSmall),
                const Spacer(),
                TextButton(
                  key: ValueKey('page-key-clear-$index'),
                  onPressed: () => setState(() {
                    if (index == 0) {
                      _prev = [];
                    } else {
                      _next = [];
                    }
                  }),
                  child: const Text('清空'),
                ),
              ],
            ),
            if (codes.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(
                  '未设置',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              )
            else
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final code in codes)
                    InputChip(
                      key: ValueKey('page-key-chip-$code'),
                      label: Text('$code'),
                      visualDensity: VisualDensity.compact,
                      onDeleted: () => setState(() {
                        if (index == 0) {
                          _prev = [..._prev]..remove(code);
                        } else {
                          _next = [..._next]..remove(code);
                        }
                      }),
                    ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}
