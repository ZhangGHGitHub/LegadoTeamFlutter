// 直链上传规则配置 Sheet（批16b）
//
// 对齐参考版 `DirectLinkUploadBottomSheet`（legado-with-MD3）：
// 标题 + 关闭/更多菜单 + 上传 URL / 下载 URL 规则 / 注释 / 是否压缩 +
// 测试 / 取消 / 确认。字段集按参考版 4 字段（不展示口令与 expiryDate）。
// 菜单：导入默认规则（内置 3 条，索引 0 为默认）/ 复制规则 / 粘贴规则。
// 测试语义对齐原版：上传 `test.json`（`{}`）并展示结果（可复制）。
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:material_symbols_icons/symbols.dart';

import '../providers/providers.dart';
import '../services/direct_link_upload_rule_service.dart';
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

  bool get _busy => _testing || _saving;

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
    _uploadUrl.dispose();
    _downloadUrlRule.dispose();
    _summary.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final rule = await _service.getEffectiveRule();
      if (!mounted) return;
      _fill(rule);
    } on DirectLinkUploadRuleException catch (e) {
      if (mounted) _toast('读取直链上传规则失败：${e.message}');
    } catch (e) {
      if (mounted) _toast('读取直链上传规则失败：$e');
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
      _toast('读取默认规则失败：$e');
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
    await Clipboard.setData(ClipboardData(text: json));
    _toast('规则已复制到剪贴板');
  }

  Future<void> _pasteRule() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text ?? '';
    if (text.trim().isEmpty) {
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
      error = '$e';
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
      builder: (dialogContext) => AlertDialog(
        title: Text(title),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480, maxHeight: 360),
          child: SingleChildScrollView(
            child: SelectableText(
              message,
              style: isError
                  ? TextStyle(color: Theme.of(dialogContext).colorScheme.error)
                  : null,
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: message));
              if (dialogContext.mounted) Navigator.pop(dialogContext);
            },
            child: const Text('复制结果'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('确认'),
          ),
        ],
      ),
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
        ..showSnackBar(SnackBar(content: Text('保存失败：$e')));
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
                            enabled: !_loading,
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
                                  onChanged: _busy
                                      ? null
                                      : (v) => setState(() => _compress = v),
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
