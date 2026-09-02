// source_screen.dart 的 part 文件（体检 §三.16 超长文件拆分）：
// 列表行/菜单行/文本对话框等顶层私有组件类（原样搬移）。
part of 'source_screen.dart';

/// 书源列表行：域名头或书源项（域名分组模式）
class _SourceListRow {
  final String? header;
  final BookSource? source;

  const _SourceListRow.header(this.header) : source = null;
  const _SourceListRow.item(this.source) : header = null;

  bool get isHeader => header != null;
}

/// 溢出菜单图标行（对标原版菜单项的 icon + title 结构）
class _MenuRow extends StatelessWidget {
  final IconData icon;
  final String label;

  const _MenuRow({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 20, color: Theme.of(context).colorScheme.onSurfaceVariant),
        const SizedBox(width: 12),
        Expanded(child: Text(label)),
      ],
    );
  }
}

/// 文本输入对话框内容组件：controller 生命周期绑定对话框子树，
/// 随子树卸载统一释放（避免退场动画期间 dispose 引发框架断言）
class _TextPromptDialog extends StatefulWidget {
  final String title;
  final String hintText;
  final String confirmLabel;
  final bool autofocus;

  /// 预填文本（如校验关键词持久化回显）
  final String? initialText;

  /// 为 true 时确认按钮在输入为空时不关闭对话框
  final bool requireNonEmpty;

  const _TextPromptDialog({
    required this.title,
    required this.hintText,
    required this.confirmLabel,
    this.autofocus = false,
    this.initialText,
    this.requireNonEmpty = false,
  });

  @override
  State<_TextPromptDialog> createState() => _TextPromptDialogState();
}

class _TextPromptDialogState extends State<_TextPromptDialog> {
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
      title: Text(widget.title),
      content: TextField(
        controller: _controller,
        autofocus: widget.autofocus,
        decoration: InputDecoration(hintText: widget.hintText),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () {
            final text = _controller.text.trim();
            if (widget.requireNonEmpty && text.isEmpty) return;
            Navigator.pop(context, text);
          },
          child: Text(widget.confirmLabel),
        ),
      ],
    );
  }
}
