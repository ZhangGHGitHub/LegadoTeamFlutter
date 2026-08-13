import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;

import '../../l10n/app_strings.dart';
import '../../providers/providers.dart';
import '../../providers/reader/reader_notifier.dart';
import '../../routes.dart';
import '../../screens/reader_config_panel.dart';
import 'reader_padding_config_sheet.dart';
import 'reader_tip_config_sheet.dart';
import '../ios_widgets.dart';

/// 阅读设置底部弹出面板（「界面」面板）
///
/// [UI-fix v2.0.4 | 2026-08-08] 重做对齐安卓原版 ReadStyleDialog
/// （dialog_read_book_style.xml）：
/// - 顶部按钮行 6 项：字重（中/粗/细循环）/ 字体 / 缩进 / 简繁 / 边距 / 信息
/// - 四滑条：字号 12-32 / 字距 -0.5~1.0 / 行距 1.0-3.0 连续 / 段距 0-2.0
/// - 翻页动画五选（顺序对齐原版：覆盖/滑动/仿真/滚动/无动画）
/// - 背景色预设圆圈 + 长按弹出自定义配色（文字色/背景色）
/// - 底部「共用布局」开关（shareLayout）
/// 视觉保持 iOS 底部 Sheet 形态（IosGrabber）— Qoder
class ReaderSettingsSheet extends ConsumerStatefulWidget {
  const ReaderSettingsSheet({super.key});

  /// 便捷弹出方法
  static void show(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
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
  /// 简繁转换类型（0=不转换 1=繁→简 2=简→繁，对标原版 ChineseConverter）
  int _convertType = 0;

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
    unawaited(_loadConvertType());
  }

  /// 共享配置尚未加载时兜底自加载（Sheet 可能先于面板/阅读页打开）
  Future<void> _ensureConfigLoaded() async {
    if (ref.read(readerAdvConfigProvider) != null) return;
    final cfg = await ReaderAdvancedConfig.load();
    if (!mounted) return;
    ref.read(readerAdvConfigProvider.notifier).apply(cfg);
  }

  Future<void> _loadConvertType() async {
    try {
      final type = await ref.read(bookApiProvider).getChineseConvertType();
      if (!mounted) return;
      setState(() => _convertType = type.clamp(0, 2));
    } catch (_) {
      // FFI 不可用时保持不转换
    }
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
        padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // iOS sheet 顶部短横条
            const Center(child: IosGrabber()),
            const SizedBox(height: 12),
            Text(AppStrings.readingSettingsTitle,
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 12),

            // ===== 顶部按钮行（对标原版 ReadStyleDialog 顶排 6 项） =====
            _buildTopButtons(context, adv, notifier),
            const Divider(height: 20),

            // ===== 四滑条：字号 / 字距 / 行距 / 段距 =====
            _sliderRow(
              label: AppStrings.fontSizeLabel,
              value: state.fontSize.clamp(12.0, 32.0),
              min: 12,
              max: 32,
              divisions: 20,
              display: state.fontSize.round().toString(),
              onChanged: (v) => notifier.updateFontSize(v),
            ),
            // 字距（em 语义，对标原版 dsbTextLetterSpacing (it-50)/100）
            _sliderRow(
              label: '字距',
              value: adv.letterSpacing.clamp(-0.5, 1.0),
              min: -0.5,
              max: 1.0,
              divisions: 75,
              display: adv.letterSpacing.toStringAsFixed(2),
              onChanged: (v) {
                final cfg = adv.copy()..letterSpacing = v;
                _commitAdv(cfg);
              },
            ),
            // 行距连续滑条（替代原 4 档 ChoiceChip，对标原版 dsbLineSize）
            _sliderRow(
              label: AppStrings.lineHeightLabel,
              value: state.lineHeight.clamp(1.0, 3.0),
              min: 1.0,
              max: 3.0,
              divisions: 40,
              display: state.lineHeight.toStringAsFixed(2),
              onChanged: (v) => notifier.updateLineHeight(v),
            ),
            // 段距（0-2.0 档，对标原版 dsbParagraphSpacing it/10；
            // 存储沿用 px 值 = 档位 × 10，与高级面板 0-48px 滑条共用键）
            _sliderRow(
              label: '段距',
              value: (adv.paragraphSpacing / 10).clamp(0.0, 2.0),
              min: 0,
              max: 2.0,
              divisions: 20,
              display: (adv.paragraphSpacing / 10).toStringAsFixed(1),
              onChanged: (v) {
                final cfg = adv.copy()..paragraphSpacing = v * 10;
                _commitAdv(cfg);
              },
            ),
            const Divider(height: 20),

            // ===== 翻页动画五选（顺序对齐原版 page_anim 数组） =====
            Text(AppStrings.flipModeLabel,
                style: Theme.of(context).textTheme.bodyMedium),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: [
                _flipChip(state, notifier, PageTurnMode.cover,
                    AppStrings.coverMode),
                _flipChip(state, notifier, PageTurnMode.slide,
                    AppStrings.slideMode),
                _flipChip(state, notifier, PageTurnMode.simulate,
                    AppStrings.simulateMode),
                _flipChip(state, notifier, PageTurnMode.scroll,
                    AppStrings.scrollMode),
                _flipChip(
                    state, notifier, PageTurnMode.none, AppStrings.noneMode),
              ],
            ),
            const SizedBox(height: 12),

