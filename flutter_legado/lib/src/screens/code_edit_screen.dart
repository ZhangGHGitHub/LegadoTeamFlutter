import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'curl_analyze_url_sheet.dart';

/// 规则/代码全屏编辑（对标原版 `CodeEditActivity` 最小可用）
///
/// 能力：等宽编辑、保存回写、查找、cURL↔AnalyzeUrl 转换。
/// 视觉：Apple 式冷静顶栏 + 系统灰编辑区，不做语法高亮/主题切换。
class CodeEditScreen extends StatefulWidget {
  final String title;
  final String initialText;
  final int cursorPosition;
  final bool writable;

  const CodeEditScreen({
    super.key,
    required this.title,
    required this.initialText,
    this.cursorPosition = 0,
    this.writable = true,
  });

  /// 打开编辑器；保存返回文本，取消返回 `null`
  static Future<String?> open(
    BuildContext context, {
    required String title,
    required String initialText,
    int cursorPosition = 0,
    bool writable = true,
  }) {
    return Navigator.of(context).push<String>(
      MaterialPageRoute(
        builder: (_) => CodeEditScreen(
          title: title,
          initialText: initialText,
          cursorPosition: cursorPosition,
          writable: writable,
        ),
      ),
    );
  }

  @override
  State<CodeEditScreen> createState() => _CodeEditScreenState();
}

class _CodeEditScreenState extends State<CodeEditScreen> {
  late final TextEditingController _controller;
  late final FocusNode _focus;
  final _findCtrl = TextEditingController();
  bool _showFind = false;
  int _findIndex = -1;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialText);
    _focus = FocusNode();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final pos = widget.cursorPosition.clamp(0, _controller.text.length);
      _controller.selection = TextSelection.collapsed(offset: pos);
      _focus.requestFocus();
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    _findCtrl.dispose();
    super.dispose();
  }

  bool get _dirty => _controller.text != widget.initialText;

  Future<void> _handlePop() async {
    if (!widget.writable || !_dirty) {
      Navigator.of(context).pop();
      return;
    }
    final leave = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('退出'),
        content: const Text('内容尚未保存，确定退出？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('退出'),
          ),
        ],
      ),
    );
    if (leave == true && mounted) Navigator.of(context).pop();
  }

  void _save() {
    if (!widget.writable) {
      Navigator.of(context).pop();
      return;
    }
    Navigator.of(context).pop(_controller.text);
  }

  Future<void> _openCurlConverter() async {
    final sel = _controller.selection;
    final text = _controller.text;
    var seed = '';
    if (sel.isValid && !sel.isCollapsed) {
      seed = sel.textInside(text);
    }
    final inserted = await CurlAnalyzeUrlSheet.show(
      context,
      initialText: seed,
      canInsert: widget.writable,
    );
    if (inserted == null || !mounted || !widget.writable) return;
    _insertText(inserted);
  }

  void _insertText(String value) {
    final text = _controller.text;
    final sel = _controller.selection;
    final start = sel.isValid ? sel.start : text.length;
    final end = sel.isValid ? sel.end : text.length;
    final next = text.replaceRange(start, end, value);
    _controller.value = TextEditingValue(
      text: next,
      selection: TextSelection.collapsed(offset: start + value.length),
    );
    setState(() {});
  }

  void _findNext() {
    final q = _findCtrl.text;
    if (q.isEmpty) return;
    final text = _controller.text;
    final from = (_findIndex + 1).clamp(0, text.length);
    var idx = text.indexOf(q, from);
    if (idx < 0) idx = text.indexOf(q);
    if (idx < 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('未找到')),
      );
      return;
    }
    _findIndex = idx;
    _controller.selection = TextSelection(
      baseOffset: idx,
      extentOffset: idx + q.length,
    );
    _focus.requestFocus();
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _handlePop();
      },
      child: Scaffold(
        backgroundColor: cs.surface,
        appBar: AppBar(
          title: Text(widget.title),
          leading: IconButton(
            icon: const Icon(Icons.close),
            onPressed: _handlePop,
          ),
          actions: [
            if (widget.writable)
              TextButton(
                onPressed: _save,
                child: const Text('保存'),
              ),
            PopupMenuButton<String>(
              tooltip: '更多',
              position: PopupMenuPosition.under,
              onSelected: (v) async {
                switch (v) {
                  case 'find':
                    setState(() => _showFind = !_showFind);
                  case 'curl':
                    await _openCurlConverter();
                  case 'copy_all':
                    await Clipboard.setData(
                      ClipboardData(text: _controller.text),
                    );
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('已复制全部')),
                      );
                    }
                }
              },
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'find', child: Text('查找')),
                PopupMenuItem(value: 'curl', child: Text('cURL 转换')),
                PopupMenuItem(value: 'copy_all', child: Text('复制全部')),
              ],
            ),
          ],
        ),
        body: Column(
          children: [
            if (_showFind)
              Material(
                color: cs.surfaceContainerHighest.withValues(alpha: 0.55),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
                  child: Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _findCtrl,
                          decoration: const InputDecoration(
                            hintText: '查找…',
                            isDense: true,
                            border: OutlineInputBorder(),
                          ),
                          onSubmitted: (_) => _findNext(),
                        ),
                      ),
                      IconButton(
                        tooltip: '下一个',
                        onPressed: _findNext,
                        icon: const Icon(Icons.keyboard_arrow_down),
                      ),
                      IconButton(
                        tooltip: '关闭',
                        onPressed: () => setState(() => _showFind = false),
                        icon: const Icon(Icons.close),
                      ),
                    ],
                  ),
                ),
              ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: cs.surfaceContainerHighest.withValues(alpha: 0.35),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: TextField(
                    controller: _controller,
                    focusNode: _focus,
                    readOnly: !widget.writable,
                    maxLines: null,
                    expands: true,
                    keyboardType: TextInputType.multiline,
                    textAlignVertical: TextAlignVertical.top,
                    style: const TextStyle(
                      fontFamily: 'Menlo',
                      fontFamilyFallback: ['Consolas', 'monospace'],
                      fontSize: 14,
                      height: 1.4,
                    ),
                    decoration: const InputDecoration(
                      border: InputBorder.none,
                      contentPadding: EdgeInsets.all(14),
                    ),
                    onChanged: (_) => setState(() {}),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
