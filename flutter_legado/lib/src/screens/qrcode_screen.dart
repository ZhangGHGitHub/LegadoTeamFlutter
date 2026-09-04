import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import '../widgets/legado_app_bar.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

/// 扫码结果类型
enum _ScanResultType { legadoUrl, httpUrl, sourceJson, text }

/// 二维码扫描页面
///
/// 移动端（Android/iOS）启用相机实时扫码（mobile_scanner）；
/// 桌面端（Windows/Linux）与测试环境降级为手动输入模式。
/// 扫码/输入结果会被解析为：legado 协议链接 / HTTP 订阅 URL / 书源 JSON / 口令。
/// 确认后可将内容返回给调用方（如关联导入页 / 书源管理扫码导入）。
class QrcodeScreen extends StatefulWidget {
  const QrcodeScreen({super.key});

  @override
  State<QrcodeScreen> createState() => _QrcodeScreenState();
}

class _QrcodeScreenState extends State<QrcodeScreen> {
  final _inputController = TextEditingController();
  String? _rawContent;

  /// 是否启用相机扫码（仅移动端，排除 Web/桌面/测试）
  bool get _cameraSupported =>
      !kIsWeb && (Platform.isAndroid || Platform.isIOS);

  late final MobileScannerController? _scannerController;

  /// 是否已处理扫码结果（避免连续扫码重复 pop）
  bool _handled = false;

  @override
  void initState() {
    super.initState();
    _scannerController =
        _cameraSupported ? MobileScannerController(formats: [BarcodeFormat.qrCode]) : null;
  }

  @override
  void dispose() {
    _inputController.dispose();
    _scannerController?.dispose();
    super.dispose();
  }

  /// 相机扫码回调：取首个条码原始值，填入输入框并展示识别结果
  void _onDetect(BarcodeCapture result) {
    if (_handled) return;
    final code = result.barcodes.firstOrNull?.rawValue;
    if (code == null || code.trim().isEmpty) return;
    _handled = true;
    _inputController.text = code;
    setState(() => _rawContent = code.trim());
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('扫码成功，请确认后使用')),
    );
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
        return Symbols.link_rounded;
      case _ScanResultType.httpUrl:
        return Symbols.cloud_rounded;
      case _ScanResultType.sourceJson:
        return Symbols.data_object_rounded;
      case _ScanResultType.text:
        return Symbols.text_snippet_rounded;
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
      appBar: LegadoAppBar(title: const Text('扫码导入')),
      body: ListView(
        // [LAYOUT_PLAN P3] 页面水平边距统一 16dp（全局标尺）
        padding: const EdgeInsets.all(16),
        children: [
          _buildScannerArea(theme),
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
                icon: const Icon(Symbols.content_paste_rounded),
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
            icon: const Icon(Symbols.check_rounded),
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

  /// 扫码区域：移动端为相机实时预览，桌面/测试为降级提示
  Widget _buildScannerArea(ThemeData theme) {
    if (_cameraSupported && _scannerController != null) {
      return ClipRRect(
        // [LAYOUT_PLAN P3] 分组卡圆角 16dp（全局标尺）
        borderRadius: BorderRadius.circular(16),
        child: SizedBox(
          height: 240,
          child: MobileScanner(
            controller: _scannerController,
            onDetect: _onDetect,
            errorBuilder: (context, error) =>
                _buildCameraError(theme, error.toString()),
          ),
        ),
      );
    }
    return _buildCameraPlaceholder(theme);
  }

  /// 相机预览占位（桌面端/测试环境降级提示）
  Widget _buildCameraPlaceholder(ThemeData theme) {
    return Container(
      height: 200,
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        // [LAYOUT_PLAN P3] 分组卡圆角 16dp（全局标尺）
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Stack(
            alignment: Alignment.center,
            children: [
              Icon(Symbols.qr_code_scanner_rounded, size: 72,
                  color: theme.colorScheme.outline),
              Icon(Symbols.cameraswitch_rounded, size: 24,
                  color: theme.colorScheme.outline),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            '当前平台未启用相机扫码',
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

  /// 相机错误提示（权限拒绝/无相机等）
  Widget _buildCameraError(ThemeData theme, String error) {
    return Container(
      color: theme.colorScheme.surfaceContainerHighest,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Symbols.videocam_off_rounded, size: 48, color: theme.colorScheme.outline),
          const SizedBox(height: 12),
          Text('相机启动失败', style: theme.textTheme.titleSmall),
          const SizedBox(height: 4),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Text(
              error,
              style: theme.textTheme.bodySmall,
              textAlign: TextAlign.center,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildResultCard(ThemeData theme, String content) {
    final type = _detectType(content);
    return Card(
      // [LAYOUT_PLAN P3] 分组卡圆角 16dp；卡内统一 16dp
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
      ),
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
