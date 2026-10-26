// 通用导出目标 Sheet（批16c）
//
// 对齐参考版 `FilePickerSheet` 的 EXPORT 形态（legado-with-MD3）：
// 「保存到本地」（系统另存）+「上传直链」两项，不做自带文件夹/手动路径，
// 不含口令与 expiryDate（已登记待用户裁决）。
//
// 上传语义对齐 `BaseRuleViewModel.uploadSelectedRules`：按生效直链规则
// （`DirectLinkUploadRuleService.getEffectiveRule()`，配置键
// `directLinkUploadRule`）调用契约 §2.51 `directLinkUpload`；成功后展示
// URL + 规则注释（summary）并可复制，失败展示真实错误文本（可复制/重试）。
//
// 返回值 [ExportFileResult] 供调用方统一提示导出结果；null = 用户取消
// （含系统另存对话框取消、失败后放弃）。
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:material_symbols_icons/symbols.dart';

import '../providers/providers.dart';
import '../services/direct_link_upload_rule_service.dart';
import '../services/export_file_service.dart';
import '../utils/error_message.dart';
import 'ios_widgets.dart';

/// 导出成功的结果类型
enum ExportFileOutcome {
  /// 已通过系统另存写入本地
  savedLocal,

  /// 已上传直链并取得下载 URL
  uploaded,
}

/// 导出结果（供调用方提示）
@immutable
class ExportFileResult {
  const ExportFileResult._({
    required this.outcome,
    this.path,
    this.url,
    this.summary,
  });

  /// 已保存到本地 [path]
  const ExportFileResult.savedLocal(String path)
    : this._(outcome: ExportFileOutcome.savedLocal, path: path);

  /// 已上传直链 [url]（[summary] 为生效规则的注释）
  const ExportFileResult.uploaded({
    required String url,
    required String summary,
  }) : this._(outcome: ExportFileOutcome.uploaded, url: url, summary: summary);

  final ExportFileOutcome outcome;

  /// 本地保存路径（[ExportFileOutcome.savedLocal] 时有值）
  final String? path;

  /// 直链 URL（[ExportFileOutcome.uploaded] 时有值）
  final String? url;

  /// 生效规则注释（[ExportFileOutcome.uploaded] 时有值）
  final String? summary;

  /// 调用方统一提示文案（仅成功结果）
  String get message => switch (outcome) {
    ExportFileOutcome.savedLocal => '已保存到：$path',
    ExportFileOutcome.uploaded => '上传成功：$url',
  };
}

/// 展示通用导出目标 Sheet
///
/// - [content]：要导出的完整文本内容（JSON 等）；
/// - [fileName]：系统另存/上传使用的文件名（如 `rssSources.json`）；
/// - [contentType]：上传时的内容类型（默认 `application/json`）；
/// - [subject]：Sheet 标题（默认「选择操作」，对齐参考版 select_operation）；
/// - [fileService] / [ruleService]：测试注入口，默认按真实实现构造。
///
/// 返回 null 表示用户取消；成功时返回 [ExportFileResult]。
Future<ExportFileResult?> showExportFileSheet(
  BuildContext context, {
  required String content,
  required String fileName,
  String contentType = 'application/json',
  String? subject,
  ExportFileService? fileService,
  DirectLinkUploadRuleService? ruleService,
}) {
  return showModalBottomSheet<ExportFileResult>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Colors.transparent,
    builder: (_) => ExportFileSheet(
      content: content,
      fileName: fileName,
      contentType: contentType,
      subject: subject,
      fileService: fileService,
      ruleService: ruleService,
    ),
  );
}

/// 通用导出目标底部 Sheet
class ExportFileSheet extends ConsumerStatefulWidget {
  const ExportFileSheet({
    super.key,
    required this.content,
    required this.fileName,
    this.contentType = 'application/json',
    this.subject,
    this.fileService,
    this.ruleService,
  });

  /// 导出内容
  final String content;

  /// 导出文件名
  final String fileName;

  /// 上传内容类型
  final String contentType;

  /// Sheet 标题
  final String? subject;

