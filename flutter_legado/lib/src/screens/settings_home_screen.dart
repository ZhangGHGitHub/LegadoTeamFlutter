import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../routes.dart';
import '../widgets/reader/reader_settings_sheet.dart';

/// 设置主页（集中化分组入口）
///
/// [UI_SYNC_REFACTOR S6 | 2026-09-08] 差异清单批八：对齐参考版「设置主页
/// 集中化」结构——参考版 8 组（外观/高级/阅读界面/封面设置/下载与缓存/
/// 备份与恢复/AI 设置/翻译设置）；我方按真实功能映射为 9 组，封面设置/
/// AI 设置/翻译设置暂缺（AI 设置随 AI 批次，其余登记）— Qoder
class SettingsHomeScreen extends StatelessWidget {
  const SettingsHomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final entries = [
      (Symbols.palette_rounded, '外观', '主题配色与显示模式',
          () => Navigator.pushNamed(context, AppRoutes.themeConfig)),
      (Symbols.tune_rounded, '高级', '功能相关的一些设置',
          () => Navigator.pushNamed(context, AppRoutes.otherSettings)),
      (Symbols.style_rounded, '阅读界面', '字号/背景/翻页动画/排版',
          () => ReaderSettingsSheet.show(context)),
      (Symbols.backup_rounded, '备份与恢复', 'WebDav 设置/导入旧版本数据',
          () => Navigator.pushNamed(context, AppRoutes.webdavSettings)),
      (Symbols.download_rounded, '缓存管理', '书籍下载任务与缓存进度',
          () => Navigator.pushNamed(context, AppRoutes.offlineCache)),
      (Symbols.book_rounded, '书源管理', '新建、导入、编辑或管理书源',
          () => Navigator.pushNamed(context, AppRoutes.sources)),
      (Symbols.schedule_rounded, '定时任务', '管理按计划执行的 JavaScript 任务',
          () => Navigator.pushNamed(context, AppRoutes.autoTasks)),
      (Symbols.font_download_rounded, '字体管理', '阅读字体选择与导入',
          () => Navigator.pushNamed(context, AppRoutes.fonts)),
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
                  color: cs.surfaceContainerLow,
                  borderRadius: BorderRadius.circular(16),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(16),
                    onTap: onTap,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 14,
                      ),
                      child: Row(
                        children: [
                          Icon(icon, size: 22, color: cs.onSurfaceVariant),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
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
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
