// 直链上传规则配置 Sheet（批16b）
//
// 对齐参考版 `DirectLinkUploadBottomSheet`（legado-with-MD3）：
// 标题 + 关闭/更多菜单 + 上传 URL / 下载 URL 规则 / 注释 / 是否压缩 +
// 测试 / 取消 / 确认。字段集按参考版 4 字段（不展示口令与 expiryDate）。
// 菜单：导入默认规则（内置 3 条，索引 0 为默认）/ 复制规则 / 粘贴规则。
// 测试语义对齐原版：上传 `test.json`（`{}`）并展示结果（可复制）。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:material_symbols_icons/symbols.dart';

import '../providers/providers.dart';
import '../services/direct_link_upload_rule_service.dart';
import '../utils/error_message.dart';
import '../widgets/ios_widgets.dart';

/// 直链上传规则配置底部 Sheet
class DirectLinkUploadSettingsSheet extends ConsumerStatefulWidget {
  /// 可选注入服务（测试用）；默认经 [bookApiProvider] 构造
  final DirectLinkUploadRuleService? service;

  const DirectLinkUploadSettingsSheet({super.key, this.service});

  /// 展示 Sheet
  static Future<void> show(
    BuildContext context, {
    DirectLinkUploadRuleService? service,
  }) {
    return showModalBottomSheet<void>(
      context: context,
      // 测试/保存进行中拖拽关闭会绕过 _busy 保护并丢失进度，统一禁用手势下拉
      enableDrag: false,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (_) => DirectLinkUploadSettingsSheet(service: service),
    );
  }

  @override
  ConsumerState<DirectLinkUploadSettingsSheet> createState() =>
      _DirectLinkUploadSettingsSheetState();
}

enum _SheetMenuAction { importDefault, copy, paste }

