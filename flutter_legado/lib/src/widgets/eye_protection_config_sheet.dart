// [设置批2a-1 | 2026-11-01] 护眼模式配置面板（阅读设置行共用）— 全栈工程师
//
// 参考版：`ui/book/read/sheet/EyeProtectionConfigSheet.kt:28-133`
// （启用护眼模式 / 深色模式时自动开启 / 护眼强度 / 定时开启 / 起止时间，
// 时间用 24 小时制 TimePickerDialog）。外观设置页仍用参考版
// ThemeConfigScreen 的行内分组；阅读设置页行打开本面板，两处共用
// eyeProtectionProvider（同一份持久化值）。
//
// 与外观页共用 [EyeProtectionIntensityRow]，避免两套滑杆行为分叉。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;

import '../models/eye_protection.dart';
import '../providers/theme/eye_protection_notifier.dart';
import 'ios_widgets.dart';

/// 打开护眼模式配置面板（底部弹层）
Future<void> showEyeProtectionConfigSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (sheetContext) => Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.viewInsetsOf(sheetContext).bottom,
      ),
      child: const SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(16, 0, 16, 24),
        child: EyeProtectionConfigPanel(),
      ),
    ),
  );
}

/// 护眼模式配置面板内容（阅读设置页入口使用）
class EyeProtectionConfigPanel extends ConsumerWidget {
  const EyeProtectionConfigPanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(eyeProtectionProvider);
    final notifier = ref.read(eyeProtectionProvider.notifier);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 0, 4, 12),
          child: Text('护眼模式', style: Theme.of(context).textTheme.titleLarge),
        ),
        IosGroup(
          children: [
            SettingSwitchRow(
              title: '启用护眼模式',
              subtitle: '使用暖色调降低蓝光',
              value: settings.enabled,
              onChanged: notifier.setEnabled,
            ),
            SettingSwitchRow(
              title: '深色模式时自动开启',
              subtitle: '跟随阅读界面的深色/浅色模式自动切换',
              value: settings.autoNight,
              onChanged: notifier.setAutoNight,
            ),
            if (settings.isConfigured) ...[
              EyeProtectionIntensityRow(
                value: settings.intensity,
                onChanged: notifier.setIntensity,
                // 阅读侧文案对齐参考版 EyeProtectionConfigSheet（护眼强度）；
                // 外观页沿用 ThemeConfigScreen 的「色温」（默认参数）
                title: '护眼强度',
                descriptionPrefix: '当前强度',
              ),
              SettingSwitchRow(
                title: '定时开启',
                subtitle: '仅在设定的时间段内生效',
                value: settings.schedule,
                onChanged: notifier.setSchedule,
              ),
              if (settings.schedule) ...[
                IosListTile(
                  title: '开始时间',
                  value: settings.startTime,
                  onTap: () => pickEyeProtectionTime(context, ref, start: true),
                ),
                IosListTile(
                  title: '结束时间',
                  value: settings.endTime,
                  onTap: () =>
                      pickEyeProtectionTime(context, ref, start: false),
                ),
              ],
            ],
          ],
        ),
      ],
    );
  }
}

/// 选择护眼定时起止时间（24 小时制、值格式 `HH:mm`）
///
/// 当前值解析失败时回落到 00:00（解析口径见 EyeProtectionFilter.parseClock）；
/// 参考版 TimePickerDialog.kt 同样固定 24 小时制。
Future<void> pickEyeProtectionTime(
  BuildContext context,
  WidgetRef ref, {
  required bool start,
}) async {
  final settings = ref.read(eyeProtectionProvider);
  final current = EyeProtectionFilter.parseClock(
    start ? settings.startTime : settings.endTime,
  );
  final picked = await showTimePicker(
    context: context,
    initialTime: TimeOfDay(
      hour: current?.hour ?? 0,
      minute: current?.minute ?? 0,
    ),
    helpText: start ? '开始时间' : '结束时间',
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(alwaysUse24HourFormat: true),
      child: child!,
    ),
  );
  if (picked == null || !context.mounted) return;
  final text =
      '${picked.hour.toString().padLeft(2, '0')}:'
      '${picked.minute.toString().padLeft(2, '0')}';
  final notifier = ref.read(eyeProtectionProvider.notifier);
  if (start) {
    await notifier.setStartTime(text);
  } else {
    await notifier.setEndTime(text);
  }
}

/// 行内「色温」滑杆（外观页分组与阅读设置面板共用）
///
/// 拖动中仅本地预览，松手提交一次（与阅读设置页 SettingSliderRow 口径一致）。
///
/// 与参考版差异（设置批2a-1 登记）：参考 `SliderSettingItem` 默认收起、点开后
/// 提供数值输入与「恢复默认 50」按钮；我方按现有设置页口径常显滑杆 + 当前
/// 值说明，不新增输入/重置交互（避免引入未授权的新交互面），提交语义一致。
class EyeProtectionIntensityRow extends StatefulWidget {
  final int value;
  final ValueChanged<int> onChanged;

  /// 行标题：外观页「色温」/ 阅读面板「护眼强度」（参考版两处文案不同）
  final String title;

  /// 当前值说明前缀：外观页「当前色温」/ 阅读面板「当前强度」
  final String descriptionPrefix;

  const EyeProtectionIntensityRow({
    super.key,
    required this.value,
    required this.onChanged,
    this.title = '色温',
    this.descriptionPrefix = '当前色温',
  });

  @override
  State<EyeProtectionIntensityRow> createState() =>
      _EyeProtectionIntensityRowState();
}

class _EyeProtectionIntensityRowState extends State<EyeProtectionIntensityRow> {
  /// 拖动中的本地预览值（null = 未在拖动，显示外部值）
  int? _preview;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final shown = _preview ?? widget.value;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(widget.title, style: theme.textTheme.titleMedium),
          Text(
            '${widget.descriptionPrefix}：$shown',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          Slider(
            key: const ValueKey<String>('eyeProtectionIntensitySlider'),
            value: shown.toDouble().clamp(
              EyeProtectionFilter.minIntensity.toDouble(),
              EyeProtectionFilter.maxIntensity.toDouble(),
            ),
            min: EyeProtectionFilter.minIntensity.toDouble(),
            max: EyeProtectionFilter.maxIntensity.toDouble(),
            divisions: EyeProtectionFilter.maxIntensity,
            label: '$shown',
            onChanged: (v) => setState(() => _preview = v.round()),
            onChangeEnd: (v) {
              final target = v.round().clamp(
                EyeProtectionFilter.minIntensity,
                EyeProtectionFilter.maxIntensity,
              );
              setState(() => _preview = null);
              widget.onChanged(target);
            },
          ),
        ],
      ),
    );
  }
}
