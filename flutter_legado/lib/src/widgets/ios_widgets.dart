import 'package:flutter/material.dart';

/// MD3 风格分组列表组件库（Batch 0 集中改造，UI_MD3_PLAN.md 第八节）
///
/// 提供分组设置页的「tonal 表面背景 + 大圆角分组容器 + outlineVariant
/// 分隔」构件。类名沿用 Ios* 前缀（消费屏零改动继承改造），视觉已切换
/// 为 MD3 token：分组容器走 cardTheme（tonal surfaceContainer 层次），
/// 图标容器 primaryContainer，拖拽把手对齐 M3 drag handle 规格。
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
///
/// 分组列表外层容器：使用 Scaffold 的表面背景色并留出左右安全边距。
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

/// 分组标题：MD3 风格的小标题（labelMedium / onSurfaceVariant，位于容器上方）。
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
    // 含中文/混排标题保持原样（避免「WebDav 设置」→「WEBDAV 设置」）；
    // 纯拉丁短标题仍用大写。
    final hasCjk = RegExp(r'[\u4e00-\u9fff]').hasMatch(text);
    final label = hasCjk ? text : text.toUpperCase();
    return Padding(
      padding: padding,
      child: Text(
        label,
        style: theme.textTheme.labelMedium?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
          letterSpacing: hasCjk ? 0.2 : 0.6,
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

/// tonal 圆角分组容器：在 children 之间绘制 outlineVariant 分隔线。
///
/// 容器视觉由 cardTheme 驱动（tonal surfaceContainer 层次 + Expressive
/// 大圆角）；[separatorIndent] 为分隔线左侧缩进（有 leading 图标时约 56）。
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

/// MD3 列表项：图标 + 标题 +（可选副标题）+ 尾部（值 / 开关）。
///
/// 对 [ListTile] 的薄封装，统一 leading 图标容器为 MD3 tonal 圆角方块
/// （primaryContainer 底 + onPrimaryContainer 图标，可经参数覆写）。
/// [MD3 全量清点 P2] 移除 iOS 式行尾展开箭头（原版 Android 列表无行尾
/// 「>」，与参考仓库一致）；行是否可点由 onTap 存在性决定。
class IosListTile extends StatelessWidget {
  /// 可选；嵌套设置页常见无图标行
  final IconData? icon;
  final Color? iconColor;
  final Color? iconBackground;
  final String title;
  final String? subtitle;
  final Widget? trailing;

  /// 尾部值文本（如「默认」），与自定义 [trailing] 互斥（trailing 优先）
  final String? value;
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
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    // MD3 tonal 图标容器：默认 primaryContainer 底 + onPrimaryContainer 图标，
    // 屏幕显式传入 iconBackground/iconColor 时以传入值为准
    final bg = iconBackground ?? scheme.primaryContainer;
    final fg = iconColor ?? scheme.onPrimaryContainer;

    Widget? trailing = this.trailing;
    if (trailing == null && value != null) {
      trailing = Text(
        value!,
        style: theme.textTheme.bodyMedium
            ?.copyWith(color: scheme.onSurfaceVariant),
      );
    }

    return ListTile(
      leading: icon == null
          ? null
          : Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                color: bg,
                borderRadius: BorderRadius.circular(8),
              ),
              alignment: Alignment.center,
              child: Icon(icon, size: 19, color: fg),
            ),
      title: Text(title),
      subtitle: subtitle != null ? Text(subtitle!) : null,
      trailing: trailing,
      onTap: onTap,
    );
  }
}

/// MD3 拖拽把手（Bottom Sheet 顶部短横条，对齐 M3 drag handle 规格）。
class IosGrabber extends StatelessWidget {
  const IosGrabber({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 8),
      width: 32,
      height: 4,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.onSurfaceVariant,
        borderRadius: BorderRadius.circular(2),
      ),
    );
  }
}
