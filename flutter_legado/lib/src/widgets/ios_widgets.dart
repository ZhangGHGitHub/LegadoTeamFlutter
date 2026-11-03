import 'package:flutter/material.dart';

import '../providers/ui_settings/ui_settings_notifier.dart';
import '../services/theme_background_image_store.dart';
import '../theme/card_style.dart';

import 'pill_divider.dart';
import 'setting_cards.dart';
import 'glass_card_background.dart';
import 'nine_patch.dart';

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

/// tonal 圆角分组容器：行之间按设置绘制可选分隔线。
///
/// 容器视觉由 cardTheme 驱动（tonal surfaceContainer 层次）；
/// [separatorIndent] 为扁平模式分隔线左侧缩进（有 leading 图标时约 56）。
/// [LAYOUT_MOTION_AUDIT L2] 分组默认圆角 16dp（HapeLee SplicedColumnGroup，
/// 已确认；cardTheme 全局 20 保留，此处显式覆盖）；
/// [flat] 为 true 时走扁平模式（Column + 分隔线，HapeLee 设置页式，
/// 9 屏迁移用），默认 false 保持卡片兼容。
///
/// [设置批2b-1b-1] 卡片视觉接入参考版三项全局覆盖：
/// - 圆角：`disableSplicedColumnGroupCornerRadius`（0）优先于
///   `overrideBaseCardCornerRadius`（baseCardCornerRadius），否则 16dp；
/// - 边框：`overrideBaseCardBorder` 开启时按宽度/日/夜色绘制，
///   0 色回落 outlineVariant；用 foregroundDecoration 绘制，不改变布局、
///   不裁剪内容；
/// - 分隔线：`enableItemDivider` 开启时在相邻行之间插入 PillDivider
///   （行间距保持 2dp，与参考版 Column spacedBy(2) + divider 子项同构）；
///   [flat] 模式开关开同样使用该参数化线，开关关回落既有 0.5dp 细线。
///
/// [M3 我的页 | full-stack-engineer + UI | 2026-11-03] 新增可选 [footer]：
/// 参考版 `WebServiceSettingBlock` 的运行中操作按钮位于
/// `SplicedColumnGroup` 分组 Column **内**、且不是卡片行。footer 因此：
/// - 渲染在分组容器内部（同一背景图图层、同一圆角裁剪、同一
///   foregroundDecoration 边框包裹），位于最后一行之下；
/// - **不**套行卡（不包 surfaceContainerLow Material、不乘
///   containerOpacity）、**不**参与行分隔线与 2dp 行距；
/// - 仅由 [footerPadding] 提供内边距（默认水平 16dp 与行内容对齐、垂直
///   12dp，与参考版 `Row(padding(start/end = 16, top/bottom = 12))` 同值）。
/// [flat] 模式无卡片面，footer 同样按 [footerPadding] 渲染在末尾。
class IosGroup extends StatelessWidget {
  final List<Widget> children;
  final double separatorIndent;
  final EdgeInsets margin;
  final bool flat;

  /// 可选分组脚注（如运行中操作按钮行）：在分组容器内、最后一行下方，
  /// 不套行卡、不参与分隔线/2dp 行距；null 时不占位（默认）。
  final Widget? footer;

  /// footer 内边距（仅 footer 存在时生效）
  final EdgeInsetsGeometry footerPadding;

