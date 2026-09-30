import 'package:flutter/material.dart';

import '../providers/ui_settings/ui_settings_notifier.dart';

import 'setting_cards.dart';

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
/// 容器视觉由 cardTheme 驱动（tonal surfaceContainer 层次）；
/// [separatorIndent] 为分隔线左侧缩进（有 leading 图标时约 56）。
/// [LAYOUT_MOTION_AUDIT L2] 分组圆角 16dp（HapeLee SplicedColumnGroup，
/// 已确认；cardTheme 全局 20 保留，此处显式覆盖）；
/// [flat] 为 true 时走扁平模式（Column + 条件 80% pill 分隔，
/// HapeLee 设置页式，9 屏迁移用），默认 false 保持卡片兼容。
class IosGroup extends StatelessWidget {
  final List<Widget> children;
  final double separatorIndent;
  final EdgeInsets margin;
  final bool flat;

  const IosGroup({
    super.key,
    required this.children,
    this.separatorIndent = 16,
    this.margin = const EdgeInsets.symmetric(horizontal: 0),
    this.flat = false,
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

    if (flat) {
      // 扁平模式需自备透明 Material，否则 ListTile 的 ink 溅在远端
      // Material 祖先上会被中间 ColoredBox（IosGroupedBody）遮住而断言失败
      return Padding(
        padding: margin,
        child: Material(
          type: MaterialType.transparency,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: rows,
          ),
        ),
      );
    }
    // [UI_SYNC_REFACTOR T2] 对齐参考 SplicedColumnGroup：16dp 玻璃分组卡
    //（surfaceContainer 底）+ 组内 spacedBy 2 + 每行 4dp surfaceContainerLow
    // 小卡底（SettingCard 等效）
    return Padding(
      padding: margin,
      child: Container(
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainer,
          borderRadius: BorderRadius.circular(16),
        ),
        clipBehavior: Clip.antiAlias,
        padding: const EdgeInsets.all(4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var i = 0; i < children.length; i++) ...[
              Material(
                color: theme.colorScheme.surfaceContainerLow,
                borderRadius: BorderRadius.circular(4),
                clipBehavior: Clip.antiAlias,
                child: children[i],
              ),
              if (i != children.length - 1) const SizedBox(height: 2),
            ],
          ],
        ),
      ),
    );
  }
}

/// M3 设置行：图标 + 标题 +（可选副标题）+ 尾部（值 / 开关 / 箭头）。
///
/// [LAYOUT_MOTION_AUDIT L2] 对齐 HapeLee SettingItem：
/// 图标为裸 Icon（onSurfaceVariant，HapeLee 无 32dp 方块容器；
/// 传 [iconBackground] 时仍走旧 tonal 方块兼容）；
/// 值文本走 primary-labelMediumEmphasized；
/// [showChevron] 为 true 且可点击时尾部补 Chevron（M3 有箭头；
/// 原 P2 移除注释仅对 Miuix 成立，此处反转）。
/// [MD3 全量清点 P2] 行是否可点由 onTap 存在性决定。
class IosListTile extends StatelessWidget {
  /// 可选；嵌套设置页常见无图标行
  final IconData? icon;

  /// 自定义前导件（优先于 [icon]）。用于忙态 spinner 等非静态图标；
  /// 行语义包装件 [SettingSwitchRow] 亦经此透传。
  final Widget? leading;
  final Color? iconColor;
  final Color? iconBackground;
  final String title;
  final String? subtitle;
  final Widget? trailing;

  /// 尾部值文本（如「默认」），与自定义 [trailing] 互斥（trailing 优先）
  final String? value;

  /// 可点击时是否显示行尾 Chevron（默认 true；开关行传 false）
  final bool showChevron;
  final VoidCallback? onTap;

  /// 行是否可用（同 ListTile.enabled：false 时文字/图标灰显且不可点）
  final bool enabled;

  /// 行高密度（透传 ListTile.dense；null 走 ListTileTheme）
  final bool? dense;

  /// 覆盖主题默认行内边距（透传 ListTile.contentPadding；
  /// 密排开关行如 WebDav 组内 vertical12/horizontal8 用）
  final EdgeInsetsGeometry? contentPadding;

