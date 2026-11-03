import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../providers/ui_settings/ui_settings_notifier.dart';
import '../routes.dart';
import '../services/theme_background_image_store.dart';
import '../widgets/glass_card_background.dart';

/// 设置主页（集中化分组入口）
///
/// [UI_SYNC_REFACTOR S6 | 2026-09-08] 差异清单批八：对齐参考版「设置主页
/// 集中化」结构——参考版 8 组（外观/高级/阅读界面/封面设置/下载与缓存/
/// 备份与恢复/AI 设置/翻译设置）；我方按真实功能映射为入口列表，封面设置
/// 暂缺（登记）。
///
/// [设置批10a | 2026-11-04 用户裁决] 参考版「AI 设置/翻译设置/实验室」
/// 三入口以占位形态补齐（副题「暂未支持」），点击进入只说明暂未支持的
/// 页面壳，不接任何功能；Rust 能力立项后再替换路由实现。
///
/// [设置批2b-1b-2a] 本页入口卡为手写 Material（16dp 圆角、10dp 行距），
/// 不在 IosGroup/CardTheme 覆盖范围内；此处按同一口径乘 containerOpacity
/// 卡面 alpha（文字/图标保持不透明），使容器不透明度在该页生效。
/// [设置批2b-1b-2b] 入口卡按 GlassCard 语义叠加项目背景图
/// （itemBackgroundImageLight/Dark，总开关 enableContainerBackgroundImage，
/// alpha=glassCardBackgroundOpacity/100）：图片层位于卡面底色之上、内容
/// 之下，圆角 16dp 裁剪，IgnorePointer 不拦截点击。
/// 登记（2b-1b-2c）：本页仍不渲染大容器背景图（appColumnBackgroundOpacity
/// 在该页无视觉作用）；书架/详情/对话框等其余 GlassCard 卡面待迁移。
class SettingsHomeScreen extends StatelessWidget {
  const SettingsHomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<UiSettingsState>(
      valueListenable: uiSettingsListenable,
      builder: (context, ui, _) => _buildContent(context, ui),
    );
  }

  Widget _buildContent(BuildContext context, UiSettingsState ui) {
    final cs = Theme.of(context).colorScheme;
    final opacity = (ui.containerOpacity / 100).clamp(0.0, 1.0);
    // 乘 alpha 而非替换（同 IosGroup/参考 GlassCard.kt:74-75）：
    // 透明调色板的 surfaceContainerLow 自带 alpha 时不能被洗成实色。
    final cardColor = cs.surfaceContainerLow.withValues(
      alpha: cs.surfaceContainerLow.a * opacity,
    );
    const cardRadius = BorderRadius.all(Radius.circular(16));
    // [设置批2b-1b-2b] 项目背景图（GlassCard Item 语义）
    final brightness = Theme.of(context).brightness;
    final itemStored = itemBackgroundStoredValue(ui, brightness);
    final hasItemImage = hasUsableItemBackground(ui, brightness);
    final itemImagePath = hasItemImage
        ? ThemeBackgroundImageStore.resolveSync(itemStored)
        : '';
    final entries = [
      (Symbols.palette_rounded, '外观', '主题配色与显示模式',
          () => Navigator.pushNamed(context, AppRoutes.themeConfig)),
      (Symbols.tune_rounded, '高级', '功能相关的一些设置',
          () => Navigator.pushNamed(context, AppRoutes.otherSettings)),
      // [批1a | 2026-10-31] 「阅读界面」改进独立「阅读设置」页（对齐参考版
      // ConfigNavScreen Reading Interface Settings 入口语义）；阅读器内
      // 四页签弹层（ReaderSettingsSheet）入口保留不动 — 全栈工程师
      (Symbols.style_rounded, '阅读界面', '屏幕/页面控制/阅读偏好',
          () => Navigator.pushNamed(context, AppRoutes.readConfig)),
      (Symbols.backup_rounded, '备份与恢复', 'WebDav 设置/导入旧版本数据',
          () => Navigator.pushNamed(context, AppRoutes.webdavSettings)),
      (Symbols.download_rounded, '缓存管理', '书籍下载任务与缓存进度',
          () => Navigator.pushNamed(context, AppRoutes.offlineCache)),
      (Symbols.book_rounded, '书源管理', '新建、导入、编辑或管理书源',
          () => Navigator.pushNamed(context, AppRoutes.sources)),
      (Symbols.schedule_rounded, '定时任务', '管理按计划执行的 JavaScript 任务',
          () => Navigator.pushNamed(context, AppRoutes.autoTasks)),
      // [设置批10a | 2026-11-04 用户裁决] 三占位入口：明确「暂未支持」，
      // 页面无输入/网络/开关（不制造可用假象）
      (Symbols.auto_awesome_rounded, 'AI 设置', '暂未支持',
          () => Navigator.pushNamed(context, AppRoutes.aiSettings)),
      (Symbols.translate_rounded, '翻译设置', '暂未支持',
          () => Navigator.pushNamed(context, AppRoutes.translationSettings)),
      (Symbols.science_rounded, '实验室', '暂未支持',
          () => Navigator.pushNamed(context, AppRoutes.labSettings)),
      // [N6 | 2026-09-20 用户裁决（授权偏离已登记，见
      // docs/SCREEN_1TO1_PARITY_LEDGER_20260914.md 3-7/N6）]「字体管理」
      // 入口自设置可见列表收起：参考版字号/字体仅在阅读器内调整、无独立
      // 设置入口；字体页（font_screen / AppRoutes.fonts）与功能保留，仍经
      // 阅读器排版面板「阅读字体」行进入（reader_config_panel /
      // reader_settings_sheet_font_panel，与参考版阅读器内字体能力对齐）。
      (Symbols.info_rounded, '关于', '版本、日志与开源许可',
          () => Navigator.pushNamed(context, AppRoutes.about)),
    ];
    return Scaffold(
      body: CustomScrollView(
        slivers: [
          SliverAppBar.large(
            title: const Text('设置'),
            leading: IconButton(
              onPressed: () => Navigator.of(context).maybePop(),
              icon: const Icon(Symbols.arrow_back_rounded),
            ),
          ),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
            sliver: SliverList.separated(
              itemCount: entries.length,
              separatorBuilder: (_, _) => const SizedBox(height: 10),
              itemBuilder: (context, i) {
                final (icon, title, subtitle, onTap) = entries[i];
                return Material(
                  color: cardColor,
                  borderRadius: cardRadius,
                  // 项目图与卡片同 16dp 圆角裁剪（参考 GlassCard clip(shape)）
                  clipBehavior: Clip.antiAlias,
                  child: Stack(
                    children: [
                      // 项目图在卡面底色之上、入口内容之下；无图时整层不建
                      if (hasItemImage)
                        Positioned.fill(
                          child: GlassCardBackground(
                            key: ValueKey('settings-home-item-background-$i'),
                            path: itemImagePath,
                            opacityPercent: ui.glassCardBackgroundOpacity,
                            borderRadius: cardRadius,
                            opacityKey: ValueKey(
                                'settings-home-item-background-opacity-$i'),
                            imageKey: ValueKey(
                                'settings-home-item-background-image-$i'),
                          ),
                        ),
                      // 内容层恒为透明 Material：InkWell 水波纹画在项目图
                      // 之上（100% 不透明时仍可见），且无图/有图结构一致。
                      Material(
                        type: MaterialType.transparency,
                        child: InkWell(
                          borderRadius: cardRadius,
                          onTap: onTap,
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 14,
                            ),
                            child: Row(
                              children: [
                                Icon(icon,
                                    size: 22, color: cs.onSurfaceVariant),
                                const SizedBox(width: 14),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(title,
                                          style: Theme.of(context)
                                              .textTheme
                                              .titleSmall),
                                      const SizedBox(height: 2),
                                      Text(
                                        subtitle,
                                        style: Theme.of(context)
                                            .textTheme
                                            .bodySmall
                                            ?.copyWith(
                                              color: cs.onSurfaceVariant,
                                            ),
                                      ),
                                    ],
                                  ),
                                ),
                                Icon(Symbols.chevron_right_rounded,
                                    size: 20, color: cs.onSurfaceVariant),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
