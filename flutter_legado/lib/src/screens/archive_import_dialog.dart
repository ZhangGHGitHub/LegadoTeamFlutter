import 'dart:io';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:path_provider/path_provider.dart';

import '../providers/bookshelf/bookshelf_notifier.dart';
import '../providers/providers.dart';
import '../services/book_api.dart';
import '../utils/error_message.dart';
import '../utils/legado_deep_link.dart';

/// 压缩包类型：决定列表/解压调用与是否显示密码框
enum _ArchiveKind { zip, rar, sevenZ }

/// 支持的编码列表（用于 TXT 子文件编码选择）
const _supportedEncodings = [
  'UTF-8',
  'GBK',
  'GB2312',
  'Big5',
  'ISO-8859-1',
  'ASCII',
];

/// 压缩包导入对话框
///
/// 显示压缩包（zip/rar/7z）内书籍文件列表，支持多选导入、编码检测与编码选择。
/// 对应安卓端 BaseImportBookActivity.onArchiveFileClick 逻辑；7z 不支持加密/分卷，
/// 因此不显示密码框。
class ArchiveImportDialog extends ConsumerStatefulWidget {
  /// 压缩包文件路径
  final String archivePath;

  const ArchiveImportDialog({super.key, required this.archivePath});

  @override
  ConsumerState<ArchiveImportDialog> createState() =>
      _ArchiveImportDialogState();
}

class _ArchiveImportDialogState extends ConsumerState<ArchiveImportDialog> {
  /// 经 Riverpod 注入层获取 BookApi（对齐 §0.2 铁律，不直接实例化 RustApi）
  BookApi get _api => ref.read(bookApiProvider);

  /// 压缩包内的书籍文件名列表
  List<String> _fileNames = [];

  /// 已选中的文件名集合
  final Set<String> _selected = {};

  /// 加载状态
  bool _loading = true;

  /// 错误信息
  String? _error;

  /// 导入中状态
  bool _importing = false;

  /// 导入成功数（仅 try 成功分支自增；失败不计入）
  int _importDone = 0;

  /// 导入失败数
  int _importFailed = 0;

  /// 失败明细（`书名：原因`），结果提示取首条并汇总条数
  final List<String> _importFailures = [];

  /// 导入总数（用户选中数）
  int _importTotal = 0;

  /// 已处理数（成功 + 失败），用于导入进度文本
  int get _importProcessed => _importDone + _importFailed;

  /// 选择的编码（针对 TXT 子文件）
  String _selectedEncoding = 'UTF-8';

  /// 编码检测结果映射（文件名 → 编码信息）
  final Map<String, String> _detectedEncodings = {};

  /// 是否正在检测编码
  bool _detecting = false;

  /// RAR 密码（可选）
  final TextEditingController _passwordController = TextEditingController();

  /// 压缩包类型（zip/rar/7z）
  _ArchiveKind get _kind =>
      switch (LegadoDeepLink.extensionOf(widget.archivePath)) {
        'rar' => _ArchiveKind.rar,
        '7z' => _ArchiveKind.sevenZ,
        _ => _ArchiveKind.zip,
      };

  /// 是否为 RAR 格式（仅 RAR 显示密码框）
  bool get _isRar => _kind == _ArchiveKind.rar;

  @override
  void initState() {
    super.initState();
    _loadFileList();
  }

  @override
  void dispose() {
    _passwordController.dispose();
    super.dispose();
  }

  /// 清理编码检测使用的临时解压目录（幂等；失败忽略）
  Future<void> _cleanupTempDir(String? path) async {
    if (path == null) return;
    try {
      final dir = Directory(path);
      if (await dir.exists()) {
        await dir.delete(recursive: true);
      }
    } catch (_) {
      // 忽略清理失败
    }
  }

