// 通用导出目标 Sheet（批16c）
//
// 对齐参考版 `FilePickerSheet` 的 EXPORT 形态（legado-with-MD3）：
// 「保存到本地」（系统另存）+「上传直链」两项，不做自带文件夹/手动路径。
// 批25 起规则类导出在上传成功后增加「复制口令」（过期天数在弹窗内输入，
// 默认 0 = 永久）；书单/皮肤等非规则导出不展示该入口。
//
// 上传语义对齐 `BaseRuleViewModel.uploadSelectedRules`：按生效直链规则
// （`DirectLinkUploadRuleService.getEffectiveRule()`，配置键
// `directLinkUploadRule`）调用契约 §2.51 `directLinkUpload`；成功后展示
// URL + 规则注释（summary）并可复制，失败展示真实错误文本（可复制/重试）。
//
// 返回值 [ExportFileResult] 供调用方统一提示导出结果；null = 用户取消
// （含系统另存对话框取消、失败后放弃）。
//
// 批16e 增加 filePath 模式：二进制/已落盘内容（书源单源 `.js`、底栏皮肤
// `.zip`）不再转字符串，直接把既有临时文件交给另存/上传两条链路。
//
// [批16e 回修 | P2-1/P2-2] 临时文件统一在 Sheet 关闭（dispose）时清理：
// 覆盖「另存成功 / 另存取消 / 上传成功 / 上传失败后放弃 / 外部关闭」全部
// 路径；上传失败后 Sheet 保持打开可重试，此时不删除文件。实际删除由
// [ExportFileService.deleteTemporaryFile] 执行，内置「仅删系统临时目录内
// 文件」护栏，用户目录文件一律不动。
// 批16c 初始化；批25 增加「复制口令」：`passphraseType` 非 null 且上传成功
// 的 URL 可编码时，在上传结果面板展示口令入口（有效期在弹窗内输入）。
//
// [批26 2026-10-27] Android 保存改为 SAF 目录树：选项区展示当前保存位置，
// 并提供「换个保存位置」入口（重选目录后记住）；保存失败面板同样提供
// 「换个位置」，重选成功后立即重试。iOS/桌面对话框每次自选位置，不展示。
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:material_symbols_icons/symbols.dart';
import 'package:path_provider/path_provider.dart';

import '../providers/providers.dart';
import '../services/direct_link_upload_rule_service.dart';
import '../services/export_file_service.dart';
import '../services/file_save_channel.dart';
import '../services/source_share_passphrase.dart';
import '../utils/error_message.dart';
import 'ios_widgets.dart';
import 'source_share_passphrase_dialog.dart';

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
    required this.message,
    this.path,
    this.url,
    this.summary,
  });

  /// 已保存到本地 [path]（[message] 为按平台生成的提示文案）
  const ExportFileResult.savedLocal(String path, {required String message})
    : this._(
        outcome: ExportFileOutcome.savedLocal,
        path: path,
        message: message,
      );

  /// 已上传直链 [url]（[summary] 为生效规则的注释）
  const ExportFileResult.uploaded({
    required String url,
    required String summary,
  }) : this._(
         outcome: ExportFileOutcome.uploaded,
         url: url,
         summary: summary,
         message: '上传成功：$url',
       );

  final ExportFileOutcome outcome;

  /// 调用方统一提示文案（仅成功结果；保存文案按平台区分）
  final String message;

  /// 本地保存路径（[ExportFileOutcome.savedLocal] 时有值）
  final String? path;

  /// 直链 URL（[ExportFileOutcome.uploaded] 时有值）
  final String? url;

  /// 生效规则注释（[ExportFileOutcome.uploaded] 时有值）
  final String? summary;
}

