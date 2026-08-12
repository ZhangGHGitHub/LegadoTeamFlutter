import 'dart:io';

import 'package:flutter/material.dart';

import '../services/bottom_bar_skin_format.dart';
import '../services/bottom_bar_skin_service.dart';
import '../widgets/ios_widgets.dart';

/// 底栏皮肤槽位分配（对齐 BottomBarSkinAssignActivity）
///
/// 从暂存 session 的任意图片中，为 4 个 Tab 各选「选中(必)/未选(可空)」后保存。
class BottomBarSkinAssignScreen extends StatefulWidget {
  const BottomBarSkinAssignScreen({
    super.key,
    required this.sessionId,
    this.preferredName = '',
    this.editName,
  });

  final String sessionId;
  final String preferredName;
  final String? editName;

  @override
  State<BottomBarSkinAssignScreen> createState() =>
      _BottomBarSkinAssignScreenState();
}

class _AssignRow {
  _AssignRow({
    required this.slot,
    required this.label,
  });

  final String slot;
  final String label;
  File? selected;
  File? normal;
}

class _BottomBarSkinAssignScreenState extends State<BottomBarSkinAssignScreen> {
  final _nameCtrl = TextEditingController();
  final _service = BottomBarSkinService.instance;

  List<File> _palette = const [];
  late List<_AssignRow> _rows;
  bool _loading = true;
  bool _saving = false;
  bool _saved = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _nameCtrl.text = widget.preferredName;
    _rows = BottomBarSkinFormat.mappedSlots
        .map(
          (slot) => _AssignRow(
            slot: slot,
            label: BottomBarSkinFormat.slotLabels[slot] ?? slot,
          ),
        )
        .toList();
    _load();
  }

  @override
  void dispose() {
    if (!_saved && !_saving) {
      _service.discardSession(widget.sessionId);
    }
    _nameCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final imgs = await _service.stagingImages(widget.sessionId);
      if (imgs.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('暂存中无可用图片')),
          );
          Navigator.pop(context);
        }
        return;
      }
      final prefill = BottomBarSkinService.buildPrefill(imgs);
      for (final row in _rows) {
        final p = prefill[row.slot];
        row.selected = p?.selected;
        row.normal = p?.normal;
      }
      if (!mounted) return;
      setState(() {
        _palette = imgs;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '$e';
      });
    }
  }

  Future<void> _save() async {
    if (_saving) return;
    final assigns = <String, BottomBarSkinSlotAssign>{};
    for (final row in _rows) {
      final sel = row.selected;
      if (sel != null) {
        assigns[row.slot] = BottomBarSkinSlotAssign(
          selected: sel,
          normal: row.normal,
        );
      }
    }
    if (assigns.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请至少为一项选择「选中」图标')),
      );
      return;
    }
    setState(() => _saving = true);
    try {
      final name = await _service.saveFromAssign(
        desiredName: _nameCtrl.text.trim(),
        assigns: assigns,
        sessionId: widget.sessionId,
        editName: widget.editName,
      );
      _saved = true;
      if (!mounted) return;
      Navigator.pop(context, name);
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('保存失败：$e')),
      );
    }
  }

  Future<void> _openPalette({
    required bool allowClear,
    required void Function(File?) onPick,
  }) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) {
        final width = MediaQuery.sizeOf(ctx).width;
        final span = (width / 72).floor().clamp(2, 4);
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  '选择图片',
                  style: Theme.of(ctx).textTheme.titleMedium,
                ),
                if (allowClear)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton(
                      onPressed: () {
                        Navigator.pop(ctx);
                        onPick(null);
                      },
                      child: const Text('清除'),
                    ),
                  ),
                const SizedBox(height: 8),
                ConstrainedBox(
                  constraints: BoxConstraints(
                    maxHeight: MediaQuery.sizeOf(ctx).height * 0.5,
                  ),
                  child: GridView.builder(
                    shrinkWrap: true,
                    itemCount: _palette.length,
                    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: span,
                      mainAxisSpacing: 8,
                      crossAxisSpacing: 8,
                    ),
                    itemBuilder: (context, i) {
                      final f = _palette[i];
                      return InkWell(
                        onTap: () {
                          Navigator.pop(ctx);
                          onPick(f);
                        },
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: Image.file(
                            f,
                            fit: BoxFit.contain,
                            errorBuilder: (_, error, stack) =>
                                const Icon(Icons.broken_image_outlined),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _thumb(File? file) {
    if (file != null) {
      return Image.file(
        file,
        width: 44,
        height: 44,
        fit: BoxFit.contain,
        errorBuilder: (_, error, stack) =>
            const Icon(Icons.broken_image_outlined, size: 28),
      );
    }
    return Icon(
      Icons.add,
      size: 28,
      color: Theme.of(context).colorScheme.outline,
    );
  }

  Widget _slotButton({
    required String caption,
    required File? file,
    required bool enabled,
    required VoidCallback onTap,
  }) {
    return Opacity(
      opacity: enabled ? 1 : 0.4,
      child: Column(
        children: [
          Text(caption, style: const TextStyle(fontSize: 11)),
          const SizedBox(height: 4),
          InkWell(
            onTap: enabled ? onTap : null,
            borderRadius: BorderRadius.circular(8),
            child: SizedBox(
              width: 44,
              height: 44,
              child: Center(child: _thumb(file)),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final editing = widget.editName != null;
    return Scaffold(
      appBar: AppBar(
        title: Text(editing ? '编辑' : '分配图标'),
        actions: [
          TextButton(
            onPressed: _saving || _loading ? null : _save,
            child: _saving
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('保存'),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : IosGroupedBody(
              child: ListView(
                children: [
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text(
                        _error!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ),
                  const IosSectionHeader('名称'),
                  IosGroup(
                    children: [
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: TextField(
                          controller: _nameCtrl,
                          decoration: const InputDecoration(
                            border: InputBorder.none,
                            hintText: '图集名称',
                          ),
                        ),
                      ),
                    ],
                  ),
                  const IosSectionHeader('槽位'),
                  IosGroup(
                    children: [
                      for (var i = 0; i < _rows.length; i++) ...[
                        if (i > 0) const Divider(height: 1),
                        Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 10,
                          ),
                          child: Row(
                            children: [
                              Expanded(
                                child: Text(
                                  _rows[i].label,
                                  style: Theme.of(context).textTheme.bodyLarge,
                                ),
                              ),
                              _slotButton(
                                caption: '选中',
                                file: _rows[i].selected,
                                enabled: true,
                                onTap: () => _openPalette(
                                  allowClear: _rows[i].selected != null,
                                  onPick: (f) {
                                    setState(() {
                                      _rows[i].selected = f;
                                      if (f == null) _rows[i].normal = null;
                                    });
                                  },
                                ),
                              ),
                              const SizedBox(width: 16),
                              _slotButton(
                                caption: '未选',
                                file: _rows[i].normal,
                                enabled: _rows[i].selected != null,
                                onTap: () => _openPalette(
                                  allowClear: _rows[i].normal != null,
                                  onPick: (f) {
                                    setState(() => _rows[i].normal = f);
                                  },
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ],
                  ),
                  const IosSectionFooter(
                    '点选缩略图从压缩包图片中分配。每个底栏项至少需要「选中」图；'
                    '「未选」可空（运行时用选中图半透明近似）。',
                  ),
                ],
              ),
            ),
    );
  }
}
