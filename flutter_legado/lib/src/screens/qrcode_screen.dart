import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import 'package:material_symbols_icons/symbols.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:zxing2/qrcode.dart' show QRCodeReader;
import 'package:zxing2/zxing2.dart'
    show BinaryBitmap, HybridBinarizer, Result, ResultMetadataType,
        RGBLuminanceSource;

import '../widgets/legado_app_bar.dart';

/// 扫码结果类型
enum _ScanResultType { legadoUrl, httpUrl, sourceJson, text }

/// 顶层函数：从图片字节流解码二维码（经 [compute] 移交后台 isolate）
///
/// [PARITY A1] 图库解码链路：image 自动识别 png/jpg 等格式 → 4 通道 RGBA
/// → zxing2 [RGBLuminanceSource] + [HybridBinarizer] 二值化 →
/// [QRCodeReader] 解码。返回 null 表示非图片/未能识别二维码，调用方统一
/// 提示，不抛异常（isolate 内异常不跨边界）。
///
/// 注意：img.decodeImage 的格式探测在个别畸形/截断字节流上会抛 Error
/// （如 image 4.x PSD 探测越界读 RangeError），故全函数兜底 catch，
/// 保证「不抛异常」契约。
///
/// [PARITY A1] zxing2 0.2.4 缺陷规避（CJK 二维码乱码）：其
/// DecodedBitStreamParser 把字节段读入带符号 Int8List 后直接喂给 ECI
/// 字符集 codec，UTF-8 内容的高字节（≥0x80）为负值被
/// Utf8Codec(allowMalformed) 逐字节替换为 U+FFFD。本文件在结果含 U+FFFD
/// 时经 [ResultMetadataType.byteSegments] 取回原始字节段，按无符号字节
/// 重建后以 UTF-8 重解（重解仍含 U+FFFD 则回退原文，只升不降），见
/// [_recoverUtf8Text]。
String? _decodeQrInIsolate(Uint8List bytes) {
  try {
    final image = img.decodeImage(bytes);
    if (image == null) return null;
    final rgba = image.convert(numChannels: 4);
    final pixels =
        rgba.getBytes(order: img.ChannelOrder.rgba).buffer.asInt32List();
    final source = RGBLuminanceSource(rgba.width, rgba.height, pixels);
    final bitmap = BinaryBitmap(HybridBinarizer(source));
    return _recoverUtf8Text(QRCodeReader().decode(bitmap));
  } catch (_) {
    // 探测/二值化/zxing2 NotFoundException / ChecksumException 等：
    // 识别失败一律按未识别处理
    return null;
  }
}

/// zxing2 0.2.4 的 `DecodedBitStreamParser._decodeByteSegment` 将字节段
/// 存为带符号 [Int8List]（≥0x80 的字节为负），再交给 ECI 指定字符集的
/// codec 解码；UTF-8 ECI（值 26）下负字节被 `Utf8Codec(allowMalformed:
/// true)` 视为畸形序列逐字节替换为 U+FFFD，导致中日韩二维码内容全部
/// 变替换符（纯 ASCII 内容不受影响，字节均 <0x80）。
///
/// 本函数在 [Result.text] 含 U+FFFD 时，从 [Result.resultMetadata] 取回
/// zxing2 存放的原始字节段（`byteSegments`，同为带符号 Int8List），逐段
/// 按无符号字节重建后经 UTF-8 重解。重解结果仍含 U+FFFD（内容并非
/// UTF-8，如 Latin-1/GB18030 段）则回退原 [Result.text]，保证「只升
/// 不降」：能修复 UTF-8/CJK，不恶化其他内容。
String _recoverUtf8Text(Result result) {
  final text = result.text;
  if (!text.contains('\uFFFD')) return text;
  final segments =
      result.resultMetadata[ResultMetadataType.byteSegments]
          as List<Int8List>?;
  if (segments == null || segments.isEmpty) return text;
  const utf8 = Utf8Codec(allowMalformed: true);
  final rebuilt = segments
      .map((segment) {
        final unsigned = Uint8List(segment.length);
        for (var i = 0; i < segment.length; i++) {
          unsigned[i] = segment[i] & 0xFF;
        }
        return utf8.decode(unsigned);
      })
      .join();
  return rebuilt.contains('\uFFFD') ? text : rebuilt;
}

