import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;

import '../models/models.dart';
import '../providers/providers.dart';
import '../providers/source/source_notifier.dart';
import 'code_edit_screen.dart';
import 'curl_analyze_url_sheet.dart';
import 'source_debug_screen.dart';

/// JS 单文件书源编辑（对标原版 JsSourceEditActivity 最小可用）
///
/// 流程：编辑 mainJs → `extractJsSource` 提取 BookSource → 保存。
/// — GapAudit P0-1 | 2026-08-12
class JsSourceEditScreen extends ConsumerStatefulWidget {
  /// 编辑已有源时传入 bookSourceUrl；新建为空
  final String? sourceUrl;

  const JsSourceEditScreen({super.key, this.sourceUrl});

  @override
  ConsumerState<JsSourceEditScreen> createState() => _JsSourceEditScreenState();
}

class _JsSourceEditScreenState extends ConsumerState<JsSourceEditScreen> {
  final _controller = TextEditingController();
  bool _loading = true;
  bool _saving = false;
  String? _openedSourceUrl;
  String? _error;

  @override
  void initState() {
    super.initState();
    _openedSourceUrl = widget.sourceUrl;
    unawaited(_bootstrap());
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _bootstrap() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final url = _openedSourceUrl;
      if (url != null && url.isNotEmpty) {
        final sources = await ref.read(bookApiProvider).getBookSources();
        final hit = sources.where((s) => s.bookSourceUrl == url).firstOrNull;
        final js = hit?.mainJs?.trim();
        _controller.text =
            (js != null && js.isNotEmpty) ? js : _kJsSourceTemplate;
      } else {
        _controller.text = _kJsSourceTemplate;
      }
    } catch (e) {
      _error = '$e';
      _controller.text = _kJsSourceTemplate;
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _save({bool openDebug = false}) async {
    final content = _controller.text;
    if (content.trim().isEmpty) {
      _toast('脚本不能为空');
      return;
    }
    setState(() => _saving = true);
    try {
      final api = ref.read(bookApiProvider);
      // 语法检查（失败不阻断保存，仅提示）
      try {
        final checkRaw = await api.checkJsSourceSyntax(content);
        final check = jsonDecode(checkRaw) as Map<String, dynamic>;
        if (check['valid'] == false) {
          final msg = check['message']?.toString() ?? '语法错误';
          final line = check['line'];
          _toast(line != null ? '语法警告 L$line：$msg' : '语法警告：$msg');
        }
      } catch (_) {}

      final extracted = await api.extractJsSource(content);
      final map = jsonDecode(extracted) as Map<String, dynamic>;
      // 确保 mainJs 为完整脚本
      map['mainJs'] = content;
      final source = BookSource.fromJson(map);
      if (source.bookSourceUrl.trim().isEmpty ||
          source.bookSourceName.trim().isEmpty) {
        _toast('配置缺少 bookSourceUrl 或 bookSourceName');
        return;
      }

      final existing = await api.getBookSources();
      final exists =
          existing.any((s) => s.bookSourceUrl == source.bookSourceUrl);
      if (exists) {
        await api.updateBookSource(source);
      } else {
        await api.addBookSource(source);
      }
      _openedSourceUrl = source.bookSourceUrl;
      // 刷新书源列表
      try {
        await ref.read(sourceNotifierProvider.notifier).loadSources();
      } catch (_) {}

      if (!mounted) return;
      if (openDebug) {
        await Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => SourceDebugScreen(sourceUrl: source.bookSourceUrl),
          ),
        );
      } else {
        _toast('已保存：${source.bookSourceName}');
        Navigator.of(context).pop(true);
      }
    } catch (e) {
      if (mounted) _toast('保存失败：$e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _openCodeEdit() async {
    final result = await CodeEditScreen.open(
      context,
      title: 'JS 书源',
      initialText: _controller.text,
      cursorPosition: _controller.selection.baseOffset.clamp(
        0,
        _controller.text.length,
      ),
    );
    if (result == null || !mounted) return;
    setState(() {
      _controller.text = result;
      _controller.selection =
          TextSelection.collapsed(offset: result.length);
    });
  }

  Future<void> _openCurl() async {
    final inserted = await CurlAnalyzeUrlSheet.show(
      context,
      initialText: '',
      canInsert: true,
    );
    if (inserted == null || !mounted) return;
    final text = _controller.text;
    final sel = _controller.selection;
    final start = sel.isValid ? sel.start : text.length;
    final end = sel.isValid ? sel.end : text.length;
    final next = text.replaceRange(start, end, inserted);
    setState(() {
      _controller.value = TextEditingValue(
        text: next,
        selection: TextSelection.collapsed(offset: start + inserted.length),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: const Color(0xFFF2F2F7),
      appBar: AppBar(
        title: Text(
          _openedSourceUrl == null || _openedSourceUrl!.isEmpty
              ? '新建 JS 书源'
              : '编辑 JS 书源',
        ),
        actions: [
          IconButton(
            tooltip: '代码编辑',
            onPressed: _loading || _saving ? null : _openCodeEdit,
            icon: const Icon(Icons.code),
          ),
          IconButton(
            tooltip: 'cURL 转换',
            onPressed: _loading || _saving ? null : _openCurl,
            icon: const Icon(Icons.swap_horiz),
          ),
          IconButton(
            tooltip: '调试',
            onPressed: _saving ? null : () => _save(openDebug: true),
            icon: const Icon(Icons.bug_report_outlined),
          ),
          TextButton(
            onPressed: _saving ? null : () => _save(),
            style: TextButton.styleFrom(foregroundColor: cs.onPrimary),
            child: _saving
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('保存'),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                if (_error != null)
                  Material(
                    color: const Color(0xFFFFEBEE),
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Text(
                        '加载已有脚本失败，已回退模板：$_error',
                        style: const TextStyle(
                          color: Color(0xFFC62828),
                          fontSize: 13,
                        ),
                      ),
                    ),
                  ),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: TextField(
                        controller: _controller,
                        maxLines: null,
                        expands: true,
                        keyboardType: TextInputType.multiline,
                        textAlignVertical: TextAlignVertical.top,
                        style: const TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 13,
                          height: 1.35,
                          color: Color(0xFF1C1C1E),
                        ),
                        decoration: const InputDecoration(
                          border: InputBorder.none,
                          contentPadding: EdgeInsets.all(14),
                          hintText: '在此编写 JS 书源脚本…',
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
    );
  }
}

/// 精简模板（对齐 assets/js_source_template.js 必备结构）
const _kJsSourceTemplate = r'''/**
 * JavaScript 单文件书源模板。
 * search、getChapters、getContent 为必需函数。
 */
var config = {
    bookSourceUrl: "https://example.com",
    bookSourceName: "示例 JS 书源",
    bookSourceType: 0,
    bookSourceGroup: "",
    bookSourceComment: "",
    loginUi: [],
    exploreUrl: [],
    lastUpdateTime: 0
};

function search(key, page) {
    var html = java.ajax(config.bookSourceUrl + "/search?q=" + encodeURIComponent(key) + "&p=" + page);
    var books = [];
    return books;
}

function getChapters(book) {
    var html = java.ajax(book.tocUrl || book.bookUrl);
    var chapters = [];
    return chapters;
}

function getContent(chapter, book, nextChapterUrl) {
    var html = java.ajax(chapter.url);
    return html;
}
''';