  /// 获取压缩包内的书籍文件列表
  Future<void> _loadFileList() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final List<String> files;
      switch (_kind) {
        case _ArchiveKind.rar:
          final pwd = _passwordController.text.trim();
          files = await _api.archiveListRarFiles(
            rarPath: widget.archivePath,
            password: pwd.isEmpty ? null : pwd,
          );
        case _ArchiveKind.sevenZ:
          files = await _api.archiveList7zFiles(
            sevenZipPath: widget.archivePath,
          );
        case _ArchiveKind.zip:
          files = await _api.archiveListZipFiles(zipPath: widget.archivePath);
      }
      if (!mounted) return;
      setState(() {
        _fileNames = files;
        _loading = false;
        // 默认全选
        _selected.addAll(files);
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = errorMessage(e);
        _loading = false;
      });
    }
  }

  /// 检测选中 TXT 文件的编码
  Future<void> _detectEncoding() async {
    // 筛选出选中的 txt 文件
    final txtFiles = _selected
        .where((name) => name.toLowerCase().endsWith('.txt'))
        .toList();
    if (txtFiles.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('没有选中的 TXT 文件需要检测编码')),
      );
      return;
    }

    setState(() => _detecting = true);

    // 需要先解压才能检测编码，这里使用临时目录；
    // 无论成功、失败还是提前 return，都在 finally 中清理（批24b P3-7）
    String? extractDir;
    try {
      final tempDir = await getTemporaryDirectory();
      extractDir =
          '${tempDir.path}${Platform.pathSeparator}archive_detect_${DateTime.now().millisecondsSinceEpoch}';

      // 解压到临时目录
      final Map<String, dynamic> result;
      switch (_kind) {
        case _ArchiveKind.rar:
          final pwd = _passwordController.text.trim();
          result = await _api.archiveImportRar(
            rarPath: widget.archivePath,
            outputDir: extractDir,
            password: pwd.isEmpty ? null : pwd,
          );
        case _ArchiveKind.sevenZ:
          result = await _api.archiveImport7z(
            sevenZipPath: widget.archivePath,
            outputDir: extractDir,
          );
        case _ArchiveKind.zip:
          result = await _api.archiveImportZip(
            zipPath: widget.archivePath,
            outputDir: extractDir,
          );
      }

      if (result['success'] != true) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('解压失败: ${result['error'] ?? '未知错误'}')),
          );
        }
        return;
      }

      // 对解压后的 txt 文件逐个检测编码
      final extractedFiles =
          (result['extracted_files'] as List<dynamic>?)?.map((e) => e.toString()).toList() ?? [];
      for (final filePath in extractedFiles) {
        if (!filePath.toLowerCase().endsWith('.txt')) continue;
        final fileName = filePath.split(Platform.pathSeparator).last;
        if (!txtFiles.contains(fileName)) continue;
        try {
          final encResult = await _api.archiveDetectEncoding(filePath: filePath);
          final encoding = encResult['encoding'] as String? ?? '未知';
          final confidence = encResult['confidence'] as String? ?? '';
          if (mounted) {
            setState(() {
              _detectedEncodings[fileName] = '$encoding ($confidence)';
            });
          }
        } catch (_) {
          if (mounted) {
            setState(() {
              _detectedEncodings[fileName] = '检测失败';
            });
          }
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('编码检测失败: ${errorMessage(e)}')),
        );
      }
    } finally {
      await _cleanupTempDir(extractDir);
      if (mounted) {
        setState(() => _detecting = false);
      }
    }
  }

  /// 导入结果提示：成功数、失败数与首个失败明细
  ///
  /// 失败项的解压文件保留在「应用文档/archive_import」目录（成功书目的
  /// bookUrl 也指向该目录，不能整目录清理），提示中给出可定位路径，
  /// 用户可到「导入」页重试。
  String get _importResultMessage {
    if (_importFailures.isEmpty) {
      return '成功导入 $_importDone 本书籍';
    }
    final failed = _importFailures.length;
    final more = failed > 1 ? ' 等 $failed 本' : '';
    final detail = '${_importFailures.first}$more';
    final summary = _importDone == 0
        ? '导入失败：$detail'
        : '成功导入 $_importDone 本，$failed 本失败：$detail';
    return '$summary（解压文件保留在应用文档/archive_import 目录，可重试）';
  }

  /// 确认导入：解压压缩包并将书籍添加到书架
  Future<void> _confirmImport() async {
    if (_selected.isEmpty || _importing) return;

    setState(() {
      _importing = true;
      _importDone = 0;
      _importFailed = 0;
      _importFailures.clear();
      _importTotal = _selected.length;
    });

    try {
      // 解压到应用文档目录下的 archive_import 子目录
      final docsDir = await getApplicationDocumentsDirectory();
      final outputDir =
          '${docsDir.path}${Platform.pathSeparator}archive_import';
      final dir = Directory(outputDir);
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }

      // 调用 FFI 解压
      final Map<String, dynamic> result;
      switch (_kind) {
        case _ArchiveKind.rar:
          final pwd = _passwordController.text.trim();
          result = await _api.archiveImportRar(
            rarPath: widget.archivePath,
            outputDir: outputDir,
            password: pwd.isEmpty ? null : pwd,
          );
        case _ArchiveKind.sevenZ:
          result = await _api.archiveImport7z(
            sevenZipPath: widget.archivePath,
            outputDir: outputDir,
          );
        case _ArchiveKind.zip:
          result = await _api.archiveImportZip(
            zipPath: widget.archivePath,
            outputDir: outputDir,
          );
      }

      if (result['success'] != true) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('解压失败: ${result['error'] ?? '未知错误'}')),
          );
        }
        return;
      }

      // 将解压出的书籍逐个导入书架
      final extractedFiles =
          (result['extracted_files'] as List<dynamic>?)?.map((e) => e.toString()).toList() ?? [];
      if (!mounted) return;
      final notifier = ref.read(bookshelfNotifierProvider.notifier);
      // 导入期间文件列表仍可勾选/取消；先快照选中集合，避免边导入边改
      // 造成「总数 N、实际只处理 M」的计数错位
      final selectedNames = Set<String>.of(_selected);

      for (final filePath in extractedFiles) {
        final fileName = filePath.split(Platform.pathSeparator).last;
        // 只导入用户选中的文件
        if (!selectedNames.contains(fileName)) continue;

        // 如果是 TXT 文件且选择了非 UTF-8 编码，先转换编码
        if (filePath.toLowerCase().endsWith('.txt') && _selectedEncoding != 'UTF-8') {
          try {
            await _api.archiveConvertEncoding(
              filePath: filePath,
              fromEncoding: _selectedEncoding,
              toEncoding: 'utf-8',
            );
          } catch (_) {
            // 编码转换失败不阻断导入流程
          }
        }

        try {
          await notifier.importLocalBook(filePath);
          // 只有导入成功才计入成功数（修复前失败也会自增，导致假成功）
          if (mounted) {
            setState(() => _importDone++);
          }
        } catch (e) {
          // 单个文件失败不阻断整体流程，但必须计数并保留「书名：原因」
          if (mounted) {
            setState(() {
              _importFailed++;
              _importFailures.add('$fileName：${errorMessage(e)}');
            });
          }
        }
      }

      // 刷新书架
      await notifier.refresh();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(_importResultMessage)),
        );
        Navigator.of(context).pop();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('导入失败: ${errorMessage(e)}')),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _importing = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final fileName = widget.archivePath.split(Platform.pathSeparator).last;
    return AlertDialog(
      // [LAYOUT_PLAN P3] Dialog 容器 surfaceContainer 圆角 28dp（全局标尺，对齐 dialogTheme）
      backgroundColor: Theme.of(context).colorScheme.surfaceContainer,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(28),
      ),
      title: Text(
        '压缩包导入',
        style: Theme.of(context).textTheme.titleMedium,
      ),
      content: SizedBox(
        width: double.maxFinite,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 压缩包文件名
            Text(
              fileName,
              style: Theme.of(context).textTheme.bodySmall,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 8),
            // RAR 密码输入
            if (_isRar) ...[
              TextField(
                controller: _passwordController,
                // [LAYOUT_PLAN P3] 输入框走 inputDecorationTheme（不显式 border）
                decoration: const InputDecoration(
                  hintText: 'RAR 密码（可选）',
                  isDense: true,
                ),
                obscureText: true,
              ),
              const SizedBox(height: 8),
            ],
            // 文件列表区域
            Flexible(
              child: _buildFileListContent(),
            ),
            const SizedBox(height: 8),
            // 编码选择行
            _buildEncodingRow(),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _importing ? null : () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _importing || _selected.isEmpty || _loading
              ? null
              : _confirmImport,
          child: _importing
              ? Text('导入中 $_importProcessed/$_importTotal')
              : Text('导入 (${_selected.length})'),
        ),
      ],
    );
  }

  /// 文件列表内容区域
  Widget _buildFileListContent() {
    if (_loading) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: CircularProgressIndicator(),
        ),
      );
    }
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Symbols.error_rounded, color: Theme.of(context).colorScheme.error),
            const SizedBox(height: 8),
            Text('加载失败', style: Theme.of(context).textTheme.bodyMedium),
            const SizedBox(height: 4),
            Text(
              _error!,
              style: Theme.of(context).textTheme.bodySmall,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 8),
            FilledButton.tonal(
              onPressed: _loadFileList,
              child: const Text('重试'),
            ),
          ],
        ),
      );
    }
    if (_fileNames.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text('压缩包内没有可导入的书籍文件'),
        ),
      );
    }
    return ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 300),
      child: ListView.builder(
        shrinkWrap: true,
        itemCount: _fileNames.length,
        itemBuilder: (context, index) {
          final name = _fileNames[index];
          final isSelected = _selected.contains(name);
          final isTxt = name.toLowerCase().endsWith('.txt');
          final detectedEnc = _detectedEncodings[name];
          return CheckboxListTile(
            // [LAYOUT_PLAN P3] 组内行 vertical12/horizontal8（全局行规范）
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 8,
              vertical: 12,
            ),
            value: isSelected,
            onChanged: (v) {
              setState(() {
                if (v == true) {
                  _selected.add(name);
                } else {
                  _selected.remove(name);
                }
              });
            },
            title: Text(
              name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            subtitle: isTxt && detectedEnc != null
                ? Text('编码: $detectedEnc',
                    style: Theme.of(context).textTheme.labelSmall)
                : null,
            dense: true,
            controlAffinity: ListTileControlAffinity.leading,
          );
        },
      ),
    );
  }

  /// 编码选择行（针对 TXT 子文件）
  Widget _buildEncodingRow() {
    return Row(
      children: [
        // 编码下拉选择
        Expanded(
          child: DropdownButtonFormField<String>(
            initialValue: _selectedEncoding,
            // [LAYOUT_PLAN P3] 输入框走 inputDecorationTheme（不显式 border）
            decoration: const InputDecoration(
              labelText: 'TXT 编码',
              isDense: true,
            ),
            items: _supportedEncodings
                .map((enc) => DropdownMenuItem(value: enc, child: Text(enc)))
                .toList(),
            onChanged: (v) {
              if (v != null) setState(() => _selectedEncoding = v);
            },
          ),
        ),
        const SizedBox(width: 8),
        // 检测编码按钮
        IconButton.filledTonal(
          onPressed: _detecting || _selected.isEmpty ? null : _detectEncoding,
          icon: _detecting
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Symbols.manage_search_rounded, size: 20),
          tooltip: '检测编码',
        ),
      ],
    );
  }
}
