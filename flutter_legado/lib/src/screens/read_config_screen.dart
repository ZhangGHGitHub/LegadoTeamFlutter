// 独立「阅读设置」页（批1a，对齐参考版 ui/config/readConfig 三组结构）
//
// 入口：设置主页「阅读界面」行（reader_screen 内弹层入口保留不动）。
// 数据：与阅读器弹层共用 [ReaderAdvancedConfig] 同一模型同一持久化键，
// 改值即 save() + 推送 readerAdvConfigProvider，返回阅读器即时生效。
// 视觉：按 SETTINGS_GAP_SCOPE §六裁决 6（拼接卡片组、行内滑块/下拉/步进），
// 复用 IosGroup / SettingSwitchRow，新增行内滑块/下拉/步进行组件（本文件内，
// 不动 other_settings_screen）。
//
// 仅收录已有消费方的项（禁新造死开关）：
// - 屏幕：screenOrientation/hideStatusBar/hideNavigationBar/
//   paddingDisplayCutouts/showBrightnessView/doubleHorizontalPage/
//   progressBarBehavior/readBodyToLh
//   （keepLight 有字段无消费，留 1b，不放本页）
// - 页面控制：useZhLayout/textFullJustify/hangingPunctuation/pageTouchClick/
//   pageTouchSlop/volumeKeyPage/volumeKeyPageOnPlay/mouseWheelPage/
//   noAnimScrollPage/autoChangeSource/selectText/showReadTitleAddition
//   （showReadTitleAddition 本批新接线 reader_menu_panel 信息块显隐）
// - 其他：sliderVibrator/selectVibrator（本批新接线振动）、disableReturnKey
//   （本批新接线 PopScope 拦截）
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;

import '../widgets/app_scaffold.dart';
import '../widgets/ios_widgets.dart';
import '../widgets/legado_app_bar.dart';
import '../widgets/setting_cards.dart' show LabelMediumEmphasized;
import 'reader_config_panel.dart';

part 'read_config_screen_data.part.dart';

/// 独立阅读设置页（三组：屏幕 / 页面控制 / 其他）
class ReadConfigScreen extends ConsumerStatefulWidget {
  const ReadConfigScreen({super.key});

  @override
  ConsumerState<ReadConfigScreen> createState() => _ReadConfigScreenState();
}

