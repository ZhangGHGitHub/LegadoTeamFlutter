// 隐私密码验证弹窗（批9c / 批9d）
//
// 统一入口 `showPrivacyUnlockDialog`：书架锁定卡片、私密分组锁定页、
// 数据详情页、阅读器闸门复用同一套「验证一次 → 按频率授权」流程。
// - 已授权 / 总开关关闭 → 直接返回 true，不打扰；
// - 未设置密码 → 引导去隐私设置，返回 false（安全兜底，不落锁死）；
// - EveryTime → 只授权本次目标；AppSession/UntilBackground → 会话放行；
// - [批9d] 已配置且平台可用时提供「使用生物识别」；取消/失败留在弹窗，
//   仍可回退密码验证。
//
// 编写：全栈工程师（批9c / 批9d） ｜ 2026-11-10
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../providers/privacy/privacy_notifier.dart';
import '../../providers/privacy/privacy_state.dart';
import '../../routes.dart';

/// 请求解锁某个私密目标；true = 已获准（或无需验证）
///
/// [bookUrl] / [groupId] 对应参考版 `PrivateUnlockTarget.Book/Group`；
/// 两者都为空时只做一次普通验证（不登记目标，EveryTime 下等同无效授权）。
Future<bool> showPrivacyUnlockDialog(
  BuildContext context,
  WidgetRef ref, {
  String? bookUrl,
  int? groupId,
  String? title,
}) async {
  final privacy = ref.read(privacyNotifierProvider);
  if (!privacy.enabled) return true;
  if (privacy.isTargetGranted(bookUrl: bookUrl, groupId: groupId)) {
    return true;
  }
  if (!context.mounted) return false;

  if (!privacy.hasPassword) {
    final goSettings = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        key: const ValueKey('privacyNoPasswordDialog'),
        title: const Text('未设置隐私密码'),
        content: const Text('私密内容需要隐私密码。请先在隐私设置中设置密码后再验证。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('去设置'),
          ),
        ],
      ),
    );
    if (goSettings == true && context.mounted) {
      await Navigator.pushNamed(context, AppRoutes.privacy);
    }
    return false;
  }

  final result = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => _PrivacyUnlockDialog(
      title: title ?? '验证隐私密码',
      bookUrl: bookUrl,
      groupId: groupId,
    ),
  );
  return result == true;
}

class _PrivacyUnlockDialog extends ConsumerStatefulWidget {
  const _PrivacyUnlockDialog({required this.title, this.bookUrl, this.groupId});

  final String title;
  final String? bookUrl;
  final int? groupId;

  @override
  ConsumerState<_PrivacyUnlockDialog> createState() =>
      _PrivacyUnlockDialogState();
}

class _PrivacyUnlockDialogState extends ConsumerState<_PrivacyUnlockDialog> {
  final TextEditingController _controller = TextEditingController();
  bool _busy = false;
  bool _biometricBusy = false;
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy) return;
    final password = _controller.text;
    if (password.isEmpty) {
      setState(() => _error = '请输入密码');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final ok = await ref
        .read(privacyNotifierProvider.notifier)
        .verifyForTarget(
          password,
          bookUrl: widget.bookUrl,
          groupId: widget.groupId,
        );
    if (!mounted) return;
    if (ok) {
      Navigator.pop(context, true);
      return;
    }
    setState(() {
      _busy = false;
      _error = '密码错误，请重试';
    });
  }

  /// [批9d] 生物快捷解锁：取消/失败留在弹窗，密码输入仍可用
  Future<void> _submitBiometric() async {
    if (_busy || _biometricBusy) return;
    setState(() {
      _biometricBusy = true;
      _error = null;
    });
    final outcome = await ref
        .read(privacyNotifierProvider.notifier)
        .unlockWithBiometric(bookUrl: widget.bookUrl, groupId: widget.groupId);
    if (!mounted) return;
    if (outcome.isSuccess) {
      Navigator.pop(context, true);
      return;
    }
    setState(() {
      _biometricBusy = false;
      _error = outcome.userMessage;
    });
  }

  @override
  Widget build(BuildContext context) {
    final privacy = ref.watch(privacyNotifierProvider);
    return AlertDialog(
      key: const ValueKey('privacyUnlockDialog'),
      title: Text(widget.title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            _scopeHint(privacy.unlockScope),
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            key: const ValueKey('privacyUnlockField'),
            controller: _controller,
            autofocus: true,
            obscureText: true,
            enabled: !_busy,
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => _submit(),
            decoration: InputDecoration(
              labelText: '隐私密码',
              errorText: _error,
              border: const OutlineInputBorder(),
            ),
          ),
          if (privacy.biometricUsable) ...[
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                key: const ValueKey('privacyUnlockBiometric'),
                onPressed: (_busy || _biometricBusy) ? null : _submitBiometric,
                icon: _biometricBusy
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Symbols.fingerprint_rounded, size: 18),
                label: const Text('使用生物识别'),
              ),
            ),
          ],
        ],
      ),
      actions: [
        TextButton(
          key: const ValueKey('privacyUnlockCancel'),
          onPressed: (_busy || _biometricBusy)
              ? null
              : () => Navigator.pop(context, false),
          child: const Text('取消'),
        ),
        FilledButton(
          key: const ValueKey('privacyUnlockConfirm'),
          onPressed: (_busy || _biometricBusy) ? null : _submit,
          child: _busy
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('验证'),
        ),
      ],
    );
  }

  String _scopeHint(PrivacyUnlockScope scope) => switch (scope) {
    PrivacyUnlockScope.everyTime => '验证后仅放行当前内容，离开即重新锁定',
    PrivacyUnlockScope.appSession => '验证后本次应用内不再重复验证',
    PrivacyUnlockScope.untilBackground => '验证后离开后台超过宽限时间需重新验证',
  };
}