            // ===== 背景色预设圆圈 + 长按自定义配色 =====
            Text(AppStrings.bgColor,
                style: Theme.of(context).textTheme.bodyMedium),
            const SizedBox(height: 8),
            Row(
              children: List.generate(ReaderBackground.presets.length, (i) {
                final color = ReaderBackground.presets[i];
                final label = ReaderBackground.labels[i];
                final isSelected = state.backgroundColor == color;
                return Padding(
                  padding: const EdgeInsets.only(right: 12),
                  child: GestureDetector(
                    onTap: () => notifier.updateBackgroundColor(color),
                    // 长按弹出自定义配色（对标原版长按背景圆圈进入
                    // BgTextConfigDialog 自定义文字/背景色）
                    onLongPress: () =>
                        _showCustomColorDialog(context, adv, notifier, state),
                    child: Column(
                      children: [
                        Container(
                          width: 44,
                          height: 44,
                          decoration: BoxDecoration(
                            color: color,
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: isSelected
                                  ? Theme.of(context).colorScheme.primary
                                  : Theme.of(context)
                                      .colorScheme
                                      .outlineVariant,
                              width: isSelected ? 3 : 1,
                            ),
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(label,
                            style: Theme.of(context).textTheme.labelSmall),
                      ],
                    ),
                  ),
                );
              }),
            ),
            const SizedBox(height: 4),
            Text('长按任一圆圈可自定义文字/背景颜色',
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    )),
            const Divider(height: 20),

