// 私密内容整页锁定提示（批9c / 批9d）
//
// 对齐参考版 `PrivateLockedPage` / `PrivateLockedHint`：锁图标 + 标题 +
// 说明 + 验证入口。用于私密分组内容区、数据详情页与阅读器闸门；
// 页面上不渲染任何真实书名/作者/分组书列表。
//
// [批9d] 已配置且平台可用时追加「使用生物识别」次入口；失败/取消留在
// 本页，仍可走密码验证。
//
// 编写：全栈工程师（批9c / 批9d） ｜ 2026-11-10
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../providers/privacy/privacy_state.dart';

/// 锁定页说明文案（有密码 → 引导验证；无密码 → 引导设置）
String privacyLockedDescription(
  PrivacyState privacy, {
  String fallback = '验证后查看内容',
}) {
  if (!privacy.hasPassword) return '请先在隐私设置中设置密码';
  return fallback;
}

/// 锁定页动作文案
String privacyLockedActionText(
  PrivacyState privacy, {
  String fallback = '验证并查看',
}) {
  if (!privacy.hasPassword) return '去设置密码';
  return fallback;
}

/// 私密内容整页锁定
class PrivateLockedPage extends StatelessWidget {
  const PrivateLockedPage({
    super.key,
    required this.title,
    required this.description,
    required this.actionText,
    required this.onAction,
    this.icon = Symbols.lock_rounded,
    this.header,
    this.onBiometric,
  });

  final String title;
  final String description;
  final String actionText;
  final VoidCallback onAction;
  final IconData icon;

  /// 额外头部（如详情页的 3 条占位条）
  final Widget? header;

  /// [批9d] 生物快捷解锁入口（null = 隐藏；调用方按 `biometricUsable` 决定）
  final VoidCallback? onBiometric;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Center(
      key: const ValueKey('private-locked-page'),
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (header != null) ...[header!, const SizedBox(height: 32)],
            Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(
                color: cs.surfaceContainerHighest,
                shape: BoxShape.circle,
              ),
              child: Icon(icon, size: 30, color: cs.onSurfaceVariant),
            ),
            const SizedBox(height: 20),
            Text(
              title,
              textAlign: TextAlign.center,
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            Text(
              description,
              textAlign: TextAlign.center,
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              key: const ValueKey('private-locked-action'),
              onPressed: onAction,
              icon: const Icon(Symbols.lock_open_rounded, size: 18),
              label: Text(actionText),
            ),
            if (onBiometric != null) ...[
              const SizedBox(height: 8),
              TextButton.icon(
                key: const ValueKey('private-locked-biometric'),
                onPressed: onBiometric,
                icon: const Icon(Symbols.fingerprint_rounded, size: 18),
                label: const Text('使用生物识别'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// 详情页脱敏占位条（3 条，宽高对齐参考版 name/author/source 占位）
class PrivateLockedPlaceholderBars extends StatelessWidget {
  const PrivateLockedPlaceholderBars({super.key});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    Widget bar(double widthFactor) => FractionallySizedBox(
      widthFactor: widthFactor,
      child: Container(
        height: 14,
        margin: const EdgeInsets.symmetric(vertical: 5),
        decoration: BoxDecoration(
          color: cs.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(7),
        ),
      ),
    );
    return Column(
      key: const ValueKey('private-locked-placeholders'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [bar(0.62), bar(0.38), bar(0.48)],
    );
  }
}