/// 展示通用导出目标 Sheet
///
/// [content] 与 [filePath] **必须且只能提供一个**（互斥，违反时抛
/// [ArgumentError]；release 构建同样生效。ExportFileSheet 构造函数仍保留
/// assert 作为直接实例化时的调试护栏）：
/// - [content]：要导出的完整文本内容（JSON 等）；
/// - [filePath]：已落盘的既有文件路径（`.js` / `.zip` 等二进制或非文本
///   内容），保存时复制字节到用户选择位置、上传时按路径上传。
///
/// 其余参数：
/// - [fileName]：系统另存使用的文件名（如 `exportRssSource.json`）；
/// - [uploadFileName]：上传直链使用的文件名（默认与 [fileName] 相同；
///   参考版各规则导出统一上传 `export_rules.json`）；
/// - [contentType]：上传时的内容类型（默认 `application/json`）；
/// - [subject]：Sheet 标题（默认「选择操作」，对齐参考版 select_operation）；
/// - [deleteTempFileOnClose]：Sheet 关闭时删除 [filePath] 指向的临时文件。
///   仅用于调用方自建的临时文件（如书源单源 `.js`、皮肤 `.zip`）；实际
///   删除还会校验文件位于系统临时目录内（见
///   [ExportFileService.deleteTemporaryFile]），指向用户文件的路径不会被删。
/// - [fileService] / [ruleService]：测试注入口，默认按真实实现构造。
/// - [passphraseType]：规则类导出传对应类型时，直链上传成功后展示
///   「复制口令」入口（批25）。书单/皮肤等非规则导出保持 null，不展示。
///
/// 返回 null 表示用户取消；成功时返回 [ExportFileResult]。
Future<ExportFileResult?> showExportFileSheet(
  BuildContext context, {
  String? content,
  String? filePath,
  required String fileName,
  String? uploadFileName,
  String contentType = 'application/json',
  String? subject,
  bool deleteTempFileOnClose = false,
  ExportFileService? fileService,
  DirectLinkUploadRuleService? ruleService,
  SourcePassphraseType? passphraseType,
}) {
  // assert 在 release 下会被移除，故公共入口改用常驻运行时校验（P3-6）；
  // ExportFileSheet 构造函数仍保留 assert 作为直接实例化时的调试护栏。
  if ((content == null) == (filePath == null)) {
    throw ArgumentError('content 与 filePath 必须且只能提供一个');
  }
  return showModalBottomSheet<ExportFileResult>(
    context: context,
    // 下拉关闭走 Navigator.pop，绕过 PopScope(canPop:false)：
    // 保存/上传中必须禁用手势，避免结果丢失（关闭按钮/取消键仍受 _busy 保护）
    enableDrag: false,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Colors.transparent,
    builder: (_) => ExportFileSheet(
      content: content,
      filePath: filePath,
      fileName: fileName,
      uploadFileName: uploadFileName,
      contentType: contentType,
      subject: subject,
      deleteTempFileOnClose: deleteTempFileOnClose,
      fileService: fileService,
      ruleService: ruleService,
      passphraseType: passphraseType,
    ),
  );
}

/// 通用导出目标底部 Sheet
class ExportFileSheet extends ConsumerStatefulWidget {
  const ExportFileSheet({
    super.key,
    this.content,
    this.filePath,
    required this.fileName,
    this.uploadFileName,
    this.contentType = 'application/json',
    this.subject,
    this.deleteTempFileOnClose = false,
    this.fileService,
    this.ruleService,
    this.passphraseType,
  }) : assert(
         (content == null) != (filePath == null),
         'content 与 filePath 必须且只能提供一个',
       );

  /// 导出内容（文本模式，与 [filePath] 互斥）
  final String? content;

  /// 既有文件路径（filePath 模式，与 [content] 互斥）
  final String? filePath;

  /// 系统另存使用的文件名
  final String fileName;

  /// 上传直链使用的文件名（为空时沿用 [fileName]）
  final String? uploadFileName;

  /// 上传内容类型
  final String contentType;

  /// Sheet 标题
  final String? subject;

  /// Sheet 关闭时是否删除 [filePath]（仅限调用方自建临时文件）
  final bool deleteTempFileOnClose;

  /// 落盘服务（测试注入）
  final ExportFileService? fileService;

  /// 直链上传规则服务（测试注入）
  final DirectLinkUploadRuleService? ruleService;

  /// 规则类型（非 null 时上传成功后展示「复制口令」，批25）
  final SourcePassphraseType? passphraseType;

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

  /// 面向用户的错误文案（已剥离 FFI 前缀 / 连接错误已映射，见 errorMessage）
  String? _error;

  /// 原始错误文本（含 `FFI error:` / `os error 111` 等底层串，供次要行与
  /// 「复制错误」排障）。与 [_error] 相同时不重复展示。
  String? _errorDetail;

  /// 错误面板标题
  String get _errorTitle =>
      _failedAction == _FailureAction.upload ? '上传失败' : '保存失败';