            // ===== 共用布局（对标原版 ReadBookConfig.shareLayout：
            // 开启后日/夜共用边距/字距/缩进/字重/翻页模式；关闭则分桶） =====
            SwitchListTile(
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
          ],
        ),
      ),
    );
  }

  // ===== 顶部按钮行 =====

  Widget _buildTopButtons(BuildContext context, ReaderAdvancedConfig adv,
      ReaderNotifier notifier) {
    return Row(
      children: [
        // 字重：中/粗/细三态循环（对标原版 textBold TextFontWeightConverter）
        _topButton(
          value: const ['中', '粗', '细'][adv.textBold.clamp(0, 2)],
          caption: '字重',
          onTap: () {
            final cfg = adv.copy()..textBold = (adv.textBold + 1) % 3;
            _commitAdv(cfg);
          },
        ),
        // 字体：跳转现有字体选择页（对标原版 tvTextFont → FontSelectDialog）
        _topButton(
          value: '字体',
          caption: '选择',
          onTap: () async {
            await Navigator.pushNamed(context, AppRoutes.fonts);
            if (!mounted) return;
            // 推送新实例触发 reader_screen 重建（重读字体配置）
            _commitAdv(
                (ref.read(readerAdvConfigProvider) ?? ReaderAdvancedConfig())
                    .copy());
          },
        ),
        // 缩进：0-3 字符档位（对标原版 tvTextIndent）
        _topButton(
          value: const ['无', '一字', '二字', '三字'][adv.paragraphIndent.clamp(0, 3)],
          caption: '缩进',
          onTap: () => _showIndentDialog(adv),
        ),
        // 简繁转换（对标原版 chinese_converter，经 BookApi 读写）
        _topButton(
          value: const ['简繁', '繁→简', '简→繁'][_convertType.clamp(0, 2)],
          caption: '转换',
          onTap: _cycleConvertType,
        ),
        // 边距：打开页眉/正文/页脚边距面板（对标原版 tvPadding → PaddingConfigDialog）
        _topButton(
          value: '边距',
          caption: '设置',
          onTap: () => ReaderPaddingConfigSheet.show(
            context,
            config: adv.copy(),
            onChanged: _commitAdv,
          ),
        ),
        // 信息：打开阅读提示信息面板（对标原版 tvTip → TipConfigDialog）
        _topButton(
          value: '信息',
          caption: '设置',
          onTap: () => ReaderTipConfigSheet.show(
            context,
            config: adv.copy(),
            onChanged: _commitAdv,
          ),
        ),
      ],
    );
  }

  Widget _topButton({
    required String value,
    required String caption,
    required VoidCallback onTap,
  }) {
    return Expanded(
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Column(
            children: [
              Text(
                value,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: Theme.of(context).colorScheme.primary,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 2),
              Text(
                caption,
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 缩进档位选择对话框（0/1/2/3 字符；不用 RadioListTile，
  /// 避开 groupValue/onChanged 弃用 API）
  void _showIndentDialog(ReaderAdvancedConfig adv) {
    const options = {0: '无缩进', 1: '一字符', 2: '二字符', 3: '三字符'};
    showDialog<void>(
      context: context,
      builder: (dialogContext) => SimpleDialog(
        title: const Text('首行缩进'),
        children: [
          for (final entry in options.entries)
            ListTile(
              title: Text(entry.value),
              trailing: adv.paragraphIndent == entry.key
                  ? Icon(Icons.check,
                      color: Theme.of(dialogContext).colorScheme.primary)
                  : null,
              onTap: () {
                Navigator.pop(dialogContext);
                final cfg = adv.copy()..paragraphIndent = entry.key;
                _commitAdv(cfg);
              },
            ),
        ],
      ),
    );
  }

  /// 简繁转换三态循环：不转换 → 繁→简 → 简→繁（经 BookApi 读写）
  Future<void> _cycleConvertType() async {
    final next = (_convertType + 1) % 3;
    setState(() => _convertType = next);
    try {
      await ref.read(bookApiProvider).setChineseConvertType(next);
      // 转换类型变更后重新加载当前章正文
      if (mounted) {
        unawaited(
            ref.read(readerNotifierProvider.notifier).reloadChapterContent());
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('简繁转换设置失败: $e')),
        );
      }
    }
  }

  Widget _flipChip(ReaderState state, ReaderNotifier notifier,
      PageTurnMode mode, String label) {
    return ChoiceChip(
      label: Text(label),
      selected: state.pageTurnMode == mode,
      onSelected: (_) => notifier.updatePageTurnMode(mode),
    );
  }

  Widget _sliderRow({
    required String label,
    required double value,
    required double min,
    required double max,
    required int divisions,
    required String display,
    required ValueChanged<double> onChanged,
  }) {
    return Row(
      children: [
        SizedBox(
          width: 36,
          child: Text(label, style: Theme.of(context).textTheme.bodyMedium),
        ),
        Expanded(
          child: Slider(
            value: value,
            min: min,
            max: max,
            divisions: divisions,
            label: display,
            onChanged: onChanged,
          ),
        ),
        SizedBox(
          width: 44,
          child: Text(
            display,
            textAlign: TextAlign.end,
            style: Theme.of(context).textTheme.labelMedium,
          ),
        ),
      ],
    );
  }

  // ===== 自定义配色对话框（长按背景圆圈弹出，自绘色板不引入依赖） =====

  void _showCustomColorDialog(BuildContext context, ReaderAdvancedConfig adv,
      ReaderNotifier notifier, ReaderState state) {
    var textColorValue = adv.customTextColor;
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
                      final cfg = adv.copy()..customTextColor = 0;
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
                          final cfg = adv.copy()
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
