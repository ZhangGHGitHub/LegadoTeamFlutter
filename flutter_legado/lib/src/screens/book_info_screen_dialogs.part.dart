// book_info_screen.dart 的 part 文件（体检 §三.16 超长文件拆分）：
// 可折叠文字组件与变量对话框（顶层私有类原样搬移）。
part of 'book_info_screen.dart';

/// 可折叠文字组件
class _ExpandableText extends StatefulWidget {
  final String text;

  const _ExpandableText({required this.text});

  @override
  State<_ExpandableText> createState() => _ExpandableTextState();
}

class _ExpandableTextState extends State<_ExpandableText> {
  // [UI-fix v2.0.11 | 2026-08-10] 简介默认全部显示（用户反馈），
  // 保留「收起」按钮供手动折叠；短简介仍由 showToggle 自适应隐藏切换控件 — Reasonix
  bool _expanded = true;

  /// 折叠态显示行数（对齐原版折叠约 3 行）
  static const int _collapsedLines = 3;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final style = Theme.of(context).textTheme.bodyMedium;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      // [UI-fix v2.0.7 | 2026-08-08] 用 TextPainter 预测折叠态是否真的截断正文：
      // 仅在超过 _collapsedLines 行时才显示「展开/收起」控件，短简介整段直接显示
      // （按内容自适应，替代此前 length>100 的粗略字数阈值——后者会漏判「刚好
      // 超 3 行但不足百字」的简介，导致尾部被省略号截断却无展开入口） — Qoder
      child: LayoutBuilder(
        builder: (context, constraints) {
          final painter = TextPainter(
            text: TextSpan(text: widget.text, style: style),
            maxLines: _collapsedLines,
            textDirection: Directionality.of(context),
            textScaler: MediaQuery.textScalerOf(context),
          )..layout(maxWidth: constraints.maxWidth);
          final showToggle = painter.didExceedMaxLines;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // [UI-fix v2.0.7 | 2026-08-08] 移除「简介」标题 heading：对齐原版
              // 无标签、直接显示简介正文 — Qoder
              AnimatedCrossFade(
                firstChild: Text(
                  widget.text,
                  maxLines: _collapsedLines,
                  overflow: TextOverflow.ellipsis,
                  style: style,
                ),
                secondChild: Text(widget.text, style: style),
                crossFadeState: _expanded
                    ? CrossFadeState.showSecond
                    : CrossFadeState.showFirst,
                duration: const Duration(milliseconds: 200),
              ),
              // [UI-fix v2.0.7 | 2026-08-08] 展开/收起：右对齐 + 主题色文字，
              // 对齐原版底部右下角切换控件（省略号硬截断改为可展开/收起） — Qoder
              if (showToggle)
                Align(
                  alignment: Alignment.centerRight,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => setState(() => _expanded = !_expanded),
                    child: Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        _expanded ? '收起' : '展开',
                        style: TextStyle(color: cs.primary, fontSize: 13),
                      ),
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

/// 变量设置对话框（供设置源变量/设置书籍变量复用）
///
/// [Task #70 D1 修复 | 2026-08-10] 照 source_screen.dart 的
/// _TextPromptDialog 范式实现自持 StatefulWidget：controller 在 State
/// 内 late final 创建、dispose 随子树卸载统一释放，确定按钮先取值再
/// Navigator.pop(ctx, value)，规避外部作用域 controller 在退场动画期间
/// 提前 dispose 引发的 framework.dart '_dependents.isEmpty' 断言 +
/// OverlayEntry Duplicate GlobalKey 红屏 — Qoder
///
/// 回传约定：确定 → pop 输入值（可为空串，空串=清除语义由调用方保持）；
/// 取消/系统关闭 → pop 无值（null），调用方不保存。
class _VariableDialog extends StatefulWidget {
  final String title;

  /// 说明文案（对齐原版 VariableDialog 的 comment 展示）
  final String comment;

  /// 输入框预填文本
  final String initialText;

  const _VariableDialog({
    required this.title,
    required this.comment,
    required this.initialText,
  });

  @override
  State<_VariableDialog> createState() => _VariableDialogState();
}

class _VariableDialogState extends State<_VariableDialog> {
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
              minLines: 3,
              maxLines: null,
              decoration: const InputDecoration(
                labelText: 'variable',
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
          onPressed: () {
            // 先取值再 pop（controller 随子树卸载后不可再读）
            final value = _controller.text;
            Navigator.pop(context, value);
          },
          child: const Text('确定'),
        ),
      ],
    );
  }
}