class _ReadConfigScreenState extends ConsumerState<ReadConfigScreen> {
  /// 页面本地快照（null = 加载中）；改动即写回该对象并持久化
  ReaderAdvancedConfig? _config;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final cfg = await ReaderAdvancedConfig.load();
    if (!mounted) return;
    setState(() => _config = cfg);
    // 同步共享 provider（阅读器未打开时也保持单源）
    ref.read(readerAdvConfigProvider.notifier).apply(cfg);
  }

  /// 统一改值入口：写回快照 → 持久化 → 推共享 provider（阅读器即时生效）
  void _update(void Function(ReaderAdvancedConfig cfg) mutate) {
    final cfg = _config;
    if (cfg == null) return;
    mutate(cfg);
    setState(() {});
    unawaited(_persist());
  }

  /// save + provider 推送
  Future<void> _persist() async {
    final cfg = _config;
    if (cfg == null) return;
    await cfg.save();
    ref.read(readerAdvConfigProvider.notifier).apply(cfg.copy());
  }

  @override
  Widget build(BuildContext context) {
    final cfg = _config;
    return AppScaffold(
      topBar: const LegadoAppBar(title: Text('阅读设置')),
      body: cfg == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
              children: [
                const IosSectionHeader('屏幕'),
                IosGroup(
                  children: _screenGroup(cfg),
                ),
                const IosSectionHeader('页面控制'),
                IosGroup(
                  children: _pageControlGroup(cfg),
                ),
                const IosSectionHeader('其他'),
                IosGroup(
                  children: _otherGroup(cfg),
                ),
              ],
            ),
    );
  }

  // ── 组1「屏幕」（对齐参考版 ReadConfigScreen 组1，仅放已有消费方） ──

  List<Widget> _screenGroup(ReaderAdvancedConfig cfg) => [
        SettingDropdownRow<int>(
          title: '屏幕方向',
          value: cfg.screenOrientation,
          options: _kScreenOrientationOptions,
          onChanged: (v) => _update((c) => c.screenOrientation = v),
        ),
        SettingSwitchRow(
          title: '隐藏状态栏',
          value: cfg.hideStatusBar,
          onChanged: (v) => _update((c) => c.hideStatusBar = v),
        ),
        SettingSwitchRow(
          title: '隐藏导航栏',
          value: cfg.hideNavigationBar,
          onChanged: (v) => _update((c) => c.hideNavigationBar = v),
        ),
        SettingSwitchRow(
          title: '填充刘海区域',
          value: cfg.paddingDisplayCutouts,
          onChanged: (v) => _update((c) => c.paddingDisplayCutouts = v),
        ),
        SettingSwitchRow(
          title: '扩展到刘海',
          value: cfg.readBodyToLh,
          onChanged: (v) => _update((c) => c.readBodyToLh = v),
        ),
        SettingSwitchRow(
          title: '显示亮度调节控件',
          value: cfg.showBrightnessView,
          onChanged: (v) => _update((c) => c.showBrightnessView = v),
        ),
        SettingDropdownRow<int>(
          title: '平板/横屏双页',
          value: cfg.doubleHorizontalPage,
          options: _kDoublePageOptions,
          onChanged: (v) => _update((c) => c.doubleHorizontalPage = v),
        ),
        SettingDropdownRow<String>(
          title: '进度条行为',
          value: cfg.progressBarBehavior,
          options: _kProgressBarBehaviorOptions,
          onChanged: (v) => _update((c) => c.progressBarBehavior = v),
        ),
      ];

  // ── 组2「页面控制」 ──

  List<Widget> _pageControlGroup(ReaderAdvancedConfig cfg) => [
        SettingSwitchRow(
          title: '使用自定义中文分行',
          value: cfg.useZhLayout,
          onChanged: (v) => _update((c) => c.useZhLayout = v),
        ),
        SettingSwitchRow(
          title: '文字两端对齐',
          value: cfg.textFullJustify,
          onChanged: (v) => _update((c) => c.textFullJustify = v),
        ),
        SettingSwitchRow(
          title: '段首标点悬挂',
          subtitle: '段首引号等标点悬挂于缩进内，使正文首字与其他段落对齐',
          value: cfg.hangingPunctuation,
          onChanged: (v) => _update((c) => c.hangingPunctuation = v),
        ),
        SettingStepperRow(
          title: '边缘点击阈值',
          unit: 'px',
          value: cfg.pageTouchClick,
          min: 0,
          max: 399,
          step: 10,
          onChanged: (v) => _update((c) => c.pageTouchClick = v),
        ),
        SettingSliderRow(
          title: '滑动翻页阈值',
          value: cfg.pageTouchSlop,
          min: 0,
          max: 1000,
          onChanged: (v) => _update((c) => c.pageTouchSlop = v),
        ),
        SettingSwitchRow(
          title: '鼠标滚轮翻页',
          value: cfg.mouseWheelPage,
          onChanged: (v) => _update((c) => c.mouseWheelPage = v),
        ),
        SettingSwitchRow(
          title: '音量键翻页',
          value: cfg.volumeKeyPage,
          onChanged: (v) => _update((c) => c.volumeKeyPage = v),
        ),
        SettingSwitchRow(
          title: '朗读时音量键翻页',
          value: cfg.volumeKeyPageOnPlay,
          onChanged: (v) => _update((c) => c.volumeKeyPageOnPlay = v),
        ),
        SettingSwitchRow(
          title: '禁用滚动点击动画',
          value: cfg.noAnimScrollPage,
          onChanged: (v) => _update((c) => c.noAnimScrollPage = v),
        ),
        SettingSwitchRow(
          title: '自动换源',
          value: cfg.autoChangeSource,
          onChanged: (v) => _update((c) => c.autoChangeSource = v),
        ),
        SettingSwitchRow(
          title: '长按选择文本',
          value: cfg.selectText,
          onChanged: (v) => _update((c) => c.selectText = v),
        ),
        SettingSwitchRow(
          title: '展示顶部工具栏附加区域',
          value: cfg.showReadTitleAddition,
          onChanged: (v) => _update((c) => c.showReadTitleAddition = v),
        ),
      ];

  // ── 组3「其他」（本批三项新接线） ──

  List<Widget> _otherGroup(ReaderAdvancedConfig cfg) => [
        SettingSwitchRow(
          title: '翻页成功振动',
          value: cfg.sliderVibrator,
          onChanged: (v) => _update((c) => c.sliderVibrator = v),
        ),
        SettingSwitchRow(
          title: '选词振动',
          value: cfg.selectVibrator,
          onChanged: (v) => _update((c) => c.selectVibrator = v),
        ),
        SettingSwitchRow(
          title: '禁用返回键',
          value: cfg.disableReturnKey,
          onChanged: (v) => _update((c) => c.disableReturnKey = v),
        ),
      ];
}