  const IosGroup({
    super.key,
    required this.children,
    this.separatorIndent = 16,
    this.margin = const EdgeInsets.symmetric(horizontal: 0),
    this.flat = false,
    this.footer,
    this.footerPadding = const EdgeInsets.fromLTRB(16, 12, 16, 12),
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final legacySeparator = Divider(
      height: 0.5,
      thickness: 0.5,
      indent: separatorIndent,
      color: theme.dividerColor,
    );

    return ValueListenableBuilder<UiSettingsState>(
      valueListenable: uiSettingsListenable,
      builder: (context, ui, _) {
        if (flat) {
          // 登记：flat 模式无卡片面，不参与容器背景图/不透明度/圆角/边框。
          // 分隔线：开关开 → 与卡片分组相同的 PillDivider 参数（宽/百分比/
          // 颜色/0 色灰 30%）；开关关 → 保留既有 0.5dp 细线作为「关」形态。
          final rows = <Widget>[];
          for (var i = 0; i < children.length; i++) {
            rows.add(children[i]);
            if (i != children.length - 1) {
              rows.add(
                ui.enableItemDivider
                    ? _itemDivider(
                        ui,
                        key: ValueKey('ios-group-flat-divider-$i'),
                      )
                    : legacySeparator,
              );
            }
          }
          // 扁平模式需自备透明 Material，否则 ListTile 的 ink 溅在远端
          // Material 祖先上会被中间 ColoredBox（IosGroupedBody）遮住而断言失败
          return Padding(
            padding: margin,
            child: Material(
              type: MaterialType.transparency,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ...rows,
                  // [M3] 扁平模式无卡片面，footer 仍按同一内边距渲染在末尾
                  //（不插分隔线/不加行距）
                  if (footer != null)
                    Padding(
                      key: const ValueKey('ios-group-footer'),
                      padding: footerPadding,
                      child: footer,
                    ),
                ],
              ),
            ),
          );
        }
        // [UI_SYNC_REFACTOR T2] 对齐参考 SplicedColumnGroup：16dp 玻璃分组卡
        //（surfaceContainer 底）+ 组内 spacedBy 2 + 每行 4dp surfaceContainerLow
        // 小卡底（SettingCard 等效）
        //
        // [设置批2b-1a / 2b-1b-2a 层序修正] 容器背景图/容器不透明度
        //（参考 `SplicedColumnGroup.kt:107-133`）：
        // - 背景图按当前亮暗取 largeContainerBackgroundImageLight/Dark；
        //   图像**铺满分组卡最底层**（Stack 第 0 层），由同一圆角裁剪。
        // - **没有整卡 scrim**：行小卡直接叠在图上，4dp 边距与 2dp 行距
        //   露出容器图；`containerOpacity` 只乘行卡 surface alpha
        //   （参考 `GlassCard.kt:155` alpha 只进行卡 BaseCard）。
        //   100% 时行卡不透明，但缝隙/边距仍显示图片（不是虚线边框）。
        // - 图片自身 alpha = appColumnBackgroundOpacity/100（参考版 Large
        //   图口径），与行卡 containerOpacity 独立叠加；0 时图片完全透明。
        //   文件缺失时静默回落为纯主题底色/全局壁纸。
        // - 文字不透明；图片层 IgnorePointer，不拦截点击/手势。
        final radius = BorderRadius.circular(
          resolveSplicedGroupCornerRadius(ui),
        );
        final borderSide = resolveBaseCardBorderSide(
          ui,
          theme.colorScheme,
          brightness: theme.brightness,
        );
        final opacity = (ui.containerOpacity / 100).clamp(0.0, 1.0);
        // [设置批2b-1b-2a] 大容器背景图自身不透明度（参考版
        // appColumnBackgroundOpacity，默认 100）：只乘图片 alpha，与行卡
        // 的 containerOpacity 独立叠加；0 时图片完全透明（参考
        // AppContainerBackground.kt:61）。
        final imageOpacity =
            (ui.appColumnBackgroundOpacity / 100).clamp(0.0, 1.0);
        // [P1 回修] 乘 alpha 而非替换：参考版 GlassCard.kt:74-75 为
        // `it.copy(alpha = it.alpha * alpha)`。透明调色板的
        // surfaceContainerLow 自带 alpha（如 0x00），直接 withValues 会
        // 覆盖调色板 alpha 把透明主题洗成不透明白卡、盖住容器背景图。
        final rowSurface = theme.colorScheme.surfaceContainerLow;
        final stored = theme.brightness == Brightness.dark
            ? ui.largeContainerBackgroundImageDark
            : ui.largeContainerBackgroundImageLight;
        final hasImage = ui.enableContainerBackgroundImage &&
            ThemeBackgroundImageStore.isUsableSync(stored);
        final imagePath =
            hasImage ? ThemeBackgroundImageStore.resolveSync(stored) : '';
        // [设置批2b-1b-2b] 项目（卡片）背景图（参考 GlassCard.kt:36-53,
        // 128-160；SettingCard 复用 GlassCard → 设置行卡即 Item 卡面）：
        // - 当前亮暗取 itemBackgroundImageLight/Dark，与 Large 图共用
        //   enableContainerBackgroundImage 总开关（AppContainerBackground
        //   .kt:51-63）；
        // - 图片层位于**行卡底色之上、行内容之下**，圆角与行卡一致；
        // - alpha 只受 glassCardBackgroundOpacity 控制，与 containerOpacity
        //   独立叠加：100% 图片覆盖行卡底色，0 完全透明。
        final itemStored = itemBackgroundStoredValue(ui, theme.brightness);
        final hasItemImage = hasUsableItemBackground(ui, theme.brightness);
        final itemImagePath = hasItemImage
            ? ThemeBackgroundImageStore.resolveSync(itemStored)
            : '';
        final rowRadius = BorderRadius.circular(4);
        return Padding(
          padding: margin,
          child: Container(
            key: const ValueKey('ios-group-frame'),
            // 边框画在内容之上、不参与布局（参考版 BorderStroke 不改变卡尺寸）
            foregroundDecoration: borderSide == null
                ? null
                : BoxDecoration(
                    borderRadius: radius,
                    border: Border.fromBorderSide(borderSide),
                  ),
            child: ClipRRect(
              borderRadius: radius,
              child: Stack(
                children: [
                  // 背景图铺满分组最底层；行卡直接叠在图上，缝隙/边距露出图片
                  if (hasImage)
                    Positioned.fill(
                      child: IgnorePointer(
                        child: Opacity(
                          key: const ValueKey(
                              'ios-group-container-background-opacity'),
                          opacity: imageOpacity,
                          // [设置批2b-1b-2b] 统一图片构建：`.9.png` 走
                          // centerSlice + BoxFit.fill，普通图 cover
                          child: buildBackgroundImage(
                            key: const ValueKey(
                                'ios-group-container-background'),
                            context: context,
                            path: imagePath,
                          ),
                        ),
                      ),
                    ),
                  // 行容器无整卡 scrim（参考 SplicedColumnGroup 无分组底色）：
                  // 行卡**满宽**、无 4dp 内边距，图片只从 2dp 行距与分组圆角
                  // 边缘露出；decoration 只承载圆角供既有测试/识别，不绘制颜色。
                  // [设置批2b-1b-2a] 参考 `SplicedColumnGroup.kt:107-133` 的
                  // Column 无 padding/spacedBy(2)，行卡自身满宽。
                  // [设置批2b-1b-1-b] 分隔线拿到分组**外宽**（参考版
                  // `fillMaxWidth(fraction)` 不含额外内层缩进）。
                  Container(
                    key: const ValueKey('ios-group-surface'),
                    decoration: BoxDecoration(borderRadius: radius),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        for (var i = 0; i < children.length; i++) ...[
                          Material(
                            key: ValueKey('ios-group-row-$i'),
                            color: rowSurface.withValues(
                              alpha: rowSurface.a * opacity,
                            ),
                            borderRadius: rowRadius,
                            clipBehavior: Clip.antiAlias,
                            // [设置批2b-1b-2b P2] 行树恒定 Stack：
                            // - 有项目图时第 0 层为图片（卡面色之上）；
                            // - 第 1 层恒为透明 Material 承载行内容：ListTile/
                            //   InkWell 的水波纹画在该层（图片之上），项目图
                            //   100% 不透明时仍可见；无图时结构不变，避免
                            //   图片开关导致 Element 类型切换丢状态。
                            child: Stack(
                              children: [
                                if (hasItemImage)
                                  Positioned.fill(
                                    child: GlassCardBackground(
                                      key: ValueKey(
                                          'ios-group-item-background-$i'),
                                      path: itemImagePath,
                                      opacityPercent:
                                          ui.glassCardBackgroundOpacity,
                                      borderRadius: rowRadius,
                                      opacityKey: ValueKey(
                                          'ios-group-item-background-opacity-$i'),
                                      imageKey: ValueKey(
                                          'ios-group-item-background-image-$i'),
                                    ),
                                  ),
                                Material(
                                  type: MaterialType.transparency,
                                  child: children[i],
                                ),
                              ],
                            ),
                          ),
                          if (i != children.length - 1) ...[
                            const SizedBox(height: 2),
                            if (ui.enableItemDivider)
                              _itemDivider(
                                ui,
                                key: ValueKey('ios-group-divider-$i'),
                              ),
                            if (ui.enableItemDivider)
                              const SizedBox(height: 2),
                          ],
                        ],
                        // [M3] footer 在分组容器内、最后一行下方：位于同一
                        // Container（背景图之上、圆角裁剪内、foregroundDecoration
                        // 边框下），但不套行卡 Material、不插分隔线/2dp 行距。
                        // containerOpacity 只作用于行卡 alpha，footer 无卡片面。
                        if (footer != null)
                          Padding(
                            key: const ValueKey('ios-group-footer'),
                            padding: footerPadding,
                            child: footer,
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  /// 参数化分隔线（卡片/扁平分组共用；调用方保证开关已开）
  Widget _itemDivider(UiSettingsState ui, {required Key key}) {
    return PillDivider(
      key: key,
      widthFraction: resolveItemDividerWidthFraction(ui.itemDividerLength),
      thickness: ui.itemDividerWidth.toDouble(),
      color: resolveItemDividerColor(ui.itemDividerColor),
      padding: EdgeInsets.zero,
      enabled: ui.itemDividerWidth > 0,
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

    // [设置批2b-1b-1] 行内分隔线已移除：参考版 `SettingItemDivider` 由分组
    // 容器在相邻项之间插入（SplicedColumnGroup + SettingItemWithDivider），
    // 行自身不画线（否则末行多一条、扁平分组出现双线）。分隔线配置
    //（开关/宽度/长度百分比/颜色）统一由 IosGroup 消费。
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
