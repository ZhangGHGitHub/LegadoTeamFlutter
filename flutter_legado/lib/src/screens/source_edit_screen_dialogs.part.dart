// source_edit_screen.dart 的 part 文件（体检 §三.16 超长文件拆分）：
// 源变量对话框与二维码分享对话框（顶层私有类原样搬移）。
part of 'source_edit_screen.dart';

/// 源变量对话框（自持 controller，对齐 book_info_screen._VariableDialog）
class _SourceVariableDialog extends StatefulWidget {
  final String title;
  final String comment;
  final String initialText;

  const _SourceVariableDialog({
    required this.title,
    required this.comment,
    required this.initialText,
  });

  @override
  State<_SourceVariableDialog> createState() => _SourceVariableDialogState();
}

class _SourceVariableDialogState extends State<_SourceVariableDialog> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.initialText);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: Text(widget.title),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.comment,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _controller,
              maxLines: 6,
              autofocus: true,
              decoration: const InputDecoration(
                hintText: '输入源变量（空则清除）',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _controller.text),
          child: const Text('确定'),
        ),
      ],
    );
  }
}

/// 二维码分享对话框：预览 + 分享 PNG（对标原版 shareWithQr）
class _QrShareDialog extends StatelessWidget {
  final String title;
  final String payload;

  const _QrShareDialog({required this.title, required this.payload});

  Future<void> _shareImage(BuildContext context) async {
    try {
      final painter = QrPainter(
        data: payload,
        version: QrVersions.auto,
        errorCorrectionLevel: QrErrorCorrectLevel.L,
        gapless: true,
        // [UI_MD3_ALIGNMENT_PLAN.md Batch B B10 例外] 二维码黑白为扫码语义色
        //（扫码器要求黑 on 白对比），不随 tonal，刻意保留硬编码
        // ignore: deprecated_member_use
        color: const Color(0xFF000000),
        // ignore: deprecated_member_use
        emptyColor: const Color(0xFFFFFFFF),
      );
      final imageData = await painter.toImageData(
        512,
        format: ui.ImageByteFormat.png,
      );
      if (imageData == null) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('二维码生成失败')),
          );
        }
        return;
      }
      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/legado_source_qr.png');
      await file.writeAsBytes(imageData.buffer.asUint8List());
      await Share.shareXFiles(
        [XFile(file.path, mimeType: 'image/png')],
        subject: title,
      );
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('分享失败：$e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: Text(title),
      content: SizedBox(
        width: 240,
        height: 240,
        child: QrImageView(
          data: payload,
          version: QrVersions.auto,
          errorCorrectionLevel: QrErrorCorrectLevel.L,
          // [UI_MD3_ALIGNMENT_PLAN.md Batch B B10 例外] 同上，扫码语义白底
          backgroundColor: Colors.white,
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('关闭'),
        ),
        FilledButton(
          onPressed: () => _shareImage(context),
          child: const Text('分享图片'),
        ),
      ],
    );
  }
}
