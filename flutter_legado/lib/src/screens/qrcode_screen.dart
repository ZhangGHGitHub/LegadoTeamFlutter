import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 扫码结果类型
enum _ScanResultType { legadoUrl, httpUrl, sourceJson, text }

/// 二维码扫描页面
///
/// 当前构建未包含相机扫码组件（mobile_scanner），桌面端提供手动输入模式；
/// 扫码/输入结果会被解析为：legado 协议链接 / HTTP 订阅 URL / 书源 JSON / 口令。
/// 确认后可将内容返回给调用方（如关联导入页）。
class QrcodeScreen extends StatefulWidget {
  const QrcodeScreen({super.key});

  @override
  State<QrcodeScreen> createState() => _QrcodeScreenState();
}

class _QrcodeScreenState extends State<QrcodeScreen> {
  final _inputController = TextEditingController();
  String? _rawContent;

  @override
  void dispose() {
    _inputController.dispose();
    super.dispose();
  }

  /// 解析内容类型
  _ScanResultType _detectType(String content) {
    final trimmed = content.trim();
    if (trimmed.startsWith('legado://')) return _ScanResultType.legadoUrl;
    if (trimmed.startsWith('http://') || trimmed.startsWith('https://')) {
      return _ScanResultType.httpUrl;
    }
    if (trimmed.startsWith('[') || trimmed.startsWith('{')) {
      try {
        final decoded = jsonDecode(trimmed);
        if (decoded is List && decoded.isNotEmpty) {
          return _ScanResultType.sourceJson;
        }
        if (decoded is Map &&
            (decoded.containsKey('bookSourceUrl') ||
                decoded.containsKey('sourceUrl') ||
                decoded.containsKey('bookSourceName'))) {
          return _ScanResultType.sourceJson;
        }
      } catch (_) {
        // 非 JSON，按文本处理
      }
    }
    return _ScanResultType.text;
  }

  String _typeLabel(_ScanResultType type) {
    switch (type) {
      case _ScanResultType.legadoUrl:
        return 'Legado 导入链接';
      case _ScanResultType.httpUrl:
        return 'HTTP 订阅地址';
      case _ScanResultType.sourceJson:
        return '书源 JSON';
      case _ScanResultType.text:
        return '口令 / 文本';
    }
  }

  IconData _typeIcon(_ScanResultType type) {
    switch (type) {
      case _ScanResultType.legadoUrl:
        return Icons.link;
      case _ScanResultType.httpUrl:
        return Icons.cloud_outlined;
      case _ScanResultType.sourceJson:
        return Icons.data_object;
      case _ScanResultType.text:
        return Icons.text_snippet_outlined;
    }
  }

  Future<void> _pasteFromClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim() ?? '';
    if (text.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('剪贴板为空')),
        );
      }
      return;
    }
    setState(() {
      _inputController.text = text;
      _rawContent = text;
    });
  }

  void _confirm() {
    final content = _inputController.text.trim();
    if (content.isEmpty) return;
    Navigator.of(context).pop(content);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('扫码导入')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _buildCameraPlaceholder(theme),
          const SizedBox(height: 20),
          Text('手动输入', style: theme.textTheme.titleSmall),
          const SizedBox(height: 8),
          TextField(
            controller: _inputController,
            maxLines: 3,
            decoration: InputDecoration(
              hintText: '粘贴或输入二维码内容：书源 URL / legado:// 链接 / 书源 JSON / 口令',
              border: const OutlineInputBorder(),
              suffixIcon: IconButton(
                icon: const Icon(Icons.paste),
                tooltip: '从剪贴板粘贴',
                onPressed: _pasteFromClipboard,
              ),
            ),
            onChanged: (v) => setState(() => _rawContent = v.trim()),
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed:
                (_rawContent?.isNotEmpty ?? false) ? _confirm : null,
            icon: const Icon(Icons.check),
            label: const Text('使用该内容'),
          ),
          if (_rawContent != null && _rawContent!.isNotEmpty) ...[
            const SizedBox(height: 20),
            _buildResultCard(theme, _rawContent!),
          ],
        ],
      ),
    );
  }

  /// 相机预览占位（未集成 mobile_scanner 时降级提示）
  Widget _buildCameraPlaceholder(ThemeData theme) {
    return Container(
      height: 200,
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Stack(
            alignment: Alignment.center,
            children: [
              Icon(Icons.qr_code_scanner, size: 72,
                  color: theme.colorScheme.outline),
              Icon(Icons.cameraswitch_outlined, size: 24,
                  color: theme.colorScheme.outline),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            '当前构建未启用相机扫码',
            style: theme.textTheme.titleSmall,
          ),
          const SizedBox(height: 4),
          Text(
            '桌面端请使用下方手动输入模式',
            style: theme.textTheme.bodySmall,
          ),
        ],
      ),
    );
  }

  Widget _buildResultCard(ThemeData theme, String content) {
    final type = _detectType(content);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(_typeIcon(type), size: 20,
                    color: theme.colorScheme.primary),
                const SizedBox(width: 8),
                Text('识别结果', style: theme.textTheme.titleSmall),
                const Spacer(),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.secondaryContainer,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    _typeLabel(type),
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSecondaryContainer,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              content,
              style: theme.textTheme.bodySmall?.copyWith(
                fontFamily: 'monospace',
              ),
              maxLines: 4,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 8),
            if (type == _ScanResultType.sourceJson)
              Text(
                _describeSourceJson(content),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.secondary,
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// 提取书源 JSON 的摘要信息
  String _describeSourceJson(String content) {
    try {
      final decoded = jsonDecode(content);
      if (decoded is List) {
        return '包含 ${decoded.length} 个源';
      }
      if (decoded is Map) {
        final name = decoded['bookSourceName'] ?? decoded['sourceName'] ?? '';
        return name.toString().isEmpty ? '单个源' : '源：$name';
      }
    } catch (_) {}
    return '';
  }
}
