import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;

import '../providers/providers.dart';
import '../providers/source/source_notifier.dart';

/// 全局验证码请求监听器（对标 Kotlin SourceVerificationHelp 全局监听）
///
/// 挂载于 MaterialApp.builder：订阅 BookApi.verificationRequestStream，
/// 书源 JS 经 getVerificationCode 钩子挂起等待时弹出验证码对话框；
/// 多个请求按到达顺序队列化，逐个弹出（原版同一时刻仅一个对话框）。
///
/// 职责边界（对齐 UI_RESTRUCTURE_PLAN.md §0.2 铁律）：
/// 本组件仅消费 BookApi 事件流与 SourceNotifier，不触 bridge。
class VerificationCodeListener extends ConsumerStatefulWidget {
  final Widget child;

  const VerificationCodeListener({super.key, required this.child});

  @override
  ConsumerState<VerificationCodeListener> createState() =>
      _VerificationCodeListenerState();
}

class _VerificationCodeListenerState
    extends ConsumerState<VerificationCodeListener> {
  StreamSubscription<Map<String, dynamic>>? _subscription;

  /// 待处理请求队列（订阅时会回放进行中请求，需按 key 去重）
  final List<Map<String, dynamic>> _queue = [];

  /// 正在展示对话框的 key（null 表示空闲）
  String? _showingKey;

  @override
  void initState() {
    super.initState();
    _subscription = ref
        .read(bookApiProvider)
        .verificationRequestStream()
        .listen(_onRequest, onError: (Object _) {/* 通道异常静默，等待重连 */});
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }

  void _onRequest(Map<String, dynamic> event) {
    if (!mounted) return;
    final key = (event['key'] ?? '').toString();
    if (key.isEmpty) return;
    // 去重：正在展示或队列中已有同 key 请求（回放场景）
    if (key == _showingKey) return;
    if (_queue.any((e) => (e['key'] ?? '').toString() == key)) return;
    _queue.add(event);
    _showNext();
  }

  Future<void> _showNext() async {
    if (_showingKey != null || _queue.isEmpty || !mounted) return;
    final event = _queue.removeAt(0);
    final key = (event['key'] ?? '').toString();
    _showingKey = key;

    // builder 上下文持有全局 Navigator，跨页面弹窗安全
    final submitted = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _VerificationCodeDialog(
        requestKey: key,
        sourceName: (event['source_name'] ?? '').toString(),
        title: (event['title'] ?? '').toString(),
        imageUrl: (event['image_url'] ?? '').toString(),
        sourceUrl: (event['source_url'] ?? '').toString(),
      ),
    );

    final api = ref.read(bookApiProvider);
    if (submitted != true) {
      // 关闭未提交：以空结果唤醒等待方（对齐 Kotlin checkResult 语义）
      await api.cancelVerificationRequest(key);
    }

    _showingKey = null;
    if (mounted) _showNext();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// 验证码对话框内容（对标原版 VerificationCodeDialog：
/// 图片 + 输入框 + 确定/取消，溢出菜单含禁用书源/删除书源）
///
/// controller 由对话框内容 StatefulWidget 自持（随子树卸载释放，
/// 避免退场动画期间 dispose 引发框架断言）。
class _VerificationCodeDialog extends ConsumerStatefulWidget {
  final String requestKey;
  final String sourceName;
  final String title;
  final String imageUrl;
  final String sourceUrl;

  const _VerificationCodeDialog({
    required this.requestKey,
    required this.sourceName,
    required this.title,
    required this.imageUrl,
    required this.sourceUrl,
  });

  @override
  ConsumerState<_VerificationCodeDialog> createState() =>
      _VerificationCodeDialogState();
}

class _VerificationCodeDialogState
    extends ConsumerState<_VerificationCodeDialog> {
  final TextEditingController _controller = TextEditingController();
  bool _submitting = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final code = _controller.text.trim();
    if (code.isEmpty || _submitting) return;
    setState(() => _submitting = true);
    await ref
        .read(bookApiProvider)
        .submitVerificationResult(widget.requestKey, code);
    if (mounted) Navigator.pop(context, true);
  }

  /// 溢出菜单：禁用书源/删除书源（对标原版 VerificationCodeDialog 菜单）
  Future<void> _showSourceMenu(BuildContext buttonContext) async {
    // 从按钮自身坐标弹出（对齐顶栏右侧锚点）
    final box = buttonContext.findRenderObject() as RenderBox?;
    final overlay =
        MediaQuery.of(buttonContext).size;
    final position = box != null
        ? RelativeRect.fromRect(
            box.localToGlobal(Offset.zero) & box.size,
            Offset.zero & overlay,
          )
        : const RelativeRect.fromLTRB(100, 100, 0, 0);
    final action = await showMenu<String>(
      context: buttonContext,
      position: position,
      items: [
        const PopupMenuItem(value: 'disable', child: Text('禁用书源')),
        const PopupMenuItem(value: 'delete', child: Text('删除书源')),
      ],
    );
    if (action == null || !mounted) return;
    final notifier = ref.read(sourceNotifierProvider.notifier);
    switch (action) {
      case 'disable':
        await notifier.toggleSource(widget.sourceUrl);
      case 'delete':
        await notifier.deleteSource(widget.sourceUrl);
    }
    // 处置书源后关闭对话框（对齐原版处置后 finish 语义）
    if (mounted) Navigator.pop(context, false);
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final header = widget.title.isNotEmpty
        ? widget.title
        : (widget.sourceName.isNotEmpty
            ? '「${widget.sourceName}」需要验证码'
            : '请输入验证码');
    return AlertDialog(
      title: Row(
        children: [
          Expanded(
            child: Text(header,
                maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
          Builder(
            builder: (btnContext) => IconButton(
              icon: const Icon(Icons.more_vert, size: 20),
              tooltip: '更多选项',
              visualDensity: VisualDensity.compact,
              onPressed: () => _showSourceMenu(btnContext),
            ),
          ),
        ],
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (widget.imageUrl.isNotEmpty)
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Image.network(
                widget.imageUrl,
                height: 80,
                fit: BoxFit.contain,
                errorBuilder: (_, _, _) => Container(
                  height: 80,
                  color: colorScheme.surfaceContainerHighest,
                  alignment: Alignment.center,
                  child: Text(
                    '验证码图片加载失败',
                    style: TextStyle(
                      fontSize: 12,
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
            ),
          const SizedBox(height: 16),
          TextField(
            controller: _controller,
            autofocus: true,
            decoration: const InputDecoration(
              hintText: '输入验证码',
              border: OutlineInputBorder(),
            ),
            onSubmitted: (_) => _submit(),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _submitting ? null : _submit,
          child: _submitting
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('确定'),
        ),
      ],
    );
  }
}