  /// 落盘服务（测试注入）
  final ExportFileService? fileService;

  /// 直链上传规则服务（测试注入）
  final DirectLinkUploadRuleService? ruleService;

  @override
  ConsumerState<ExportFileSheet> createState() => _ExportFileSheetState();
}

/// 失败环节（决定错误面板标题与重试动作）
enum _FailureAction { save, upload }

class _ExportFileSheetState extends ConsumerState<ExportFileSheet> {
  late final ExportFileService _fileService;
  late final DirectLinkUploadRuleService _ruleService;

  bool _saving = false;
  bool _uploading = false;

  /// 失败环节与真实错误文本
  _FailureAction? _failedAction;
  String? _error;

  /// 错误面板标题
  String get _errorTitle =>
      _failedAction == _FailureAction.upload ? '上传失败' : '保存失败';

  /// 上传成功后的直链与规则注释
  String? _uploadedUrl;
  String? _uploadedSummary;

  bool get _busy => _saving || _uploading;

  @override
  void initState() {
    super.initState();
    _fileService = widget.fileService ?? const ExportFileService();
    _ruleService =
        widget.ruleService ??
        DirectLinkUploadRuleService(ref.read(bookApiProvider));
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  /// 复制文本到剪贴板（失败给出真实原因）
  Future<void> _copy(String text, String successMessage) async {
    try {
      await Clipboard.setData(ClipboardData(text: text));
    } catch (e) {
      _toast('复制失败：${errorMessage(e)}');
      return;
    }
    _toast(successMessage);
  }

  /// 保存到本地（系统另存）
  Future<void> _saveToLocal() async {
    setState(() {
      _saving = true;
      _failedAction = null;
      _error = null;
    });
    String? path;
    try {
      path = await _fileService.saveToLocal(
        fileName: widget.fileName,
        content: widget.content,
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _failedAction = _FailureAction.save;
        _error = errorMessage(e);
      });
      return;
    }
    if (!mounted) return;
    setState(() => _saving = false);
    if (path == null) {
      // 用户在系统另存对话框取消：关闭 Sheet，不提示
      Navigator.pop(context);
      return;
    }
    Navigator.pop(context, ExportFileResult.savedLocal(path));
  }

  /// 上传直链（生效规则 → §2.51 directLinkUpload）
  Future<void> _upload() async {
    setState(() {
      _uploading = true;
      _failedAction = null;
      _error = null;
    });
    try {
      final rule = await _ruleService.getEffectiveRule();
      final url = await ref.read(bookApiProvider).directLinkUpload(
        ruleJson: rule.toJsonString(),
        fileName: widget.fileName,
        contentType: widget.contentType,
        content: widget.content,
      );
      if (!mounted) return;
      setState(() {
        _uploading = false;
        _uploadedUrl = url;
        _uploadedSummary = rule.summary;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _uploading = false;
        _failedAction = _FailureAction.upload;
        _error = errorMessage(e);
      });
    }
  }