// ── 行内控件行组件（对齐参考版 SliderSettingItem / DropdownListSettingItem
//    形态：标题 + 行内控件；仅本页使用，避免动批9a 触碰的
//    other_settings_screen）──

/// 行内滑块行：标题 + 当前值 + Slider（参考版 SliderSettingItem 形态）
class SettingSliderRow extends StatelessWidget {
  final String title;
  final int value;
  final int min;
  final int max;

  /// 拖动即提交（数值行拖动频率低，逐帧写盘与既有字号滑块不同、可接受；
  /// 调用方 _update 内部为异步 save，无 UI 卡顿路径）
  final ValueChanged<int> onChanged;

  const SettingSliderRow({
    super.key,
    required this.title,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(title, style: Theme.of(context).textTheme.titleMedium),
              Text(
                '$value',
                style: Theme.of(context).textTheme.labelMediumEmphasized
                    ?.copyWith(color: cs.primary),
              ),
            ],
          ),
          Slider(
            value: value.toDouble().clamp(min.toDouble(), max.toDouble()),
            min: min.toDouble(),
            max: max.toDouble(),
            divisions: max - min,
            label: '$value',
            onChanged: (v) => onChanged(v.round()),
          ),
        ],
      ),
    );
  }
}

/// 行内下拉行：标题 + 尾部 DropdownButton（参考版 DropdownListSettingItem
/// 形态：行尾展开选择，选中值显示在尾部；整行可点弹同数据选择框兜底）
class SettingDropdownRow<T> extends StatelessWidget {
  final String title;
  final T value;

  /// 选项（值 → 显示文案；展示顺序按 Map 迭代序）
  final Map<T, String> options;
  final ValueChanged<T> onChanged;

  const SettingDropdownRow({
    super.key,
    required this.title,
    required this.value,
    required this.options,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return IosListTile(
      title: title,
      showChevron: false,
      trailing: DropdownButtonHideUnderline(
        child: DropdownButton<T>(
          value: options.containsKey(value) ? value : null,
          items: [
            for (final e in options.entries)
              DropdownMenuItem<T>(value: e.key, child: Text(e.value)),
          ],
          onChanged: (v) {
            if (v != null) onChanged(v);
          },
        ),
      ),
      onTap: () => unawaited(_showPickerDialog(context)),
    );
  }

  /// 点行弹出选择对话框（键盘/读屏可达性兜底；与尾部下拉同数据）
  Future<void> _showPickerDialog(BuildContext context) {
    return showDialog<void>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text(title),
        children: [
          for (final e in options.entries)
            SimpleDialogOption(
              onPressed: () {
                Navigator.pop(ctx);
                onChanged(e.key);
              },
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Text(
                  e.value,
                  style: e.key == value
                      ? TextStyle(
                          fontWeight: FontWeight.w600,
                          color: Theme.of(ctx).colorScheme.primary,
                        )
                      : null,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 行内步进行：标题 + 单位副标题 + 数值 + 减/加按钮
///（参考版数值项行内步进形态）
class SettingStepperRow extends StatelessWidget {
  final String title;
  final String unit;
  final int value;
  final int min;
  final int max;
  final int step;
  final ValueChanged<int> onChanged;

  const SettingStepperRow({
    super.key,
    required this.title,
    required this.value,
    required this.min,
    required this.max,
    this.step = 1,
    this.unit = '',
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return IosListTile(
      title: title,
      showChevron: false,
      subtitle: unit.isEmpty ? null : unit,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            visualDensity: VisualDensity.compact,
            tooltip: '减少',
            icon: const Icon(Icons.remove_rounded),
            onPressed: value <= min
                ? null
                : () => onChanged((value - step).clamp(min, max)),
          ),
          Text(
            '$value',
            style: Theme.of(context)
                .textTheme
                .labelMediumEmphasized
                ?.copyWith(color: cs.primary),
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            tooltip: '增加',
            icon: const Icon(Icons.add_rounded),
            onPressed: value >= max
                ? null
                : () => onChanged((value + step).clamp(min, max)),
          ),
        ],
      ),
    );
  }
}
