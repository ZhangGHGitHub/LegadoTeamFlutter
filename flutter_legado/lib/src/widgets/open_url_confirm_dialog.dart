import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

/// 外链跳转确认对话框
///
/// [审计修复 §2.1 第三批] 对齐原版 OpenUrlConfirmDialog（ui/association）：
/// 第三方内容/网页请求跳转外部链接前，先向用户确认。
///
/// 降级说明（审计建议"可降级为通用 Dialog 实现"）：
/// - 原版菜单「禁用书源 / 删除书源」依赖书源管理接口，且书源管理页正由
///   并行会话修改，本批不实现该菜单，仅保留核心确认交互。
/// - 原版 message 文案「正在请求跳转链接/应用，是否跳转？」保持一致。 — Qoder

/// 弹出外链跳转确认对话框，返回用户是否同意跳转
Future<bool> showOpenUrlConfirmDialog(
  BuildContext context, {
  required String url,
  String? sourceName,
}) async {
  final cs = Theme.of(context).colorScheme;
  final result = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('跳转确认'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (sourceName != null && sourceName.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(
                sourceName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(ctx).textTheme.labelMedium?.copyWith(
                      color: cs.onSurfaceVariant,
                    ),
              ),
            ),
          // 对齐原版 message：正在请求跳转链接/应用，是否跳转？
          const Text('正在请求跳转链接/应用，是否跳转？'),
          const SizedBox(height: 8),
          SelectableText(
            url,
            maxLines: 3,
            style: Theme.of(ctx).textTheme.bodySmall?.copyWith(
                  color: cs.onSurfaceVariant,
                ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(false),
          child: const Text('取消'),
        ),
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(true),
          child: const Text('跳转'),
        ),
      ],
    ),
  );
  return result ?? false;
}

/// 确认并在系统浏览器中打开外链
///
/// 流程对齐原版 openUrl()：确认可跳转 → 打开；无法打开时提示（can_not_open）。
Future<void> openExternalUrlWithConfirm(
  BuildContext context, {
  required String url,
  String? sourceName,
}) async {
  final uri = Uri.tryParse(url);
  if (uri == null) return;
  // 提前持有 messenger，避免跨 await 间隙再访问 BuildContext
  final messenger = ScaffoldMessenger.of(context);
  final ok = await showOpenUrlConfirmDialog(
    context,
    url: url,
    sourceName: sourceName,
  );
  if (!ok) return;
  try {
    if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
      messenger.showSnackBar(const SnackBar(content: Text('无法打开链接')));
    }
  } catch (_) {
    messenger.showSnackBar(const SnackBar(content: Text('打开链接失败')));
  }
}