  /// 失败面板重试：按失败环节重跑对应动作
  Future<void> _retry() {
    return _failedAction == _FailureAction.upload ? _upload() : _saveToLocal();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    return PopScope(
      // 保存/上传进行中禁止返回，避免结果丢失
      canPop: !_busy,
      child: Align(
        alignment: Alignment.bottomCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: Material(
            color: cs.surface,
            borderRadius: const BorderRadius.vertical(
              top: Radius.circular(16),
            ),
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
                            onPressed: _busy
                                ? null
                                : () => Navigator.pop(context),
                            icon: const Icon(Symbols.close_rounded),
                          ),
                          Expanded(
                            child: Text(
                              widget.subject ?? '选择操作',
                              textAlign: TextAlign.center,
                              style: theme.textTheme.titleMedium?.copyWith(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          // 占位保持标题居中
                          const SizedBox(width: 48),
                        ],
                      ),
                    ),
                    Flexible(
                      child: SingleChildScrollView(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                        child: _buildBody(theme),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                      child: _buildActions(),
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

  /// 主体：选项 / 进行中 / 成功 / 失败 四态
  Widget _buildBody(ThemeData theme) {
    if (_uploading || _saving) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(
              width: 32,
              height: 32,
              child: CircularProgressIndicator(strokeWidth: 3),
            ),
            const SizedBox(height: 16),
            Text(_saving ? '正在保存…' : '正在上传…'),
          ],
        ),
      );
    }
    if (_error != null) return _buildErrorPanel(theme);
    if (_uploadedUrl != null) return _buildUploadedPanel(theme);
    return _buildOptions(theme);
  }

  /// 两个选项（对齐参考版 FilePickerSheet EXPORT：另存 + 上传）
  Widget _buildOptions(ThemeData theme) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _OptionTile(
          icon: Symbols.save_alt_rounded,
          title: '保存到本地',
          subtitle: '通过系统保存对话框选择保存位置',
          onTap: _saveToLocal,
        ),
        const SizedBox(height: 8),
        _OptionTile(
          icon: Symbols.cloud_upload_rounded,
          title: '上传直链',
          subtitle: '按直链上传规则上传，返回可分享的下载链接',
          onTap: _upload,
        ),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerLeft,
          child: Text(
            '导出文件：${widget.fileName}',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ],
    );
  }

  /// 上传成功：URL + 规则注释（summary）
  Widget _buildUploadedPanel(ThemeData theme) {
    final cs = theme.colorScheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Symbols.cloud_done_rounded, size: 40, color: cs.primary),
        const SizedBox(height: 8),
        Text(
          '上传成功',
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          _uploadedSummary ?? '',
          textAlign: TextAlign.center,
          style: theme.textTheme.bodySmall?.copyWith(
            color: cs.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 12),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: cs.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(12),
          ),
          child: SelectableText(
            _uploadedUrl!,
            style: const TextStyle(
              fontFamily: 'Menlo',
              fontFamilyFallback: ['Consolas', 'monospace'],
              fontSize: 13,
              height: 1.35,
            ),
          ),
        ),
      ],
    );
  }

  /// 失败：真实错误文本（可复制/重试）
  Widget _buildErrorPanel(ThemeData theme) {
    final cs = theme.colorScheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Symbols.error_rounded, size: 40, color: cs.error),
        const SizedBox(height: 8),
        Text(
          _errorTitle,
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 12),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: cs.errorContainer,
            borderRadius: BorderRadius.circular(12),
          ),
          child: SelectableText(
            _error!,
            style: TextStyle(color: cs.onErrorContainer),
          ),
        ),
      ],
    );
  }

  /// 底部按钮：随四态变化
  Widget _buildActions() {
    if (_uploadedUrl != null) {
      return Row(
        children: [
          Expanded(
            child: OutlinedButton.icon(
              onPressed: () => _copy(_uploadedUrl!, '已复制链接'),
              icon: const Icon(Symbols.content_copy_rounded, size: 18),
              label: const Text('复制链接'),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: FilledButton(
              onPressed: () => Navigator.pop(
                context,
                ExportFileResult.uploaded(
                  url: _uploadedUrl!,
                  summary: _uploadedSummary ?? '',
                ),
              ),
              child: const Text('完成'),
            ),
          ),
        ],
      );
    }
    if (_error != null) {
      return Row(
        children: [
          Expanded(
            child: OutlinedButton.icon(
              onPressed: () => _copy(_error!, '已复制错误信息'),
              icon: const Icon(Symbols.content_copy_rounded, size: 18),
              label: const Text('复制错误'),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消'),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: FilledButton(
              onPressed: _retry,
              child: const Text('重试'),
            ),
          ),
        ],
      );
    }
    return SizedBox(
      width: double.infinity,
      child: TextButton(
        onPressed: _busy ? null : () => Navigator.pop(context),
        child: const Text('取消'),
      ),
    );
  }
}

/// 选项行：图标 + 标题 + 说明
class _OptionTile extends StatelessWidget {
  const _OptionTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Material(
      color: cs.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(12),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Row(
            children: [
              Icon(icon, size: 24, color: cs.primary),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: cs.onSurfaceVariant,
                      ),
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
}
