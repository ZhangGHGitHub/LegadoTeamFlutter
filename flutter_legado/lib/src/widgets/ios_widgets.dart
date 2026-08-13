import 'package:flutter/material.dart';

/// iOS 风格分组列表组件库
///
/// 提供 iOS Settings 风格的「分组背景 + 白色圆角卡片 + hairline 分隔」构件，
/// 供各页面在保持功能一致的前提下统一视觉。
///
/// 典型用法：
/// ```dart
/// IosGroupedBody(
///   slivers: [
///     SliverToBoxAdapter(child: IosSectionHeader('分组')),
///     SliverToBoxAdapter(
///       child: IosGroup(children: [ ListTile(...), SwitchListTile(...) ]),
///     ),
///   ],
/// )
/// ```

/// 分组列表外层容器：使用 Scaffold 的分组背景色并留出左右安全边距。
class IosGroupedBody extends StatelessWidget {
  /// 子 Widget（通常为 Column / ListView，内容自带滚动则用 [child]）
  final Widget child;

  /// 左右留白（iOS 分组卡片外边距）
  final EdgeInsets padding;

  const IosGroupedBody({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.symmetric(horizontal: 16),
  });

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: Theme.of(context).scaffoldBackgroundColor,
      child: SafeArea(
        top: false,
        child: Padding(padding: padding, child: child),
      ),
    );
  }
}

/// 分组标题：iOS 风格的灰色小标题（位于卡片上方）。
class IosSectionHeader extends StatelessWidget {
  final String text;
  final EdgeInsets padding;

  const IosSectionHeader(
    this.text, {
    super.key,
    this.padding = const EdgeInsets.fromLTRB(16, 24, 16, 8),
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: padding,
      child: Text(
        text.toUpperCase(),
        style: theme.textTheme.labelMedium?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
          letterSpacing: 0.6,
        ),
      ),
    );
  }
}

/// 分组脚注：卡片下方的灰色说明文字。
class IosSectionFooter extends StatelessWidget {
  final String text;
  final EdgeInsets padding;

  const IosSectionFooter(
    this.text, {
    super.key,
    this.padding = const EdgeInsets.fromLTRB(16, 8, 16, 8),
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: padding,
      child: Text(
        text,
        style: theme.textTheme.labelMedium?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

/// 白色圆角分组卡片：在 children 之间绘制 hairline 分隔线。
///
/// [separatorIndent] 为分隔线左侧缩进（对齐 iOS：有 leading 图标时约 56）。
class IosGroup extends StatelessWidget {
  final List<Widget> children;
  final double separatorIndent;
  final EdgeInsets margin;

  const IosGroup({
    super.key,
    required this.children,
    this.separatorIndent = 16,
    this.margin = const EdgeInsets.symmetric(horizontal: 0),
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final separator = Divider(
      height: 0.5,
      thickness: 0.5,
      indent: separatorIndent,
      color: theme.dividerColor,
    );

    final rows = <Widget>[];
    for (var i = 0; i < children.length; i++) {
      rows.add(children[i]);
      if (i != children.length - 1) rows.add(separator);
    }

    return Padding(
      padding: margin,
      child: Card(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: rows,
        ),
      ),
    );
  }
}

/// iOS 风格列表项：图标 + 标题 +（可选副标题）+ 尾部（值 / 开关 / 箭头）。
///
/// 对 [ListTile] 的薄封装，统一 leading 图标容器为 iOS 圆角色块。
class IosListTile extends StatelessWidget {
  /// 可选；嵌套设置页常见无图标行（对齐系统 Preferences）
  final IconData? icon;
  final Color? iconColor;
  final Color? iconBackground;
  final String title;
  final String? subtitle;
  final Widget? trailing;
  final String? value;
  final bool showDisclosure;
  final VoidCallback? onTap;

  const IosListTile({
    super.key,
    this.icon,
    required this.title,
    this.iconColor,
    this.iconBackground,
    this.subtitle,
    this.trailing,
    this.value,
    this.showDisclosure = false,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final bg = iconBackground ?? scheme.primary;

    Widget? trailing = this.trailing;
    if (trailing == null && (value != null || showDisclosure)) {
      trailing = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (value != null)
            Text(
              value!,
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
          if (showDisclosure)
            Padding(
              padding: const EdgeInsets.only(left: 6),
              child: Icon(
                Icons.chevron_right,
                size: 20,
                color: scheme.outlineVariant,
              ),
            ),
        ],
      );
    }

    return ListTile(
      leading: icon == null
          ? null
          : Container(
              width: 30,
              height: 30,
              decoration: BoxDecoration(
                color: bg,
                borderRadius: BorderRadius.circular(7),
              ),
              alignment: Alignment.center,
              // [审计修复 §3.3] 兜底前景改用 onPrimary Token（与默认 primary 背景配对） — Qoder
              child: Icon(icon, size: 19, color: iconColor ?? scheme.onPrimary),
            ),
      title: Text(title),
      subtitle: subtitle != null ? Text(subtitle!) : null,
      trailing: trailing,
      onTap: onTap,
    );
  }
}

/// iOS 抓取指示条（Bottom Sheet 顶部短横条）。
class IosGrabber extends StatelessWidget {
  const IosGrabber({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 8),
      width: 36,
      height: 5,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.outlineVariant,
        borderRadius: BorderRadius.circular(2.5),
      ),
    );
  }
}
