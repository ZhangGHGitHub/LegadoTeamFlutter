import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;

import '../../providers/reader/reader_notifier.dart';
import '../../routes.dart';
import '../../screens/reader_config_panel.dart';
import 'reader_tip_config_sheet.dart';

/// 阅读界面设置弹层（「界面」面板）
///
/// [UI_SYNC_REFACTOR S5 修 | 2026-09-06] 一比一对齐参考版「阅读界面」
/// 弹层布局（四页签结构）：
/// - 头部：圆形返回按钮 + 「阅读界面」标题
/// - 底部页签：全局 / 菜单 / 信息 / 更多
/// - 全局页（参考版实证布局）：字号步进器（- 24 +）+ 独立 Tt 字体小卡；
///   背景卡（长按自定义 + 月亮夜间切换 + 自定义/预设 chips）；翻页动画行
///   （当前值 + 独立图标小卡）
/// - 菜单页：自动翻页 / 点击区域 / 亮度控制
/// - 信息页：阅读提示信息（页眉页脚提示项与标题样式）
/// - 更多页：行距 / 字重 / 字体字距缩进段距 / 更多配置 / 页面边距 / 共用布局
class ReaderSettingsSheet extends ConsumerStatefulWidget {
  const ReaderSettingsSheet({super.key});

  /// 便捷弹出方法
  static void show(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      showDragHandle: false,
      builder: (_) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.72,
        minChildSize: 0.4,
        maxChildSize: 0.95,
        builder: (_, scrollController) => SingleChildScrollView(
          controller: scrollController,
          child: const ReaderSettingsSheet(),
        ),
      ),
    );
  }

  @override
  ConsumerState<ReaderSettingsSheet> createState() =>
      _ReaderSettingsSheetState();
}

class _ReaderSettingsSheetState extends ConsumerState<ReaderSettingsSheet> {
  /// 当前页签（0全局 1菜单 2信息 3更多，对齐参考版页签顺序）
  int _tab = 0;

  static const _tabLabels = ['全局', '菜单', '信息', '更多'];

  /// 翻页动画标签（顺序对齐原版 page_anim 数组）
  static const _flipLabels = {
    PageTurnMode.cover: '覆盖',
    PageTurnMode.slide: '滑动',
    PageTurnMode.simulate: '仿真',
    PageTurnMode.scroll: '滚动',
    PageTurnMode.none: '无动画',
  };

  /// 自定义配色对话框可选色板（自绘色块网格，不引入 pub 依赖）
  static const List<Color> _palette = [
    Color(0xFFFFFFFF),
    Color(0xFFF5F5DC),
    Color(0xFFE8E0C8),
    Color(0xFFCCEBCC),
    Color(0xFFD4A574),
    Color(0xFFC8E6C9),
    Color(0xFFB3E5FC),
    Color(0xFFFFF9C4),
    Color(0xFFFFCCBC),
    Color(0xFFE1BEE7),
    Color(0xFF90A4AE),
    Color(0xFF616161),
    Color(0xFF37474F),
    Color(0xFF263238),
    Color(0xFF1A1A1A),
    Color(0xFF000000),
  ];

  @override
  void initState() {
    super.initState();
    unawaited(_ensureConfigLoaded());
  }

  /// 共享配置尚未加载时兜底自加载（Sheet 可能先于面板/阅读页打开）
  Future<void> _ensureConfigLoaded() async {
    if (ref.read(readerAdvConfigProvider) != null) return;
    final cfg = await ReaderAdvancedConfig.load();
    if (!mounted) return;
    ref.read(readerAdvConfigProvider.notifier).apply(cfg);
  }