  const IosListTile({
    super.key,
    this.icon,
    this.leading,
    required this.title,
    this.iconColor,
    this.iconBackground,
    this.subtitle,
    this.trailing,
    this.value,
    this.showChevron = true,
    this.onTap,
    this.enabled = true,
    this.dense,
    this.contentPadding,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    Widget? trailing = this.trailing;
    if (trailing == null && value != null) {
      trailing = Text(
        value!,
        style: theme.textTheme.labelMediumEmphasized?.copyWith(
          color: scheme.primary,
        ),
      );
    }
    // 可点击且无自定义尾部/值文本时补 M3 Chevron
    trailing ??= (onTap != null && showChevron)
        ? Icon(
            Icons.chevron_right_rounded,
            size: 20,
            color: scheme.onSurfaceVariant,
          )
        : null;

    Widget? leading = this.leading;
    if (leading == null && icon != null) {
      if (iconBackground != null || iconColor != null) {
        // 显式传色时保留旧 tonal 方块（兼容沉浸域调用）
        leading = Container(
          width: 32,
          height: 32,
          decoration: BoxDecoration(
            color: iconBackground ?? scheme.primaryContainer,
            borderRadius: BorderRadius.circular(8),
          ),
          alignment: Alignment.center,
          child: Icon(
              icon!, size: 19, color: iconColor ?? scheme.onPrimaryContainer),
        );
      } else {
        // 默认裸图标（HapeLee SettingItem 无容器）
        leading = Icon(icon, size: 24, color: scheme.onSurfaceVariant);
      }
    }

    // [UI_SYNC_REFACTOR R3] 设置行分隔线（参考仓 enableItemDivider：
    // 行底 1dp 胶囊线，长度 80dp 缩进 16，默认关）
    final divider = uiSettingsListenable.value.enableItemDivider
        ? Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: leading,
                title: Text(title, style: theme.textTheme.titleMedium),
                subtitle: subtitle != null
                    ? Text(
                        subtitle!,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: scheme.onSurface.withValues(alpha: 0.7),
                        ),
                      )
                    : null,
                trailing: trailing,
                onTap: onTap,
                enabled: enabled,
                dense: dense,
                contentPadding: contentPadding,
              ),
              Align(
                alignment: Alignment.centerLeft,
                child: Padding(
                  padding: const EdgeInsets.only(left: 16),
                  child: Container(
                    width: 80,
                    height: 1,
                    color: scheme.outlineVariant.withValues(alpha: 0.8),
                  ),
                ),
              ),
            ],
          )
        : null;

    if (divider != null) return divider;
    return ListTile(
      leading: leading,
      title: Text(title, style: theme.textTheme.titleMedium),
      subtitle: subtitle != null
          ? Text(
              subtitle!,
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurface.withValues(alpha: 0.7),
              ),
            )
          : null,
      trailing: trailing,
      onTap: onTap,
      enabled: enabled,
      dense: dense,
      contentPadding: contentPadding,
    );
  }
}

/// M3 设置开关行（对齐参考版 `SwitchSettingItem`）
///
/// 语义与 `IosListTile` 同族（图标 + 标题 + 副标题 + 尾部），尾部固定为
/// `Switch`：整行可点即切换（参考版非 Miuix 分支 `onClick = onCheckedChange(!checked)`），
/// 语义经 `MergeSemantics` 合并为单一开关节点（与 `SwitchListTile` 同法）。
/// `onChanged == null` 时行禁用（文字灰显、不可点、开关灰置），同 `SwitchListTile`。
/// [icon] 为静态图标；[leading] 自定义前导件（忙态 spinner 等）优先于 [icon]。
/// [dense]/[contentPadding] 供密排行保留原参数（如 WebDav 组内 vertical12/horizontal8）。
class SettingSwitchRow extends StatelessWidget {
  final IconData? icon;
  final Widget? leading;
  final String title;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool>? onChanged;
  final bool? dense;
  final EdgeInsetsGeometry? contentPadding;

  const SettingSwitchRow({
    super.key,
    this.icon,
    this.leading,
    required this.title,
    this.subtitle,
    required this.value,
    this.onChanged,
    this.dense,
    this.contentPadding,
  });

  @override
  Widget build(BuildContext context) {
    final onChanged = this.onChanged;
    return MergeSemantics(
      child: IosListTile(
        icon: icon,
        leading: leading,
        title: title,
        subtitle: subtitle,
        showChevron: false,
        enabled: onChanged != null,
        dense: dense,
        contentPadding: contentPadding,
        // 同 SwitchListTile：控件不参与焦点，整行即单一焦点/语义目标
        trailing: ExcludeFocus(
          child: Switch(value: value, onChanged: onChanged),
        ),
        onTap: onChanged == null ? null : () => onChanged(!value),
      ),
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