class _DirectLinkUploadSettingsSheetState
    extends ConsumerState<DirectLinkUploadSettingsSheet> {
  late final DirectLinkUploadRuleService _service;
  late final TextEditingController _uploadUrl;
  late final TextEditingController _downloadUrlRule;
  late final TextEditingController _summary;

  bool _compress = false;
  bool _loading = true;
  bool _testing = false;
  bool _saving = false;

  /// 复制反馈文案（Sheet 内联展示，成功短暂显示后自动清除）
  String? _feedback;
  bool _feedbackError = false;
  Timer? _feedbackTimer;

  bool get _busy => _testing || _saving;

  /// 加载或保存/测试进行中时，表单与菜单统一禁用
  bool get _interactive => !_loading && !_busy;

  @override
  void initState() {
    super.initState();
    _service =
        widget.service ??
        DirectLinkUploadRuleService(ref.read(bookApiProvider));
    _uploadUrl = TextEditingController();
    _downloadUrlRule = TextEditingController();
    _summary = TextEditingController();
    _load();
  }

  @override
  void dispose() {
    _feedbackTimer?.cancel();
    _uploadUrl.dispose();
    _downloadUrlRule.dispose();
    _summary.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final result = await _service.resolveEffectiveRule();
      if (!mounted) return;
      _fill(result.rule);
      if (result.degraded) {
        _toast('已保存的直链规则无效，已回退默认规则');
      }
    } on DirectLinkUploadRuleException catch (e) {
      if (mounted) _toast('读取直链上传规则失败：${e.message}');
    } catch (e) {
      if (mounted) _toast('读取直链上传规则失败：${errorMessage(e)}');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// 表单当前值 → 规则对象（未校验，供复制/保存/测试复用）
  DirectLinkUploadRule _currentRule() => DirectLinkUploadRule(
    uploadUrl: _uploadUrl.text,
    downloadUrlRule: _downloadUrlRule.text,
    summary: _summary.text,
    compress: _compress,
  );

  void _fill(DirectLinkUploadRule rule) {
    setState(() {
      _uploadUrl.text = rule.uploadUrl;
      _downloadUrlRule.text = rule.downloadUrlRule;
      _summary.text = rule.summary;
      _compress = rule.compress;
    });
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  /// 内联反馈：成功文案短暂展示（2 秒）后自动隐藏，失败文案保留到下次操作
  void _showFeedback(String message, {bool isError = false}) {
    if (!mounted) return;
    _feedbackTimer?.cancel();
    setState(() {
      _feedback = message;
      _feedbackError = isError;
    });
    if (isError) return;
    _feedbackTimer = Timer(const Duration(seconds: 2), () {
      if (!mounted) return;
      setState(() => _feedback = null);
    });
  }

  Future<void> _onMenuSelected(_SheetMenuAction action) {
    return switch (action) {
      _SheetMenuAction.importDefault => _importDefault(),
      _SheetMenuAction.copy => _copyRule(),
      _SheetMenuAction.paste => _pasteRule(),
    };
  }

  Future<void> _importDefault() async {
    List<DirectLinkUploadRule> rules;
    try {
      rules = await _service.loadDefaultRules();
    } on DirectLinkUploadRuleException catch (e) {
      _toast('读取默认规则失败：${e.message}');
      return;
    } catch (e) {
      _toast('读取默认规则失败：${errorMessage(e)}');
      return;
    }
    if (!mounted) return;

    final selected = await showDialog<DirectLinkUploadRule>(
      context: context,
      builder: (dialogContext) => SimpleDialog(
        title: const Text('导入默认规则'),
        children: [
          for (var i = 0; i < rules.length; i++)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(dialogContext, rules[i]),
              child: Text(
                i == 0 ? '${rules[i].summary}（默认）' : rules[i].summary,
              ),
            ),
        ],
      ),
    );
    if (selected == null || !mounted) return;
    _fill(selected);
    _toast('已导入默认规则「${selected.summary}」');
  }

  Future<void> _copyRule() async {
    final json = _currentRule().toJsonString();
    try {
      await Clipboard.setData(ClipboardData(text: json));
    } catch (e) {
      _showFeedback('复制失败：${errorMessage(e)}', isError: true);
      return;
    }
    _showFeedback('规则已复制到剪贴板');
  }

  Future<void> _pasteRule() async {
    final String? text;
    try {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      text = data?.text;
    } catch (e) {
      _toast('读取剪贴板失败：${errorMessage(e)}');
      return;
    }
    if (text == null || text.trim().isEmpty) {
      _toast('剪贴板为空或格式不正确');
      return;
    }
    try {
      final rule = _service.parseRule(text);
      if (!mounted) return;
      _fill(rule);
      _toast('已粘贴规则「${rule.summary}」');
    } on DirectLinkUploadRuleException {
      _toast('剪贴板为空或格式不正确');
    }
  }

  Future<void> _test() async {
    setState(() => _testing = true);
    String? result;
    String? error;
    try {
      result = await _service.testRule(_currentRule().toJsonString());
    } on DirectLinkUploadRuleException catch (e) {
      error = e.message;
    } catch (e) {
      error = errorMessage(e);
    }
    if (!mounted) return;
    setState(() => _testing = false);
    await _showResult(
      title: error == null ? '测试结果' : '测试失败',
      message: error ?? result ?? '',
      isError: error != null,
    );
  }

  Future<void> _showResult({
    required String title,
    required String message,
    bool isError = false,
  }) async {
    await showDialog<void>(
      context: context,
      builder: (_) =>
          _ResultDialog(title: title, message: message, isError: isError),
    );
  }

  Future<void> _save() async {
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _saving = true);
    try {
      await _service.saveRule(_currentRule().toJsonString());
      if (!mounted) return;
      Navigator.pop(context);
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(content: Text('已保存直链上传规则')));
    } on DirectLinkUploadRuleException catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(e.message)));
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(content: Text('保存失败：${errorMessage(e)}')),
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;

    return Padding(
      padding: EdgeInsets.only(bottom: bottomInset),
      child: Align(
        alignment: Alignment.bottomCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: Material(
            color: cs.surface,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
            clipBehavior: Clip.antiAlias,
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.sizeOf(context).height * 0.92,
              ),
              child: SizedBox(
                width: double.infinity,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const IosGrabber(),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                      child: Row(
                        children: [
                          IconButton(
                            tooltip: '关闭',
                            onPressed: () => Navigator.pop(context),
                            icon: const Icon(Symbols.close_rounded),
                          ),
                          Expanded(
                            child: Text(
                              '直链上传配置',
                              textAlign: TextAlign.center,
                              style: theme.textTheme.titleMedium?.copyWith(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          PopupMenuButton<_SheetMenuAction>(
                            tooltip: '更多菜单',
                            enabled: _interactive,
                            icon: const Icon(Symbols.more_vert_rounded),
                            onSelected: _onMenuSelected,
                            itemBuilder: (_) => const [
                              PopupMenuItem(
                                value: _SheetMenuAction.importDefault,
                                child: _MenuRow(
                                  icon: Symbols.download_rounded,
                                  label: '导入默认规则',
                                ),
                              ),
                              PopupMenuItem(
                                value: _SheetMenuAction.copy,
                                child: _MenuRow(
                                  icon: Symbols.content_copy_rounded,
                                  label: '复制规则',
                                ),
                              ),
                              PopupMenuItem(
                                value: _SheetMenuAction.paste,
                                child: _MenuRow(
                                  icon: Symbols.content_paste_rounded,
                                  label: '粘贴规则',
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    // 复制反馈内联展示：不依赖底层 Scaffold 的 SnackBar
                    if (_feedback != null)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Icon(
                              _feedbackError
                                  ? Symbols.error_outline_rounded
                                  : Symbols.check_circle_outline_rounded,
                              size: 16,
                              color: _feedbackError ? cs.error : cs.primary,
                            ),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Text(
                                _feedback!,
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: _feedbackError
                                      ? cs.error
                                      : cs.primary,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    Flexible(
                      child: _loading
                          ? const Padding(
                              padding: EdgeInsets.all(48),
                              child: Center(child: CircularProgressIndicator()),
                            )
                          : ListView(
                              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                              children: [
                                TextField(
                                  controller: _uploadUrl,
                                  enabled: _interactive,
                                  minLines: 2,
                                  maxLines: 4,
                                  autocorrect: false,
                                  enableSuggestions: false,
                                  style: const TextStyle(
                                    fontFamily: 'Menlo',
                                    fontFamilyFallback: [
                                      'Consolas',
                                      'monospace',
                                    ],
                                    fontSize: 13,
                                    height: 1.35,
                                  ),
                                  decoration: const InputDecoration(
                                    labelText: '上传 URL',
                                    helperText: '支持 url,{选项 JSON} 形式',
                                    alignLabelWithHint: true,
                                  ),
                                ),
                                const SizedBox(height: 16),
                                TextField(
                                  controller: _downloadUrlRule,
                                  enabled: _interactive,
                                  minLines: 3,
                                  maxLines: 8,
                                  autocorrect: false,
                                  enableSuggestions: false,
                                  style: const TextStyle(
                                    fontFamily: 'Menlo',
                                    fontFamilyFallback: [
                                      'Consolas',
                                      'monospace',
                                    ],
                                    fontSize: 13,
                                    height: 1.35,
                                  ),
                                  decoration: const InputDecoration(
                                    labelText: '下载 URL 规则',
                                    helperText: 'JSONPath / 正则 / @js: 级联',
                                    alignLabelWithHint: true,
                                  ),
                                ),
                                const SizedBox(height: 16),
                                TextField(
                                  controller: _summary,
                                  enabled: _interactive,
                                  maxLines: 2,
                                  minLines: 1,
                                  decoration: const InputDecoration(
                                    labelText: '注释',
                                    alignLabelWithHint: true,
                                  ),
                                ),
                                const SizedBox(height: 8),
                                SwitchListTile(
                                  contentPadding: EdgeInsets.zero,
                                  title: const Text('是否压缩'),
                                  subtitle: const Text('上传前压缩为 zip'),
                                  value: _compress,
                                  onChanged: _interactive
                                      ? (v) => setState(() => _compress = v)
                                      : null,
                                ),
                                const SizedBox(height: 4),
                                Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Icon(
                                      Icons.shield_outlined,
                                      size: 16,
                                      color: cs.onSurfaceVariant,
                                    ),
                                    const SizedBox(width: 6),
                                    Expanded(
                                      child: Text(
                                        '安全提示：规则可能来自网络，上传内容与下载链接由所填服务器处理；'
                                        '下载规则支持 JS 脚本，请确认来源可信后再使用。',
                                        style: theme.textTheme.bodySmall
                                            ?.copyWith(
                                              color: cs.onSurfaceVariant,
                                            ),
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                      child: Row(
                        children: [
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: _loading || _busy ? null : _test,
                              icon: _testing
                                  ? const SizedBox(
                                      width: 16,
                                      height: 16,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    )
                                  : const Icon(
                                      Icons.checklist_rounded,
                                      size: 18,
                                    ),
                              label: Text(_testing ? '测试中' : '测试'),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: TextButton(
                              onPressed: _busy
                                  ? null
                                  : () => Navigator.pop(context),
                              child: const Text('取消'),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: FilledButton(
                              onPressed: _loading || _busy ? null : _save,
                              child: _saving
                                  ? const SizedBox(
                                      width: 16,
                                      height: 16,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    )
                                  : const Text('确认'),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 菜单行：图标 + 文案
class _MenuRow extends StatelessWidget {
  const _MenuRow({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [Icon(icon, size: 20), const SizedBox(width: 12), Text(label)],
    );
  }
}

/// 测试结果对话框（复制结果失败时内联展示原因，不走 SnackBar）
class _ResultDialog extends StatefulWidget {
  const _ResultDialog({
    required this.title,
    required this.message,
    required this.isError,
  });

  final String title;
  final String message;
  final bool isError;

  @override
  State<_ResultDialog> createState() => _ResultDialogState();
}

class _ResultDialogState extends State<_ResultDialog> {
  /// 复制失败的真实原因
  String? _copyError;

  Future<void> _copy() async {
    try {
      await Clipboard.setData(ClipboardData(text: widget.message));
    } catch (e) {
      if (!mounted) return;
      setState(() => _copyError = '复制失败：${errorMessage(e)}');
      return;
    }
    if (!mounted) return;
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return AlertDialog(
      title: Text(widget.title),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480, maxHeight: 360),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SelectableText(
                widget.message,
                style: widget.isError ? TextStyle(color: cs.error) : null,
              ),
              if (_copyError != null) ...[
                const SizedBox(height: 12),
                Text(
                  _copyError!,
                  style: TextStyle(color: cs.error, fontSize: 12),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: _copy, child: const Text('复制结果')),
        FilledButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('确认'),
        ),
      ],
    );
  }
}
