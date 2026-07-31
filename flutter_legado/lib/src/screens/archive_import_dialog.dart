import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';

import '../providers/bookshelf_provider.dart';
import '../services/book_api.dart';
import '../services/rust_api.dart';

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
/// 显示压缩包内书籍文件列表，支持多选导入、编码检测与编码选择。
/// 对应安卓端 BaseImportBookActivity.onArchiveFileClick 逻辑。
class ArchiveImportDialog extends StatefulWidget {
  /// 压缩包文件路径
  final String archivePath;

  const ArchiveImportDialog({super.key, required this.archivePath});

  @override
  State<ArchiveImportDialog> createState() => _ArchiveImportDialogState();
}

class _ArchiveImportDialogState extends State<ArchiveImportDialog> {
  final BookApi _api = RustApi();

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

  /// 导入进度
  int _importDone = 0;
  int _importTotal = 0;

  /// 选择的编码（针对 TXT 子文件）
  String _selectedEncoding = 'UTF-8';

  /// 编码检测结果映射（文件名 → 编码信息）
  final Map<String, String> _detectedEncodings = {};

  /// 是否正在检测编码
  bool _detecting = false;

  /// RAR 密码（可选）
  final TextEditingController _passwordController = TextEditingController();

  /// 是否为 RAR 格式
  bool get _isRar {
    final ext = _extOf(widget.archivePath);
    return ext == 'rar';
  }

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

  String _extOf(String path) {
    final i = path.lastIndexOf('.');
    if (i < 0 || i == path.length - 1) return '';
    return path.substring(i + 1).toLowerCase();
  }

  /// 获取压缩包内的书籍文件列表
  Future<void> _loadFileList() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final List<String> files;
      if (_isRar) {
        final pwd = _passwordController.text.trim();
        files = await _api.archiveListRarFiles(
          rarPath: widget.archivePath,
          password: pwd.isEmpty ? null : pwd,
        );
      } else {
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
        _error = e.toString();
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

    // 需要先解压才能检测编码，这里使用临时目录
    try {
      final tempDir = await getTemporaryDirectory();
      final extractDir =
          '${tempDir.path}${Platform.pathSeparator}archive_detect_${DateTime.now().millisecondsSinceEpoch}';

      // 解压到临时目录
      final Map<String, dynamic> result;
      if (_isRar) {
        final pwd = _passwordController.text.trim();
        result = await _api.archiveImportRar(
          rarPath: widget.archivePath,
          outputDir: extractDir,
          password: pwd.isEmpty ? null : pwd,
        );
      } else {
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

      // 清理解压的临时文件
      try {
        final dir = Directory(extractDir);
        if (await dir.exists()) {
          await dir.delete(recursive: true);
        }
      } catch (_) {
        // 忽略清理失败
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('编码检测失败: $e')),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _detecting = false);
      }
    }
  }

  /// 确认导入：解压压缩包并将书籍添加到书架
  Future<void> _confirmImport() async {
    if (_selected.isEmpty || _importing) return;

    setState(() {
      _importing = true;
      _importDone = 0;
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
      if (_isRar) {
        final pwd = _passwordController.text.trim();
        result = await _api.archiveImportRar(
          rarPath: widget.archivePath,
          outputDir: outputDir,
          password: pwd.isEmpty ? null : pwd,
        );
      } else {
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
      final provider = context.read<BookshelfProvider>();

      for (final filePath in extractedFiles) {
        final fileName = filePath.split(Platform.pathSeparator).last;
        // 只导入用户选中的文件
        if (!_selected.contains(fileName)) continue;

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
          await provider.importLocalBook(filePath);
        } catch (_) {
          // 单个文件导入失败不阻断整体流程
        }

        if (mounted) {
          setState(() => _importDone++);
        }
      }

      // 刷新书架
      await provider.loadBooks();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('成功导入 $_importDone 本书籍')),
        );
        Navigator.of(context).pop();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('导入失败: $e')),
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
                decoration: const InputDecoration(
                  hintText: 'RAR 密码（可选）',
                  isDense: true,
                  border: OutlineInputBorder(),
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
              ? Text('导入中 $_importDone/$_importTotal')
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
            Icon(Icons.error_outline, color: Theme.of(context).colorScheme.error),
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
            decoration: const InputDecoration(
              labelText: 'TXT 编码',
              isDense: true,
              border: OutlineInputBorder(),
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
              : const Icon(Icons.manage_search, size: 20),
          tooltip: '检测编码',
        ),
      ],
    );
  }
}
