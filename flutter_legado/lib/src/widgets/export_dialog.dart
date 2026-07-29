import 'package:flutter/material.dart';
import '../services/export_service.dart';
import '../services/rust_api.dart';

/// 导出对话框
///
/// 提供完整的导出配置界面，包括：
/// - 格式选择器（RadioGroup: TXT/EPUB/HTML）
/// - 字符集选择器（DropdownButton: UTF-8/GBK/Big5）
/// - TOC 复选框（includeToc）
/// - 进度指示器（ProgressIndicator）
/// - 取消/确认按钮
class ExportDialog extends StatefulWidget {
  /// 书籍 URL
  final String bookUrl;

  /// 书籍名称（用于显示）
  final String bookName;

  /// 导出服务实例
  final ExportService exportService;

  /// Rust API 实例（用于 WebDAV 上传）
  final RustApi rustApi;

  /// WebDAV 配置 JSON（可选）
  final String? webDavConfig;

  const ExportDialog({
    super.key,
    required this.bookUrl,
    required this.bookName,
    required this.exportService,
    required this.rustApi,
    this.webDavConfig,
  });

  @override
  State<ExportDialog> createState() => _ExportDialogState();
}

class _ExportDialogState extends State<ExportDialog> {
  // 选中格式
  String _selectedFormat = 'txt';

  // 选中的字符集
  String _selectedEncoding = 'UTF-8';

  // 是否包含目录
  bool _includeToc = true;

  // 是否启用 WebDAV 上传
  bool _enableWebDav = false;

  // 导出状态
  ExportStatus _status = ExportStatus.idle;

  // 进度值（0.0-1.0）
  double _progress = 0.0;

  // 进度文本
  String _progressText = '';

  @override
  void initState() {
    super.initState();
    // 默认从支持的格式中选择第一个
    if (widget.exportService.supportedFormats.contains('epub')) {
      _selectedFormat = 'epub';
    } else {
      _selectedFormat = 'txt';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      child: Container(
        constraints: const BoxConstraints(maxWidth: 400),
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 标题
            Text(
              '导出${widget.bookName}',
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
            ),
            const SizedBox(height: 24),

            // 格式选择
            _buildFormatSelector(),
            const Divider(height: 32),

            // 字符集选择
            _buildEncodingSelector(),
            const Divider(height: 32),

            // TOC 选项
            _buildTocCheckbox(),
            const Divider(height: 32),

            // WebDAV 选项
            _buildWebDavCheckbox(),
            const Divider(height: 32),

            // 预览信息
            if (_status == ExportStatus.ready) ...[
              _buildPreviewInfo(),
              const Divider(height: 32),
            ],

            // 进度指示器
            if (_status == ExportStatus.exporting) ...[
              _buildProgressIndicator(),
              const SizedBox(height: 16),
            ],

            // 操作按钮
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: _status == ExportStatus.exporting ? null : () => Navigator.pop(context),
                  child: const Text('取消'),
                ),
                const SizedBox(width: 12),
                ElevatedButton(
                  onPressed: _handleConfirm,
                  child: const Text('确认'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// 格式选择器
  Widget _buildFormatSelector() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('导出格式',
            style: TextStyle(fontWeight: FontWeight.w500)),
        const SizedBox(height: 8),
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: widget.exportService.supportedFormats.map((format) {
            return ChoiceChip(
              label: Text(format.toUpperCase()),
              selected: _selectedFormat == format,
              onSelected: (selected) {
                setState(() {
                  _selectedFormat = format;
                });
              },
            );
          }).toList(),
        ),
      ],
    );
  }

