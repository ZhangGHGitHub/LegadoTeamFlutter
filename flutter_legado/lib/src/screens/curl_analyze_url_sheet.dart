import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;

import '../providers/providers.dart';

/// cURL ↔ AnalyzeUrl 双向转换（对标原版 `CurlAnalyzeUrlDialog`）
///
/// 设计：iOS 风格底部 Sheet——分组控件、系统灰底、主次按钮清晰，无花哨装饰。
class CurlAnalyzeUrlSheet extends ConsumerStatefulWidget {
  /// 初始输入（可选选区文本）
  final String initialText;

  /// 是否允许「插入」回写编辑器
  final bool canInsert;

  const CurlAnalyzeUrlSheet({
    super.key,
    this.initialText = '',
    this.canInsert = true,
  });

  /// 展示 Sheet；返回插入文本，或 `null`（仅复制/取消）
  static Future<String?> show(
    BuildContext context, {
    String initialText = '',
    bool canInsert = true,
  }) {
    return showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (_) => CurlAnalyzeUrlSheet(
        initialText: initialText,
        canInsert: canInsert,
      ),
    );
  }

  @override
  ConsumerState<CurlAnalyzeUrlSheet> createState() =>
      _CurlAnalyzeUrlSheetState();
}

class _CurlAnalyzeUrlSheetState extends ConsumerState<CurlAnalyzeUrlSheet> {
  late final TextEditingController _input;
  late final TextEditingController _output;
  /// true = cURL → AnalyzeUrl
  bool _curlToAnalyze = true;
  bool _converting = false;

  @override
  void initState() {
    super.initState();
    _input = TextEditingController(text: widget.initialText);
    _output = TextEditingController();
    _bootstrapDirection();
  }

  Future<void> _bootstrapDirection() async {
    final text = widget.initialText.trim();
    if (text.isEmpty) return;
    try {
      final like = await ref.read(bookApiProvider).looksLikeCurl(text);
      if (!mounted) return;
      if (!like) setState(() => _curlToAnalyze = false);
    } catch (_) {}
  }

  @override
  void dispose() {
    _input.dispose();
    _output.dispose();
    super.dispose();
  }

  Future<void> _convert() async {
    setState(() => _converting = true);
    try {
      final api = ref.read(bookApiProvider);
      final out = _curlToAnalyze
          ? await api.curlToAnalyzeUrl(_input.text)
          : await api.analyzeUrlToCurl(_input.text);
      if (!mounted) return;
      setState(() => _output.text = out);
    } catch (e) {
      if (!mounted) return;
      setState(() => _output.clear());
      final msg = _friendlyError('$e');
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
    } finally {
      if (mounted) setState(() => _converting = false);
    }
  }

  String _friendlyError(String raw) {
    if (raw.contains('CURL_EMPTY_INPUT')) return '输入不能为空';
    if (raw.contains('CURL_INVALID')) return '不是有效的 cURL 命令';
    if (raw.contains('CURL_MISSING_URL')) return '缺少 URL';
    if (raw.contains('CURL_INVALID_ANALYZE_URL')) return 'AnalyzeUrl 格式无效';
    if (raw.contains('CURL_UNSUPPORTED_METHOD')) return '不支持的 HTTP 方法';
    if (raw.contains('CURL_UNSUPPORTED_OPTION')) return '含不支持的选项';
    return '转换失败：$raw';
  }

  Future<void> _copy() async {
    final out = _output.text;
    if (out.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('没有可复制的结果')),
      );
      return;
    }
    await Clipboard.setData(ClipboardData(text: out));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('已复制')),
    );
  }

  void _insert() {
    final out = _output.text;
    if (out.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('没有可插入的结果')),
      );
      return;
    }
    Navigator.of(context).pop(out);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final bottom = MediaQuery.viewInsetsOf(context).bottom;

    return Padding(
      padding: EdgeInsets.only(bottom: bottom),
      child: Align(
        alignment: Alignment.bottomCenter,
        child: Material(
          color: cs.surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
          clipBehavior: Clip.antiAlias,
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.sizeOf(context).height * 0.92,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(height: 8),
                Container(
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: cs.outlineVariant,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                Padding(
                  // [LAYOUT_PLAN P2] 组内行 vertical12/horizontal8（全局行规范）
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
                  child: Row(
                    children: [
                      IconButton(
                        tooltip: '关闭',
                        onPressed: () => Navigator.pop(context),
                        icon: const Icon(Symbols.close_rounded),
                      ),
                      Expanded(
                        child: Text(
                          'cURL ↔ AnalyzeUrl',
                          textAlign: TextAlign.center,
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      IconButton(
                        tooltip: '转换',
                        onPressed: _converting ? null : _convert,
                        icon: _converting
                            ? const SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Symbols.swap_horiz_rounded),
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: SegmentedButton<bool>(
                    segments: const [
                      ButtonSegment(
                        value: true,
                        label: Text('cURL → URL'),
                        icon: Icon(Symbols.arrow_forward_rounded, size: 16),
                      ),
                      ButtonSegment(
                        value: false,
                        label: Text('URL → cURL'),
                        icon: Icon(Symbols.arrow_back_rounded, size: 16),
                      ),
                    ],
                    selected: {_curlToAnalyze},
                    onSelectionChanged: (s) {
                      setState(() {
                        _curlToAnalyze = s.first;
                        _output.clear();
                      });
                    },
                  ),
                ),
                const SizedBox(height: 12),
                Flexible(
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                    children: [
                      TextField(
                        controller: _input,
                        maxLines: 8,
                        minLines: 4,
                        style: const TextStyle(
                          fontFamily: 'Menlo',
                          fontFamilyFallback: ['Consolas', 'monospace'],
                          fontSize: 13,
                          height: 1.35,
                        ),
                        decoration: InputDecoration(
                          labelText: _curlToAnalyze ? 'cURL 命令' : 'AnalyzeUrl',
                          alignLabelWithHint: true,
                          // [LAYOUT_PLAN P2] 输入框走 inputDecorationTheme，不手写边框
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: _output,
                        readOnly: true,
                        maxLines: 8,
                        minLines: 3,
                        style: const TextStyle(
                          fontFamily: 'Menlo',
                          fontFamilyFallback: ['Consolas', 'monospace'],
                          fontSize: 13,
                          height: 1.35,
                        ),
                        decoration: InputDecoration(
                          labelText: _curlToAnalyze ? 'AnalyzeUrl' : 'cURL 命令',
                          alignLabelWithHint: true,
                          // [LAYOUT_PLAN P2] 输入框走 inputDecorationTheme，不手写边框
                        ),
                      ),
                      const SizedBox(height: 16),
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton(
                              onPressed: _copy,
                              child: const Text('复制'),
                            ),
                          ),
                          if (widget.canInsert) ...[
                            const SizedBox(width: 12),
                            Expanded(
                              child: FilledButton(
                                onPressed: _insert,
                                child: const Text('插入'),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