  /// 上传成功后的直链与规则注释
  String? _uploadedUrl;
  String? _uploadedSummary;

  /// 复制反馈：成功时按钮文案短暂变为「已复制」
  Timer? _copyTimer;
  bool _copied = false;

  /// 复制失败的真实原因（Sheet 内联展示，不依赖底层 SnackBar）
  String? _copyError;

  /// 系统临时目录根（initState 预解析，供 dispose 同步清理时做护栏判断）
  String? _tempDirPath;

  /// 已记住的 Android 保存文件夹（批26：首次保存弹选择并记住，
  /// 之后直接写入；「换个保存位置」可随时重选）
  SaveTreeSelection? _savedTree;

  bool get _busy => _saving || _uploading;

  /// 是否 Android（目录树保存位置仅 Android 有）
  bool get _isAndroid =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  /// 上传实际使用的文件名（参考版规则上传固定 export_rules.json）
  String get _uploadFileName => widget.uploadFileName ?? widget.fileName;

  @override
  void initState() {
    super.initState();
    _fileService = widget.fileService ?? const ExportFileService();
    _ruleService =
        widget.ruleService ??
        DirectLinkUploadRuleService(ref.read(bookApiProvider));
    if (_isAndroid) {
      // 展示当前保存位置（未记住时提示首次保存需选文件夹）
      unawaited(_loadSavedTree());
    }
    if (widget.deleteTempFileOnClose &&
        (widget.filePath?.isNotEmpty ?? false)) {
      // 预解析临时目录：dispose 不能 await，提前拿到根路径后可同步清理
      unawaited(_resolveTempDirectory());
    }
  }

  /// 读取已记住的保存文件夹（失败按「未记住」处理，不打断导出）
  Future<void> _loadSavedTree() async {
    final tree = await _fileService.rememberedSaveDirectory();
    if (!mounted || tree == null) return;
    setState(() => _savedTree = tree);
  }

  /// 解析系统临时目录（失败仅留痕迹，清理时再做一次护栏校验）
  Future<void> _resolveTempDirectory() async {
    try {
      final dir = await getTemporaryDirectory();
      _tempDirPath = dir.path;
    } catch (e) {
      debugPrint('导出临时目录解析失败：$e');
    }
  }

  @override
  void dispose() {
    _copyTimer?.cancel();
    // 批16e 回修 P2-1：临时文件统一在 Sheet 关闭时清理，覆盖另存成功/
    // 另存取消/上传成功/上传失败后放弃/外部关闭全部路径；另存与上传都在
    // 关闭前已消费文件内容，此时删除安全。上传失败后面板仍打开、可重试，
    // 因此不在这里之前提前删除。
    _cleanupTempFileOnClose();
    super.dispose();
  }

  /// 关闭时清理调用方自建的临时文件（仅 [ExportFileSheet.deleteTempFileOnClose]
  /// 为 true 且处于 filePath 模式时执行；实际删除含临时目录护栏）
  void _cleanupTempFileOnClose() {
    if (!widget.deleteTempFileOnClose) return;
    final path = widget.filePath;
    if (path == null || path.isEmpty) return;
    final tempDir = _tempDirPath;
    if (tempDir != null) {
      // 常规路径：同步清理，关闭即完成（含「仅限临时目录内」护栏）
      _fileService.deleteTemporaryFileSync(tempDirPath: tempDir, path: path);
      return;
    }
    // 极端时序（首帧未完成即关闭）：退化为异步清理，护栏不变
    unawaited(_fileService.deleteTemporaryFile(path));
  }

  /// 清除复制反馈（进入保存/上传前调用，避免旧状态串台）
  void _resetCopyFeedback() {
    _copyTimer?.cancel();
    _copied = false;
    _copyError = null;
  }

  /// 复制成功：按钮文案短暂显示「已复制」
  void _markCopied() {
    _copyTimer?.cancel();
    setState(() {
      _copied = true;
      _copyError = null;
    });
    _copyTimer = Timer(const Duration(milliseconds: 1500), () {
      if (!mounted) return;
      setState(() => _copied = false);
    });
  }

  /// 复制失败：内联展示真实原因
  void _markCopyFailed(Object error) {
    _copyTimer?.cancel();
    setState(() {
      _copied = false;
      _copyError = '复制失败：${errorMessage(error)}';
    });
  }

