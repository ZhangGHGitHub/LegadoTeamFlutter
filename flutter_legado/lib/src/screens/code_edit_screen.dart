import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import '../widgets/app_scaffold.dart';
import '../widgets/legado_app_bar.dart';
import 'package:flutter/services.dart';

import '../l10n/app_strings.dart';
import 'curl_analyze_url_sheet.dart';

/// 代码编辑结果（对齐 CodeEditActivity RESULT_ACTION_*）
class CodeEditResult {
  const CodeEditResult(this.text, {this.debugRequested = false});

  final String text;
  final bool debugRequested;
}

/// 规则/代码全屏编辑（对标原版 `CodeEditActivity` 最小可用）
///
/// 能力：等宽编辑、保存回写、查找、cURL↔AnalyzeUrl 转换、可选「调试」。
/// 视觉：Apple 式冷静顶栏 + 系统灰编辑区，不做语法高亮/主题切换。
class CodeEditScreen extends StatefulWidget {
  final String title;
  final String initialText;
  final int cursorPosition;
  final bool writable;
  final bool showDebugSource;

  const CodeEditScreen({
    super.key,
    required this.title,
    required this.initialText,
    this.cursorPosition = 0,
    this.writable = true,
    this.showDebugSource = false,
  });

  /// 打开编辑器；保存返回文本，取消返回 `null`
  static Future<String?> open(
    BuildContext context, {
    required String title,
    required String initialText,
    int cursorPosition = 0,
    bool writable = true,
  }) async {
    final result = await openExtended(
      context,
      title: title,
      initialText: initialText,
      cursorPosition: cursorPosition,
      writable: writable,
    );
    return result?.text;
  }

  /// 带调试动作的打开方式（JS 书源用）
  static Future<CodeEditResult?> openExtended(
    BuildContext context, {
    required String title,
    required String initialText,
    int cursorPosition = 0,
    bool writable = true,
    bool showDebugSource = false,
  }) {
    return Navigator.of(context).push<CodeEditResult>(
      MaterialPageRoute(
        builder: (_) => CodeEditScreen(
          title: title,
          initialText: initialText,
          cursorPosition: cursorPosition,
          writable: writable,
          showDebugSource: showDebugSource,
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
        title: Text(AppStrings.exitLabel),
        content: Text(AppStrings.codeEditUnsavedConfirm),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(AppStrings.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(AppStrings.exitLabel),
          ),
        ],
      ),
    );
    if (leave == true && mounted) Navigator.of(context).pop();
  }

  void _save({bool debug = false}) {
    if (!widget.writable) {
      Navigator.of(context).pop();
      return;
    }
    Navigator.of(context).pop(
      CodeEditResult(_controller.text, debugRequested: debug),
    );
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
        SnackBar(content: Text(AppStrings.codeEditNotFound)),
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
      child: AppScaffold(
        // [GLOBALCOMP B4] 页壳统一：AppScaffold（行为等价直通 Scaffold）
        // 背景色 cs.surface 与主题默认一致：冗余参数按裁决原样保留（色值不变）
        backgroundColor: cs.surface,
        topBar: LegadoAppBar(
          title: Text(widget.title),
          leading: IconButton(
            icon: const Icon(Symbols.close_rounded),
            onPressed: _handlePop,
          ),
          actions: [
            if (widget.writable && widget.showDebugSource)
              IconButton(
                tooltip: AppStrings.debugLabel,
                icon: const Icon(Symbols.bug_report_rounded),
                onPressed: () => _save(debug: true),
              ),
            if (widget.writable)
              TextButton(
                onPressed: () => _save(),
                child: Text(AppStrings.save),
              ),
            PopupMenuButton<String>(
              tooltip: AppStrings.moreActions,
              position: PopupMenuPosition.under,
              onSelected: (v) async {
                switch (v) {
                  case 'find':
                    setState(() => _showFind = !_showFind);
                  case 'curl':
                    await _openCurlConverter();
                  case 'debug':
                    _save(debug: true);
                  case 'copy_all':
                    final messenger = ScaffoldMessenger.of(context);
                    await Clipboard.setData(
                      ClipboardData(text: _controller.text),
                    );
                    if (mounted) {
                      messenger.showSnackBar(
                        SnackBar(content: Text(AppStrings.codeEditCopiedAll)),
                      );
                    }
                }
              },
              itemBuilder: (_) => [
                PopupMenuItem(
                  value: 'find',
                  child: Text(AppStrings.codeEditFind),
                ),
                PopupMenuItem(
                  value: 'curl',
                  child: Text(AppStrings.codeEditCurlConvert),
                ),
                if (widget.writable && widget.showDebugSource)
                  PopupMenuItem(
                    value: 'debug',
                    child: Text(AppStrings.debugLabel),
                  ),
                PopupMenuItem(
                  value: 'copy_all',
                  child: Text(AppStrings.codeEditCopyAll),
                ),
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
                  // [LAYOUT_PLAN P2] 组内行 vertical12/horizontal8（全局行规范）
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 12,
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _findCtrl,
                          // [LAYOUT_PLAN P2] 输入框走 inputDecorationTheme，不手写边框
                          decoration: InputDecoration(
                            hintText: AppStrings.codeEditFindHint,
                            isDense: true,
                          ),
                          onSubmitted: (_) => _findNext(),
                        ),
                      ),
                      IconButton(
                        tooltip: AppStrings.codeEditNext,
                        onPressed: _findNext,
                        icon: const Icon(Symbols.keyboard_arrow_down_rounded),
                      ),
                      IconButton(
                        tooltip: AppStrings.closeLabel,
                        onPressed: () => setState(() => _showFind = false),
                        icon: const Icon(Symbols.close_rounded),
                      ),
                    ],
                  ),
                ),
              ),
            Expanded(
              child: Padding(
                // [LAYOUT_PLAN P2] 页面水平边距统一 16dp（全局标尺）
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: cs.surfaceContainerHighest.withValues(alpha: 0.35),
                    // [LAYOUT_PLAN P2] 分组卡圆角统一 16dp（全局标尺）
                    borderRadius: BorderRadius.circular(16),
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
                      // [B3] 沉浸代码编辑区：三态显式无边框，防主题底线式渗入
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
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
