import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

/// 自动翻页运行时浮条（差异清单 C10，形态对齐参考版「即开即调」）
///
/// 自动翻页进行中、且菜单未展开时浮于正文底部：显示当前间隔 + 速度步进
/// （±[stepSeconds] 秒）+ 目录 / 停止 / 设置三个快捷入口。
/// 与「界面」弹层里的自动翻页配置卡并存：本浮条只做运行时微调，不新开配置面。
/// — Qoder UI ｜ 2026-09-11
class AutoTurnPanel extends StatelessWidget {
  /// 当前翻页间隔（秒）
  final double intervalSeconds;

  /// 间隔步进粒度（秒）
  final double stepSeconds;

  /// 间隔可调范围（与原版定时翻页 3~120 秒一致）
  final double minSeconds;
  final double maxSeconds;

  /// 调整间隔（已夹取范围）
  final ValueChanged<double> onIntervalChanged;

  /// 停止自动翻页
  final VoidCallback onStop;

  /// 打开目录
  final VoidCallback onOpenCatalog;

  /// 打开阅读设置（界面弹层）
  final VoidCallback onOpenSettings;

  const AutoTurnPanel({
    super.key,
    required this.intervalSeconds,
    required this.onIntervalChanged,
    required this.onStop,
    required this.onOpenCatalog,
    required this.onOpenSettings,
    this.stepSeconds = 5,
    this.minSeconds = 3,
    this.maxSeconds = 120,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final ts = Theme.of(context).textTheme;

    Widget roundIcon(IconData icon, String tooltip, VoidCallback onTap) {
      return IconButton(
        icon: Icon(icon, size: 20),
        tooltip: tooltip,
        visualDensity: VisualDensity.compact,
        color: cs.onSurface,
        onPressed: onTap,
      );
    }

    return Material(
      elevation: 3,
      color: cs.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(20),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.only(left: 6, right: 2),
              child: Text(
                '自动翻页',
                style: ts.labelMedium?.copyWith(color: cs.onSurfaceVariant),
              ),
            ),
            // 速度步进：− / 当前间隔 / ＋（对齐参考版 [−10s+] 形态，步进 5 秒）
            roundIcon(Symbols.remove_rounded, '减慢翻页', () {
              onIntervalChanged(
                  (intervalSeconds - stepSeconds).clamp(minSeconds, maxSeconds));
            }),
            SizedBox(
              width: 44,
              child: Text(
                '${intervalSeconds.round()} 秒',
                textAlign: TextAlign.center,
                style: ts.labelLarge?.copyWith(color: cs.onSurface),
              ),
            ),
            roundIcon(Symbols.add_rounded, '加快翻页', () {
              onIntervalChanged(
                  (intervalSeconds + stepSeconds).clamp(minSeconds, maxSeconds));
            }),
            const SizedBox(width: 2),
            Container(width: 1, height: 20, color: cs.outlineVariant),
            roundIcon(Symbols.format_list_bulleted_rounded, '目录', onOpenCatalog),
            roundIcon(Symbols.stop_circle_rounded, '停止自动翻页', onStop),
            roundIcon(Symbols.style_rounded, '阅读设置', onOpenSettings),
          ],
        ),
      ),
    );
  }
}