  /// 持久化并推送共享 Provider（reader_screen 经 watch 实时应用）
  void _commitAdv(ReaderAdvancedConfig cfg) {
    // F6：按当前主题写入日/夜或共用布局桶
    final isNight = Theme.of(context).brightness == Brightness.dark;
    unawaited(cfg.save(isNight: isNight));
    ref.read(readerAdvConfigProvider.notifier).apply(cfg);
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(readerNotifierProvider);
    final notifier = ref.read(readerNotifierProvider.notifier);
    final adv = ref.watch(readerAdvConfigProvider) ?? ReaderAdvancedConfig();

    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildHeader(context),
            const SizedBox(height: 16),
            _buildTabBar(context),
            const SizedBox(height: 16),
            switch (_tab) {
              0 => _buildGlobalTab(state, notifier, adv),
              1 => ReaderConfigPanel(
                  config: adv.copy(),
                  onChanged: _commitAdv,
                  section: ReaderConfigSection.menu,
                ),
              2 => ReaderTipConfigSheet(
                  config: adv.copy(),
                  onChanged: _commitAdv,
                ),
              _ => _buildMoreTab(state, notifier, adv),
            },
          ],
        ),
      ),
    );
  }

  // ===== 头部：圆形返回按钮 + 标题（对齐参考版） =====

  Widget _buildHeader(BuildContext context) {
    return Row(
      children: [
        InkWell(
          onTap: () => Navigator.of(context).pop(),
          customBorder: const CircleBorder(),
          child: Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
            ),
            child: Icon(
              Icons.arrow_back_rounded,
              size: 22,
              color: Theme.of(context).colorScheme.onSurface,
            ),
          ),
        ),
        const SizedBox(width: 14),
        Text(
          '阅读界面',
          style: Theme.of(context)
              .textTheme
              .titleLarge
              ?.copyWith(fontWeight: FontWeight.w600),
        ),
      ],
    );
  }

  // ===== 底部页签：全局 / 菜单 / 信息 / 更多 =====

  Widget _buildTabBar(BuildContext context) {
    return Row(
      children: [
        for (var i = 0; i < _tabLabels.length; i++) ...[
          if (i > 0) const SizedBox(width: 8),
          Expanded(
            child: InkWell(
              borderRadius: BorderRadius.circular(999),
              onTap: () => setState(() => _tab = i),
              child: Container(
                height: 42,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(999),
                  color: _tab == i
                      ? Theme.of(context).colorScheme.primary
                      : Colors.transparent,
                ),
                child: Text(
                  _tabLabels[i],
                  style: Theme.of(context).textTheme.labelLarge?.copyWith(
                        color: _tab == i
                            ? Theme.of(context).colorScheme.onPrimary
                            : Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }

  // ===== 配置卡片基座（圆角 20，与参考版卡片形态一致） =====

  Widget _panelCard({required Widget child, VoidCallback? onTap}) {
    return Card(
      elevation: 0,
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: Padding(padding: const EdgeInsets.all(16), child: child),
      ),
    );
  }

  // ===== 全局页：字号 / 背景 / 翻页动画 =====

  Widget _buildGlobalTab(
    ReaderState state,
    ReaderNotifier notifier,
    ReaderAdvancedConfig adv,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        IntrinsicHeight(
          child: Row(
            children: [
              Expanded(child: _buildFontSizeCard(state, notifier)),
              const SizedBox(width: 12),
              _buildFontEntryCard(context),
            ],
          ),
        ),
        const SizedBox(height: 12),
        _buildBackgroundCard(state, notifier, adv),
        const SizedBox(height: 12),
        IntrinsicHeight(
          child: Row(
            children: [
              Expanded(
                child: _panelCard(
                  onTap: () => _showFlipPicker(state, notifier),
                  child: Row(
                    children: [
                      Text('翻页动画',
                          style: Theme.of(context).textTheme.titleMedium),
                      const Spacer(),
                      Text(
                        _flipLabels[state.pageTurnMode] ?? '覆盖',
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurfaceVariant,
                            ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 12),
              _panelCard(
                onTap: () => _showFlipPicker(state, notifier),
                child: SizedBox(
                  width: 44,
                  child: Icon(
                    Icons.auto_stories_rounded,
                    size: 22,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// 字号卡片：标签 + 步进器（- 值 +，范围 12-32）
  Widget _buildFontSizeCard(ReaderState state, ReaderNotifier notifier) {
    return _panelCard(
      child: Row(
        children: [
          Text('字号', style: Theme.of(context).textTheme.titleMedium),
          const Spacer(),
          _stepButton(
            icon: Icons.remove_rounded,
            onTap: () => notifier
                .updateFontSize((state.fontSize - 1).clamp(12.0, 32.0)),
          ),
          const SizedBox(width: 10),
          Container(
            constraints: const BoxConstraints(minWidth: 52),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(10),
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
            ),
            child: Text(
              state.fontSize.round().toString(),
              style: Theme.of(context)
                  .textTheme
                  .titleSmall
                  ?.copyWith(fontWeight: FontWeight.w600),
            ),
          ),
          const SizedBox(width: 10),
          _stepButton(
            icon: Icons.add_rounded,
            onTap: () => notifier
                .updateFontSize((state.fontSize + 1).clamp(12.0, 32.0)),
          ),
        ],
      ),
    );
  }

  /// 步进按钮（描边圆形，对齐参考版 -/+ 形态）
  Widget _stepButton({required IconData icon, required VoidCallback onTap}) {
    return InkWell(
      onTap: onTap,
      customBorder: const CircleBorder(),
      child: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(
            color: Theme.of(context).colorScheme.outlineVariant,
          ),
        ),
        child: Icon(
          icon,
          size: 20,
          color: Theme.of(context).colorScheme.onSurface,
        ),
      ),
    );
  }

  /// Tt 字体入口小卡（跳转字体管理页）
  Widget _buildFontEntryCard(BuildContext context) {
    return _panelCard(
      onTap: () async {
        await Navigator.pushNamed(context, AppRoutes.fonts);
        if (!mounted) return;
        // 返回后推送共享配置触发阅读器重建（重读字体配置）
        _commitAdv(
          (ref.read(readerAdvConfigProvider) ?? ReaderAdvancedConfig())
              .copy(),
        );
      },
      child: SizedBox(
        width: 56,
        child: Center(
          child: Text(
            'Tt',
            style: Theme.of(context)
                .textTheme
                .titleMedium
                ?.copyWith(fontWeight: FontWeight.w700),
          ),
        ),
      ),
    );
  }

  /// 背景卡片：标题 + 长按自定义提示 + 月亮夜间切换 + 预设 chips
  Widget _buildBackgroundCard(
    ReaderState state,
    ReaderNotifier notifier,
    ReaderAdvancedConfig adv,
  ) {
    return _panelCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('背景', style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 2),
                  Text(
                    '长按自定义',
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color:
                              Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                  ),
                ],
              ),
              const Spacer(),
              // 月亮按钮：夜间/日间背景一键切换（对齐参考版）
              InkWell(
                onTap: () => notifier.updateBackgroundColor(
                  state.backgroundColor == ReaderBackground.dark
                      ? ReaderBackground.white
                      : ReaderBackground.dark,
                ),
                customBorder: const CircleBorder(),
                child: Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color:
                        Theme.of(context).colorScheme.surfaceContainerHighest,
                  ),
                  child: Icon(
                    Icons.dark_mode_rounded,
                    size: 20,
                    color: Theme.of(context).colorScheme.onSurface,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                // 自定义 chip：网格图标，点按弹自定义配色
                GestureDetector(
                  onTap: () =>
                      _showCustomColorDialog(context, adv, notifier, state),
                  child: Container(
                    width: 64,
                    height: 56,
                    margin: const EdgeInsets.only(right: 10),
                    alignment: Alignment.center,
                    decoration: _bgChipDecoration(selected: false),
                    child: Icon(
                      Icons.grid_view_rounded,
                      size: 22,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
                for (var i = 0; i < ReaderBackground.presets.length; i++)
                  _bgPresetChip(state, notifier, i),
              ],
            ),
          ),
        ],
      ),
    );
  }

  BoxDecoration _bgChipDecoration({required bool selected}) {
    return BoxDecoration(
      borderRadius: BorderRadius.circular(14),
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      border: Border.all(
        color: selected
            ? Theme.of(context).colorScheme.primary
            : Colors.transparent,
        width: 2,
      ),
    );
  }

  /// 预设背景 chip（选中加主色描边 + 底部对勾，对齐参考版）
  Widget _bgPresetChip(ReaderState state, ReaderNotifier notifier, int index) {
    final color = ReaderBackground.presets[index];
    final label = ReaderBackground.labels[index];
    final isSelected = state.backgroundColor == color;
    return GestureDetector(
      onLongPress: () =>
          _showCustomColorDialog(context, null, notifier, state),
      onTap: () => notifier.updateBackgroundColor(color),
      child: Container(
        width: 64,
        height: 56,
        margin: const EdgeInsets.only(right: 10),
        padding: const EdgeInsets.symmetric(vertical: 6),
        alignment: Alignment.center,
        decoration: _bgChipDecoration(selected: isSelected),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              label,
              style: Theme.of(context).textTheme.labelMedium,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 2),
            SizedBox(
              height: 14,
              child: isSelected
                  ? Icon(
                      Icons.check_rounded,
                      size: 14,
                      color: Theme.of(context).colorScheme.primary,
                    )
                  : null,
            ),
          ],
        ),
      ),
    );
  }

  /// 翻页动画五选弹窗（顺序对齐原版 page_anim 数组）
  void _showFlipPicker(ReaderState state, ReaderNotifier notifier) {
    showDialog<void>(
      context: context,
      builder: (dialogContext) => SimpleDialog(
        title: const Text('翻页动画'),
        children: [
          for (final mode in PageTurnMode.values)
            ListTile(
              title: Text(_flipLabels[mode] ?? mode.name),
              trailing: state.pageTurnMode == mode
                  ? Icon(Icons.check,
                      color: Theme.of(dialogContext).colorScheme.primary)
                  : null,
              onTap: () {
                Navigator.pop(dialogContext);
                notifier.updatePageTurnMode(mode);
              },
            ),
        ],
      ),
    );
  }

  // ===== 更多页：行距 / 字重 / 排版与更多配置 / 共用布局 =====

  Widget _buildMoreTab(
    ReaderState state,
    ReaderNotifier notifier,
    ReaderAdvancedConfig adv,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _panelCard(
          child: Row(
            children: [
              Text('行距', style: Theme.of(context).textTheme.titleMedium),
              Expanded(
                child: Slider(
                  value: state.lineHeight.clamp(1.0, 3.0),
                  min: 1.0,
                  max: 3.0,
                  divisions: 40,
                  label: state.lineHeight.toStringAsFixed(2),
                  onChanged: (v) => notifier.updateLineHeight(v),
                ),
              ),
              SizedBox(
                width: 44,
                child: Text(
                  state.lineHeight.toStringAsFixed(2),
                  textAlign: TextAlign.end,
                  style: Theme.of(context).textTheme.labelMedium,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        _panelCard(
          child: Row(
            children: [
              Text('字重', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(width: 16),
              Expanded(
                child: SegmentedButton<int>(
                  segments: const [
                    ButtonSegment(value: 0, label: Text('中')),
                    ButtonSegment(value: 1, label: Text('粗')),
                    ButtonSegment(value: 2, label: Text('细')),
                  ],
                  selected: {adv.textBold.clamp(0, 2)},
                  onSelectionChanged: (sel) {
                    final cfg = adv.copy()..textBold = sel.first;
                    _commitAdv(cfg);
                  },
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        ReaderConfigPanel(
          config: adv.copy(),
          onChanged: _commitAdv,
          section: ReaderConfigSection.more,
        ),
        const SizedBox(height: 12),
        // 共用布局（对标原版 ReadBookConfig.shareLayout：
        // 开启后日/夜共用边距/字距/缩进/字重/翻页模式；关闭则分桶）
        _panelCard(
          child: SwitchListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: const Text('共用布局'),
            subtitle: Text(
              adv.shareLayout
                  ? '日夜共用边距与排版参数'
                  : '日夜分别保存布局（切换主题自动切换）',
            ),
            value: adv.shareLayout,
            onChanged: (v) {
              final cfg = adv.copy()..shareLayout = v;
              _commitAdv(cfg);
            },
          ),
        ),
      ],
    );
  }

  // ===== 自定义配色对话框（长按背景 chip 弹出，自绘色板不引入依赖） =====

  void _showCustomColorDialog(BuildContext context, ReaderAdvancedConfig? adv,
      ReaderNotifier notifier, ReaderState state) {
    final effectiveAdv =
        adv ?? ref.read(readerAdvConfigProvider) ?? ReaderAdvancedConfig();
    var textColorValue = effectiveAdv.customTextColor;
    var bgColorValue = state.backgroundColor.toARGB32();
    showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          title: const Text('自定义配色'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('文字颜色',
                    style: Theme.of(dialogContext).textTheme.bodyMedium),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    // 「自动」= 跟随背景明暗自适应（customTextColor 置 0）
                    _autoTextChip(dialogContext, textColorValue == 0, () {
                      setDialogState(() => textColorValue = 0);
                      final cfg = effectiveAdv.copy()..customTextColor = 0;
                      _commitAdv(cfg);
                    }),
                    for (final c in _palette)
                      _colorBlock(
                        dialogContext,
                        c,
                        textColorValue == c.toARGB32(),
                        () {
                          setDialogState(
                              () => textColorValue = c.toARGB32());
                          final cfg = effectiveAdv.copy()
                            ..customTextColor = c.toARGB32();
                          _commitAdv(cfg);
                        },
                      ),
                  ],
                ),
                const SizedBox(height: 16),
                Text('背景颜色',
                    style: Theme.of(dialogContext).textTheme.bodyMedium),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final c in _palette)
                      _colorBlock(
                        dialogContext,
                        c,
                        bgColorValue == c.toARGB32(),
                        () {
                          setDialogState(() => bgColorValue = c.toARGB32());
                          // 自定义背景经 notifier 持久化并即时应用
                          unawaited(notifier.updateCustomBackgroundColor(c));
                        },
                      ),
                  ],
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('完成'),
            ),
          ],
        ),
      ),
    );
  }

  /// 「自动」文字色选项块
  Widget _autoTextChip(
      BuildContext context, bool selected, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Container(
        width: 52,
        height: 32,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
            color: selected
                ? Theme.of(context).colorScheme.primary
                : Theme.of(context).colorScheme.outlineVariant,
            width: selected ? 2 : 1,
          ),
        ),
        child: Text('自动', style: Theme.of(context).textTheme.labelMedium),
      ),
    );
  }

  /// 色板色块
  Widget _colorBlock(
      BuildContext context, Color color, bool selected, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Container(
        width: 32,
        height: 32,
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
            color: selected
                ? Theme.of(context).colorScheme.primary
                : Theme.of(context).colorScheme.outlineVariant,
            width: selected ? 2.5 : 1,
          ),
        ),
        child: selected
            ? Icon(Icons.check,
                size: 16,
                color: color.computeLuminance() > 0.5
                    ? Colors.black54
                    : Colors.white70)
            : null,
      ),
    );
  }
}