/// 二维码扫描页面
///
/// [PARITY A1] 对齐参考版（ref_dark_20260920/09）全屏扫描形态：
/// 标题「扫描二维码」+ 右上图库按钮 + 全屏取景框；参考版在无相机环境
///（MuMu）降级为「相机启动失败」页，本实现同等优雅并保留可测路径：
///
/// - 移动端（Android/iOS）且相机可用：全屏相机预览（mobile_scanner）+
///   取景框叠加；扫描成功即返回原始内容（调用方负责解析与反馈，对齐
///   原版「扫码即导入」语义）。
/// - 相机启动失败 / 无相机平台（桌面/测试）：全屏降级页（相机启动失败 /
///   当前平台未启用相机扫码），保留「手动输入」兜底（widget 测试可跑通）。
/// - 右上图库按钮：file_picker 选本地图片 + zxing2 本地解码，无相机
///   亦可导入；降级模式下回填手动输入区由用户确认，相机模式下直接返回。
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

  /// 相机是否启动失败（MobileScanner errorBuilder 触发后切降级页）
  bool _cameraFailed = false;

  /// 相机失败详情（降级页展示，对齐参考版「相机启动失败」页）
  String? _cameraError;

  /// 图库解码进行中（禁用图库按钮防重复触发）
  bool _picking = false;

  /// 是否已处理扫码结果（避免连续扫码重复 pop）
  bool _handled = false;

  @override
  void initState() {
    super.initState();
    _scannerController = _cameraSupported
        ? MobileScannerController(formats: [BarcodeFormat.qrCode])
        : null;
  }

  @override
  void dispose() {
    _inputController.dispose();
    _scannerController?.dispose();
    super.dispose();
  }

  /// 相机扫码回调：[PARITY A1] 全屏扫描器扫到即视为确认，直接返回原始
  /// 值（调用方解析并反馈，对齐原版 menu_qr_code_camera 语义）；
  /// [_handled] 防止连续扫码重复 pop
  void _onDetect(BarcodeCapture result) {
    if (_handled) return;
    final code = result.barcodes.firstOrNull?.rawValue;
    if (code == null || code.trim().isEmpty) return;
    _handled = true;
    Navigator.of(context).pop(code.trim());
  }

  /// 图库导入：[PARITY A1] 参考版扫码页右上图库按钮——选中本地二维码
  /// 图片后本地解码（zxing2），无需相机即可导入
  Future<void> _pickFromGallery() async {
    final picked = await FilePicker.platform.pickFiles(
      dialogTitle: '选择二维码图片',
      type: FileType.image,
    );
    final path = picked?.files.singleOrNull?.path;
    if (!mounted) return;
    if (path == null) return; // 用户取消
    setState(() => _picking = true);
    try {
      final bytes = await File(path).readAsBytes();
      // 大图解码 + zxing 识别为 CPU 重负载，compute 移交后台 isolate
      // 避免主线程卡顿（AGENTS 编码陷阱：>16ms 大负载不阻塞 UI）
      final decoded = await compute(_decodeQrInIsolate, bytes);
      if (!mounted) return;
      final content = decoded?.trim();
      if (content == null || content.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('未识别到图片中的二维码')),
        );
        return;
      }
      if (_cameraSupported && !_cameraFailed) {
        // 全屏相机模式：无手动输入区，识别成功即返回（同相机直扫语义）
        _handled = true;
        Navigator.of(context).pop(content);
      } else {
        // 降级模式：回填手动输入区，用户「使用该内容」确认（可测路径）
        _inputController.text = content;
        setState(() => _rawContent = content);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('已识别图片二维码，请确认后使用')),
        );
      }
    } on FileSystemException {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('图片读取失败')),
        );
      }
    } finally {
      if (mounted) setState(() => _picking = false);
    }
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
    // [PARITY A1] 标题对齐参考版「扫描二维码」
    return Scaffold(
      appBar: LegadoAppBar(
        title: const Text('扫描二维码'),
        actions: [
          // [PARITY A1] 参考版右上图库按钮：本地选图解码二维码（免相机）
          IconButton(
            tooltip: '从图库导入',
            icon: const Icon(Symbols.photo_library_rounded),
            onPressed: _picking ? null : _pickFromGallery,
          ),
        ],
      ),
      body: _buildBody(Theme.of(context)),
    );
  }

  /// 页面主体：相机模式（全屏取景）或降级模式（手动输入兜底）
  Widget _buildBody(ThemeData theme) {
    if (_cameraSupported && !_cameraFailed) {
      return Stack(
        fit: StackFit.expand,
        children: [
          MobileScanner(
            controller: _scannerController,
            onDetect: _onDetect,
            // 相机启动失败（权限拒绝/无相机硬件等）：本页降级为
            // 「相机启动失败」全屏页（对齐参考版 MuMu 形态）；首帧直接
            // 渲染降级内容避免闪屏，post-frame 置位使后续构建稳定走
            // 降级分支（errorBuilder 在构建期回调，不能直接 setState）
            errorBuilder: (context, error) {
              if (!_cameraFailed) {
                final detail = error.toString();
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (mounted && !_cameraFailed) {
                    setState(() {
                      _cameraFailed = true;
                      _cameraError = detail;
                    });
                  }
                });
              }
              return _buildDegradedBody(theme, cameraError: error.toString());
            },
          ),
          _buildViewfinder(theme),
        ],
      );
    }
    // 已置位 _cameraFailed 的后续构建（SnackBar/状态变更触发重建）仍展示
    // 失败详情，避免头部提示卡丢失错误文案
    return _buildDegradedBody(
      theme,
      cameraError: _cameraFailed ? _cameraError : null,
    );
  }

  /// 取景框叠加：居中方形边框（对齐参考版全屏扫描器取景框，比例 0.8）
  Widget _buildViewfinder(ThemeData theme) {
    return IgnorePointer(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final size = constraints.maxWidth * 0.8;
          return Center(
            child: SizedBox(
              width: size,
              height: size,
              child: Container(
                decoration: BoxDecoration(
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.9),
                    width: 2,
                  ),
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  /// 降级页：相机启动失败 / 无相机平台（桌面、测试环境）
  ///
  /// [PARITY A1] 参考版在无相机环境展示「相机启动失败」页；本实现保留
  /// 「手动输入」兜底（widget 测试可跑通），右上图库按钮在顶栏常显，
  /// 无相机时导入链路仍可用
  Widget _buildDegradedBody(ThemeData theme, {String? cameraError}) {
    final failed = _cameraFailed || cameraError != null;
    return ListView(
      // [LAYOUT_PLAN P3] 页面水平边距统一 16dp（全局标尺）
      padding: const EdgeInsets.all(16),
      children: [
        _buildDegradedHeader(theme, failed: failed, cameraError: cameraError),
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
          onPressed: (_rawContent?.isNotEmpty ?? false) ? _confirm : null,
          icon: const Icon(Symbols.check_rounded),
          label: const Text('使用该内容'),
        ),
        if (_rawContent != null && _rawContent!.isNotEmpty) ...[
          const SizedBox(height: 20),
          _buildResultCard(theme, _rawContent!),
        ],
      ],
    );
  }

  /// 降级页头部提示卡（相机启动失败 / 平台未启用相机）
  Widget _buildDegradedHeader(
    ThemeData theme, {
    required bool failed,
    String? cameraError,
  }) {
    return Container(
      height: 200,
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        // [LAYOUT_PLAN P3] 分组卡圆角 16dp（全局标尺）
        borderRadius: BorderRadius.circular(16),
      ),
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              failed
                  ? Symbols.videocam_off_rounded
                  : Symbols.qr_code_scanner_rounded,
              size: 64,
              color: theme.colorScheme.outline,
            ),
            const SizedBox(height: 12),
            Text(
              failed
                  ? '相机启动失败'
                  : '当前平台未启用相机扫码',
              style: theme.textTheme.titleSmall,
            ),
            const SizedBox(height: 4),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Text(
                '可使用右上角图库按钮导入二维码图片，或下方手动输入',
                style: theme.textTheme.bodySmall,
                textAlign: TextAlign.center,
              ),
            ),
            if (failed && cameraError != null) ...[
              const SizedBox(height: 4),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Text(
                  cameraError,
                  style: theme.textTheme.bodySmall,
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ],
        ),
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
                Icon(_typeIcon(type),
                    size: 20, color: theme.colorScheme.primary),
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