  /// 复制文本到剪贴板（结果以内联反馈呈现）
  Future<void> _copy(String text) async {
    try {
      await Clipboard.setData(ClipboardData(text: text));
    } catch (e) {
      if (!mounted) return;
      _markCopyFailed(e);
      return;
    }
    if (!mounted) return;
    _markCopied();
  }

  /// 保存到本地（系统另存）
  ///
  /// content 模式写文本字节；filePath 模式复制既有文件字节（二进制安全）。
  /// [chooseTree] 为 true 时强制重新选择保存文件夹（Android 目录树）。
  Future<void> _saveToLocal({bool chooseTree = false}) async {
    _resetCopyFeedback();
    setState(() {
      _saving = true;
      _failedAction = null;
      _error = null;
      _errorDetail = null;
    });
    SaveFileResult? saved;
    try {
      final filePath = widget.filePath;
      saved = filePath == null
          ? await _fileService.saveToLocal(
              fileName: widget.fileName,
              content: widget.content!,
              chooseTree: chooseTree,
            )
          : await _fileService.saveExistingFile(
              sourcePath: filePath,
              fileName: widget.fileName,
              chooseTree: chooseTree,
            );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _failedAction = _FailureAction.save;
        _error = errorMessage(e);
        _errorDetail = errorDetailMessage(e);
      });
      return;
    }
    if (!mounted) return;
    setState(() => _saving = false);
    if (saved == null) {
      // 用户在系统另存对话框/目录选择器取消：关闭 Sheet，不提示
      Navigator.pop(context);
      return;
    }
    Navigator.pop(
      context,
      ExportFileResult.savedLocal(
        saved.location,
        message: _fileService.savedMessage(
          saved: saved,
          requestedFileName: widget.fileName,
        ),
      ),
    );
  }

  /// 选择/更换 Android 保存文件夹（不立即保存）
  ///
  /// 返回用户选中的目录；取消或失败（失败时切到错误面板）返回 null。
  Future<SaveTreeSelection?> _pickSaveDirectory() async {
    try {
      final tree = await _fileService.chooseSaveDirectory();
      if (!mounted || tree == null) return tree;
      setState(() => _savedTree = tree);
      return tree;
    } catch (e) {
      if (!mounted) return null;
      setState(() {
        _failedAction = _FailureAction.save;
        _error = errorMessage(e);
        _errorDetail = errorDetailMessage(e);
      });
      return null;
    }
  }

  /// 保存失败后「换个位置」：选新目录成功则立即重试保存
  Future<void> _changeLocationAndRetry() async {
    final tree = await _pickSaveDirectory();
    if (!mounted || tree == null) return;
    await _saveToLocal();
  }

  /// 上传直链（生效规则 → §2.51 directLinkUpload）
  ///
  /// filePath 模式下按路径上传（content 传 null）。临时文件不在此处删除：
  /// 上传失败时 Sheet 仍打开供重试，需保留文件；关闭时由 dispose 统一清理。
  Future<void> _upload() async {
    _resetCopyFeedback();
    setState(() {
      _uploading = true;
      _failedAction = null;
      _error = null;
      _errorDetail = null;
    });
    try {
      final rule = await _ruleService.getEffectiveRule();
      final filePath = widget.filePath;
      final url = await ref
          .read(bookApiProvider)
          .directLinkUpload(
            ruleJson: rule.toJsonString(),
            fileName: _uploadFileName,
            contentType: widget.contentType,
            content: filePath == null ? widget.content : null,
            filePath: filePath,
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
        _errorDetail = errorDetailMessage(e);
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
                    // 复制失败内联反馈：Sheet 内不依赖底层 Scaffold 的 SnackBar
                    if (_copyError != null)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Icon(
                              Symbols.error_outline_rounded,
                              size: 16,
                              color: cs.error,
                            ),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Text(
                                _copyError!,
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: cs.error,
                                ),
                              ),
                            ),
                          ],
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
  ///
  /// [批26] Android 额外展示当前保存位置并提供「换个保存位置」入口：
  /// 首次保存由原生弹目录选择器，之后固定在记住的目录写入。
  Widget _buildOptions(ThemeData theme) {
    final savedDirectory = _displaySavedTree();
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _OptionTile(
          icon: Symbols.save_alt_rounded,
          title: '保存到本地',
          subtitle: !_isAndroid
              ? '通过系统保存对话框选择保存位置'
              : savedDirectory == null
              ? '首次保存需选择保存文件夹，之后沿用'
              : '保存到「$savedDirectory」',
          onTap: _saveToLocal,
        ),
        const SizedBox(height: 8),
        if (_isAndroid)
          _OptionTile(
            icon: Symbols.drive_file_move_rounded,
            title: '换个保存位置',
            subtitle: savedDirectory == null
                ? '选择文件保存到哪个文件夹'
                : '当前：$savedDirectory · 点击重新选择文件夹',
            onTap: () {
              unawaited(_pickSaveDirectory());
            },
          ),
        if (_isAndroid) const SizedBox(height: 8),
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

  /// 当前保存目录的展示文案（未记住时回落到 URI/默认文案）
  String? _displaySavedTree() {
    final tree = _savedTree;
    if (tree == null) return null;
    final display = tree.displayPath?.trim();
    return (display == null || display.isEmpty) ? tree.location : display;
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
        // 批25：规则类导出在上传成功后提供「复制口令」（对齐原版
        // `sourceSharePassphraseButton` 仅在 url.isAbsUrl() 时出现的语义）
        if (widget.passphraseType != null &&
            SourceSharePassphrase.canEncode(_uploadedUrl!)) ...[
          const SizedBox(height: 12),
          _OptionTile(
            icon: Symbols.key_rounded,
            title: '复制口令',
            subtitle: '生成可粘贴到阅读「口令导入」的分享口令，可设置有效期',
            onTap: _sharePassphrase,
          ),
        ],
      ],
    );
  }

  /// 生成并复制分享口令（有效期在弹窗内输入，默认永久）
  Future<void> _sharePassphrase() async {
    final url = _uploadedUrl;
    final type = widget.passphraseType;
    if (url == null || type == null) return;
    await showSourceSharePassphraseDialog(context, url: url, type: type);
  }

  /// 失败：面向用户的错误文案 + 原始文本次要行（均可复制/重试）
  ///
  /// [errorMessage] 已剥离 `FFI error:` 前缀并把连接类底层错误映射为中文
  /// （D4）；当原始文本与友好文案不同时，在其下以次要行保留原文（可长按
  /// 复制，「复制错误」按钮也复制原文）供排障。
  Widget _buildErrorPanel(ThemeData theme) {
    final cs = theme.colorScheme;
    final detail = _errorDetail;
    final showDetail = detail != null && detail != _error;
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
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SelectableText(
                _error!,
                style: TextStyle(color: cs.onErrorContainer),
              ),
              if (showDetail) ...[
                const SizedBox(height: 8),
                Text(
                  '原始错误：',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: cs.onErrorContainer.withValues(alpha: 0.7),
                  ),
                ),
                const SizedBox(height: 2),
                SelectableText(
                  detail,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: cs.onErrorContainer.withValues(alpha: 0.8),
                    fontFamily: 'Menlo',
                    fontFamilyFallback: const ['Consolas', 'monospace'],
                  ),
                ),
              ],
            ],
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
              onPressed: () => _copy(_uploadedUrl!),
              icon: Icon(
                _copied ? Symbols.check_rounded : Symbols.content_copy_rounded,
                size: 18,
              ),
              label: Text(_copied ? '已复制' : '复制链接'),
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
      // [批26] 保存失败时提供「换个位置」：重选 Android 保存文件夹后立即
      // 重试；上传失败不展示（与保存位置无关）
      final canChangeSaveLocation =
          _isAndroid && _failedAction == _FailureAction.save;
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (canChangeSaveLocation) ...[
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: _changeLocationAndRetry,
                icon: const Icon(Symbols.drive_file_move_rounded, size: 18),
                label: const Text('换个位置'),
              ),
            ),
            const SizedBox(height: 8),
          ],
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  // 复制原文（含底层错误码），排障信息最完整
                  onPressed: () => _copy(_errorDetail ?? _error!),
                  icon: Icon(
                    _copied
                        ? Symbols.check_rounded
                        : Symbols.content_copy_rounded,
                    size: 18,
                  ),
                  label: Text(_copied ? '已复制' : '复制错误'),
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
                child: FilledButton(onPressed: _retry, child: const Text('重试')),
              ),
            ],
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