  /// 字符集选择器
  Widget _buildEncodingSelector() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('字符编码',
            style: TextStyle(fontWeight: FontWeight.w500)),
        const SizedBox(height: 8),
        DropdownButton<String>(
          value: _selectedEncoding,
          isExpanded: true,
          items: widget.exportService.supportedEncodings.map((encoding) {
            return DropdownMenuItem<String>(
              value: encoding,
              child: Text(encoding),
            );
          }).toList(),
          onChanged: (value) {
            setState(() {
              _selectedEncoding = value ?? 'UTF-8';
            });
          },
        ),
      ],
    );
  }

  /// TOC 复选框
  Widget _buildTocCheckbox() {
    return CheckboxListTile(
      title: const Text('包含目录'),
      subtitle: const Text('导出时包含书籍的目录结构'),
      value: _includeToc,
      onChanged: (value) {
        setState(() {
          _includeToc = value ?? true;
        });
      },
      contentPadding: EdgeInsets.zero,
    );
  }

  /// WebDAV 复选框
  Widget _buildWebDavCheckbox() {
    if (widget.webDavConfig == null || widget.webDavConfig!.isEmpty) {
      return const SizedBox.shrink();
    }

    return CheckboxListTile(
      title: const Text('上传到 WebDAV'),
      subtitle: const Text('导出完成后自动上传到远程服务器'),
      value: _enableWebDav,
      onChanged: (value) {
        setState(() {
          _enableWebDav = value ?? false;
        });
      },
      contentPadding: EdgeInsets.zero,
    );
  }

  /// 预览信息
  Widget _buildPreviewInfo() {
    return FutureBuilder<Map<String, dynamic>>(
      future: _getPreviewInfo(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }

        if (snapshot.hasError) {
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(
              '获取预览信息失败：${snapshot.error}',
              style: const TextStyle(color: Colors.red),
            ),
          );
        }

        final data = snapshot.data;
        if (data != null && data['success'] == true) {
          final fileName = data['file_name'] as String? ?? '';
          final chapterCount = int.tryParse(data['error']?.split(': ').last ?? '0') ?? 0;

          return Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.folder_special,
                        size: 20, color: Theme.of(context).primaryIconTheme.color),
                    const SizedBox(width: 8),
                    Text(
                      fileName,
                      style: Theme.of(context).textTheme.bodyMedium,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  '章节数：$chapterCount',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          );
        }

        return const SizedBox.shrink();
      },
    );
  }

  /// 进度指示器
  Widget _buildProgressIndicator() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('正在导出...',
            style: TextStyle(fontWeight: FontWeight.w500)),
        const SizedBox(height: 12),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            value: _progress.clamp(0.0, 1.0),
            backgroundColor: Colors.grey[200],
            valueColor: AlwaysStoppedAnimation<Color>(
              Theme.of(context).primaryColor,
            ),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          _progressText,
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    );
  }

  /// 获取预览信息
  Future<Map<String, dynamic>> _getPreviewInfo() async {
    return await widget.exportService.getExportInfo(
      bookUrl: widget.bookUrl,
      format: _selectedFormat,
    );
  }

  /// 确认导出
  Future<void> _handleConfirm() async {
    // 验证
    if (!widget.exportService.supportedFormats.contains(_selectedFormat)) {
      _showError('不支持的导出格式');
      return;
    }

    setState(() {
      _status = ExportStatus.exploring;
      _progress = 0.0;
      _progressText = '开始导出...';
    });

    try {
      // 调用导出 API
      final result = await widget.exportService.export(
        bookUrl: widget.bookUrl,
        format: _selectedFormat,
        includeToc: _includeToc,
        encoding: _selectedEncoding,
      );

      // 更新进度
      setState(() {
        _progress = 0.8;
        _progressText = '导出完成，准备上传...';
      });

      // 检查是否需要上传到 WebDAV
      if (_enableWebDav && widget.webDavConfig != null) {
        try {
          final data = result['data_base64'] as String?;
          final fileName = result['file_name'] as String? ?? 'export';

          if (data != null) {
            setState(() {
              _progressText = '上传到 WebDAV...';
            });

            await widget.exportService.webdavUpload(
              widget.webDavConfig!,
              '/books/$fileName',
              data,
            );

            setState(() {
              _progress = 1.0;
              _progressText = '导出并上传成功！';
            });
          }
        } catch (e) {
          debugPrint('[ExportDialog] WebDAV 上传失败：$e');
          setState(() {
            _progress = 1.0;
            _progressText = '导出成功，但 WebDAV 上传失败';
          });
        }
      } else {
        setState(() {
          _progress = 1.0;
          _progressText = '导出成功！';
        });
      }

      // 延迟后关闭对话框
      await Future.delayed(const Duration(milliseconds: 1500));
      if (mounted) {
        Navigator.pop(context, result);
      }
    } catch (e) {
      _showError(e.toString());
    }
  }

  /// 显示错误提示
  void _showError(String message) {
    setState(() {
      _status = ExportStatus.error;
      _progressText = message;
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(message),
          backgroundColor: Colors.red,
        ),
      );
    });
  }
}

/// 导出状态枚举
enum ExportStatus {
  idle,       // 初始状态
  exploring,  // 正在查看
  ready,      // 已准备好
  exporting,  // 正在导出
  error,      // 错误状态
}
