// 阅读器菜单系统设置面板（批3a）
//
// 对齐参考版 `ui/book/read/sheet/SystemMenuPage.kt` 三个子页：
// - 全局：工具栏样式（readBarStyle）、调色板、颜色来源、日/夜颜色、
//   亮度模式/位置、边框、模糊半径/透明度/底色（批3b）；
// - 底栏布局：图标文字、图标容器三态、每行图标数/行数、圆角、浮动底栏、
//   模糊/液态玻璃/按钮玻璃（批3b）；
// - 顶栏布局：标题胶囊、标题显示方式、紧凑标题、图标容器三态、模糊、
//   按钮玻璃、合并按钮（批3b）。
//
// 本面板只做配置展示与写入，具体渲染在 `reader_menu_panel.dart`；
// 持久化在 `providers/reader/reader_menu_style_notifier.dart`。
//
// 编写：全栈工程师（批3a） ｜ 2026-11-04
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;

import '../l10n/app_strings.dart';
import '../providers/reader/reader_menu_style_notifier.dart';
import 'reader_config_panel.dart'
    show ReaderAdvancedConfig, readerAdvConfigProvider;
import '../widgets/container_color_dialog.dart';
import '../widgets/reader/reader_menu_style.dart';

class ReaderMenuSystemPanel extends ConsumerStatefulWidget {
  const ReaderMenuSystemPanel({super.key});

  @override
  ConsumerState<ReaderMenuSystemPanel> createState() =>
      _ReaderMenuSystemPanelState();
}

class _ReaderMenuSystemPanelState extends ConsumerState<ReaderMenuSystemPanel> {
  /// 0 全局 / 1 底栏布局 / 2 顶栏布局
  int _tab = 0;

  List<String> get _tabLabels => [
        AppStrings.globalSection,
        AppStrings.bottomBarLayout,
        AppStrings.topBarLayout,
      ];

  Map<String, String> get _barStyleOptions => {
        '0': AppStrings.barFollowSystem,
        '1': AppStrings.barFollowReadingBg,
        '2': AppStrings.barCustom,
      };

  Map<String, String> get _iconStyleOptions => {
        '0': AppStrings.iconStylePlain,
        '1': AppStrings.iconStyleTint,
        '2': AppStrings.iconStyleOutline,
      };

  Map<String, String> get _titleModeOptions => {
        '0': AppStrings.titleModeTopBar,
        '1': AppStrings.titleModeNewLine,
        '2': AppStrings.titleModeChapterOnly,
        '3': AppStrings.titleModeHidden,
      };

  @override
  Widget build(BuildContext context) {
    final style = ref.watch(readerMenuStyleProvider);
    final notifier = ref.read(readerMenuStyleProvider.notifier);
    final adv = ref.watch(readerAdvConfigProvider) ?? ReaderAdvancedConfig();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildTabBar(context),
        const SizedBox(height: 12),
        switch (_tab) {
          0 => _buildGlobalTab(context, style, notifier, adv),
          1 => _buildBottomTab(context, style, notifier),
          _ => _buildTopTab(context, style, notifier),
        },
      ],
    );
  }

  /// 阅读高级配置（亮度模式/位置）统一持久化并推送共享 Provider
  void _commitAdv(ReaderAdvancedConfig cfg) {
    final isNight = Theme.of(context).brightness == Brightness.dark;
    unawaited(cfg.save(isNight: isNight));
    ref.read(readerAdvConfigProvider.notifier).apply(cfg);
  }

  // ===== 三段胶囊 Tab（高度/圆角沿用阅读界面弹层页签风格）=====

  Widget _buildTabBar(BuildContext context) {
    Widget tabItem(int index) {
      final selected = _tab == index;
      return Expanded(
        child: InkWell(
          key: ValueKey('reader-menu-tab-$index'),
          borderRadius: BorderRadius.circular(999),
          onTap: () => setState(() => _tab = index),
          child: Container(
            height: 42,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(999),
              color: selected
                  ? Theme.of(context).colorScheme.primary
                  : Colors.transparent,
            ),
            child: Text(
              _tabLabels[index],
              style: Theme.of(context).textTheme.labelLarge?.copyWith(
                color: selected
                    ? Theme.of(context).colorScheme.onPrimary
                    : Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ),
      );
    }

    return Row(
      children: [
        tabItem(0),
        const SizedBox(width: 6),
        tabItem(1),
        const SizedBox(width: 6),
        tabItem(2),
      ],
    );
  }

  // ===== 全局：工具栏样式 / 调色板 / 颜色来源 / 日夜色 =====

  Widget _buildGlobalTab(
    BuildContext context,
    ReaderMenuStyle style,
    ReaderMenuStyleNotifier notifier,
    ReaderAdvancedConfig adv,
  ) {
    // [批3b] 跟随阅读背景档已接种子映射，调色板重新可用；
    // 自定义档仅在种子色来源下显示调色板。
    final showPalette =
        style.readBarStyle == ReaderMenuBarStyle.followPage ||
        (style.readBarStyle == ReaderMenuBarStyle.custom &&
            style.colorMode == ReaderMenuColorMode.seed);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _settingCard(
          children: [
            _dropdownRow(
              key: const ValueKey('reader-menu-style-dropdown'),
              title: AppStrings.toolbarStyle,
              value: '${style.readBarStyle}',
              options: _barStyleOptions,
              onChanged: (v) => notifier.setReadBarStyle(int.parse(v)),
            ),
            if (showPalette)
              _dropdownRow(
                key: const ValueKey('reader-menu-palette-dropdown'),
                title: AppStrings.palette,
                value: style.paletteStyle,
                options: kReaderMenuPaletteLabels,
                onChanged: notifier.setPaletteStyle,
              ),
            if (style.readBarStyle == ReaderMenuBarStyle.custom) ...[
              _dropdownRow(
                key: const ValueKey('reader-menu-color-mode-dropdown'),
                title: AppStrings.colorSource,
                value: '${style.colorMode}',
                options: {
                  '0': AppStrings.seedColor,
                  '1': AppStrings.customThemeColor,
                },
                onChanged: (v) => notifier.setColorMode(int.parse(v)),
              ),
              if (style.colorMode == ReaderMenuColorMode.seed) ...[
                _colorRow(
                  key: const ValueKey('reader-menu-color-accent-day'),
                  title: AppStrings.seedColorDay,
                  value: style.accentColor,
                  isNight: false,
                  onPick: (v) => notifier.setAccentColor(v, isNight: false),
                ),
                _colorRow(
                  key: const ValueKey('reader-menu-color-accent-night'),
                  title: AppStrings.seedColorNight,
                  value: style.accentColorNight,
                  isNight: true,
                  onPick: (v) => notifier.setAccentColor(v, isNight: true),
                ),
              ] else ...[
                _colorRow(
                  key: const ValueKey('reader-menu-color-bg-day'),
                  title: AppStrings.backgroundColorDay,
                  value: style.bgColor,
                  isNight: false,
                  onPick: (v) => notifier.setBgColor(v, isNight: false),
                ),
                _colorRow(
                  key: const ValueKey('reader-menu-color-bg-night'),
                  title: AppStrings.backgroundColorNight,
                  value: style.bgColorNight,
                  isNight: true,
                  onPick: (v) => notifier.setBgColor(v, isNight: true),
                ),
                _colorRow(
                  key: const ValueKey('reader-menu-color-accent-day-custom'),
                  title: AppStrings.accentColorDay,
                  value: style.accentColor,
                  isNight: false,
                  onPick: (v) => notifier.setAccentColor(v, isNight: false),
                ),
                _colorRow(
                  key: const ValueKey('reader-menu-color-accent-night-custom'),
                  title: AppStrings.accentColorNight,
                  value: style.accentColorNight,
                  isNight: true,
                  onPick: (v) => notifier.setAccentColor(v, isNight: true),
                ),
                _colorRow(
                  key: const ValueKey('reader-menu-color-container-day'),
                  title: AppStrings.containerColorDay,
                  value: style.containerColor,
                  isNight: false,
                  onPick: (v) => notifier.setContainerColor(v, isNight: false),
                ),
                _colorRow(
                  key: const ValueKey('reader-menu-color-container-night'),
                  title: AppStrings.containerColorNight,
                  value: style.containerColorNight,
                  isNight: true,
                  onPick: (v) => notifier.setContainerColor(v, isNight: true),
                ),
                _colorRow(
                  key: const ValueKey('reader-menu-color-text-day'),
                  title: AppStrings.textColorDay,
                  value: style.textColor,
                  isNight: false,
                  onPick: (v) => notifier.setTextColor(v, isNight: false),
                ),
                _colorRow(
                  key: const ValueKey('reader-menu-color-text-night'),
                  title: AppStrings.textColorNight,
                  value: style.textColorNight,
                  isNight: true,
                  onPick: (v) => notifier.setTextColor(v, isNight: true),
                ),
              ],
            ],
            // [批3b] 亮度控件从「更多」页回迁（参考全局子页位置）
            _dropdownRow(
              key: const ValueKey('reader-menu-brightness-mode-dropdown'),
              title: AppStrings.brightnessControl,
              value: adv.readBrightnessMode,
              options: {
            '0': AppStrings.notShown,
            '1': AppStrings.horizontal,
            '2': AppStrings.vertical,
          },
              onChanged: (v) {
                final cfg = adv.copy()..readBrightnessMode = v;
                _commitAdv(cfg);
              },
            ),
            if (adv.readBrightnessMode == '2')
              _dropdownRow(
                key: const ValueKey('reader-menu-brightness-pos-dropdown'),
                title: AppStrings.brightnessBarPosition,
                value: adv.readBrightnessVwPos,
                options: {
                  '0': AppStrings.leftSide,
                  '1': AppStrings.rightSide,
                },
                onChanged: (v) {
                  final cfg = adv.copy()..readBrightnessVwPos = v;
                  _commitAdv(cfg);
                },
              ),
            SwitchListTile(
              key: const ValueKey('reader-menu-border-switch'),
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: Text(AppStrings.showBorder),
              subtitle: Text(AppStrings.showBorderDesc),
              value: style.borderWidth > 0,
              onChanged: (v) => notifier.setBorderWidth(v ? 1 : 0),
            ),
            if (style.borderWidth > 0) ...[
              _sliderRow(
                key: const ValueKey('reader-menu-border-width-slider'),
                title: AppStrings.borderWidth,
                value: style.borderWidth.clamp(1, 4).toDouble(),
                min: 1,
                max: 4,
                divisions: 3,
                label: '${style.borderWidth.clamp(1, 4)}',
                onChanged: (v) => notifier.setBorderWidth(v.round()),
              ),
              _colorRow(
                key: const ValueKey('reader-menu-border-color-day'),
                title: AppStrings.borderColorDay,
                value: style.borderColor,
                isNight: false,
                onPick: (v) => notifier.setBorderColor(v, isNight: false),
              ),
              _colorRow(
                key: const ValueKey('reader-menu-border-color-night'),
                title: AppStrings.borderColorNight,
                value: style.borderColorNight,
                isNight: true,
                onPick: (v) => notifier.setBorderColor(v, isNight: true),
              ),
            ],
            _sliderRow(
              key: const ValueKey('reader-menu-blur-radius-slider'),
              title: AppStrings.blurRadius,
              value: style.blurRadius.toDouble(),
              min: 0,
              max: 32,
              divisions: 32,
              label: '${style.blurRadius}',
              onChanged: (v) => notifier.setBlurRadius(v.round()),
            ),
            _sliderRow(
              key: const ValueKey('reader-menu-blur-alpha-slider'),
              title: AppStrings.blurOpacity,
              value: style.blurAlpha.toDouble(),
              min: 0,
              max: 100,
              divisions: 100,
              label: '${style.blurAlpha}',
              onChanged: (v) => notifier.setBlurAlpha(v.round()),
            ),
            _colorRow(
              key: const ValueKey('reader-menu-blur-color-day'),
              title: AppStrings.blurBaseDay,
              value: style.blurColor,
              isNight: false,
              onPick: (v) => notifier.setBlurColor(v, isNight: false),
            ),
            _colorRow(
              key: const ValueKey('reader-menu-blur-color-night'),
              title: AppStrings.blurBaseNight,
              value: style.blurColorNight,
              isNight: true,
              onPick: (v) => notifier.setBlurColor(v, isNight: true),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          AppStrings.dayNightColorHint,
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }

  // ===== 底栏布局 =====

  Widget _buildBottomTab(
    BuildContext context,
    ReaderMenuStyle style,
    ReaderMenuStyleNotifier notifier,
  ) {
    return _settingCard(
      children: [
        SwitchListTile(
          key: const ValueKey('reader-menu-icon-text-switch'),
          dense: true,
          contentPadding: EdgeInsets.zero,
          title: Text(AppStrings.showIconLabels),
          subtitle: Text(AppStrings.showIconLabelsDesc),
          value: style.showIconText,
          onChanged: notifier.setShowIconText,
        ),
        _dropdownRow(
          key: const ValueKey('reader-menu-icon-style-dropdown'),
          title: AppStrings.iconContainerStyle,
          value: '${style.iconStyle}',
          options: _iconStyleOptions,
          onChanged: (v) => notifier.setIconStyle(int.parse(v)),
        ),
        _sliderRow(
          key: const ValueKey('reader-menu-items-per-row-slider'),
          title: AppStrings.iconsPerRow,
          value: style.itemsPerRow.toDouble(),
          min: 2,
          max: 8,
          divisions: 6,
          label: '${style.itemsPerRow}',
          onChanged: (v) => notifier.setItemsPerRow(v.round()),
        ),
        _sliderRow(
          key: const ValueKey('reader-menu-row-count-slider'),
          title: AppStrings.iconRows,
          value: style.rowCount.toDouble(),
          min: 1,
          max: 2,
          divisions: 1,
          label: '${style.rowCount}',
          onChanged: (v) => notifier.setRowCount(v.round()),
        ),
        _sliderRow(
          key: const ValueKey('reader-menu-corner-slider'),
          title: AppStrings.bottomBarRadius,
          value: style.bottomCornerRadius.toDouble(),
          min: 0,
          max: 32,
          divisions: 32,
          label: '${style.bottomCornerRadius}',
          onChanged: (v) => notifier.setBottomCornerRadius(v.round()),
        ),
        SwitchListTile(
          key: const ValueKey('reader-menu-floating-switch'),
          dense: true,
          contentPadding: EdgeInsets.zero,
          title: Text(AppStrings.floatingBottomBar),
          subtitle: Text(AppStrings.floatingBottomBarDesc),
          value: style.floatingBottomBar,
          onChanged: notifier.setFloatingBottomBar,
        ),
        SwitchListTile(
          key: const ValueKey('reader-menu-bottom-blur-switch'),
          dense: true,
          contentPadding: EdgeInsets.zero,
          title: Text(AppStrings.bottomBarBlur),
          subtitle: Text(AppStrings.translucentBlurDesc),
          value: style.bottomBarBlurMode != ReaderMenuBlurMode.none,
          onChanged: (v) => notifier.setBottomBarBlurMode(
            v ? ReaderMenuBlurMode.haze : ReaderMenuBlurMode.none,
          ),
        ),
        if (!style.floatingBottomBar)
          _dropdownRow(
            key: const ValueKey('reader-menu-bottom-blur-style-dropdown'),
            title: AppStrings.blurStyle,
            value: '${style.bottomBarBlurStyle}',
            options: const {'0': 'Solid', '1': 'Progressive'},
            onChanged: (v) => notifier.setBottomBarBlurStyle(int.parse(v)),
          ),
        if (style.floatingBottomBar)
          SwitchListTile(
            key: const ValueKey('reader-menu-bottom-liquid-switch'),
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: Text(AppStrings.liquidGlassBottomBar),
            subtitle: Text(AppStrings.liquidGlassBottomBarDesc),
            value:
                style.bottomBarBlurMode == ReaderMenuBlurMode.liquidGlass,
            onChanged: (v) {
              notifier.setBottomBarBlurMode(
                v
                    ? ReaderMenuBlurMode.liquidGlass
                    : (style.bottomBarBlurMode != ReaderMenuBlurMode.none
                          ? ReaderMenuBlurMode.haze
                          : ReaderMenuBlurMode.none),
              );
            },
          ),
        SwitchListTile(
          key: const ValueKey('reader-menu-bottom-glass-buttons-switch'),
          dense: true,
          contentPadding: EdgeInsets.zero,
          title: Text(AppStrings.liquidGlassButtons),
          subtitle: Text(AppStrings.liquidGlassBottomBarButtonsDesc),
          value: style.bottomBarLiquidGlassButtons,
          onChanged: notifier.setBottomBarLiquidGlassButtons,
        ),
      ],
    );
  }

  // ===== 顶栏布局 =====

  Widget _buildTopTab(
    BuildContext context,
    ReaderMenuStyle style,
    ReaderMenuStyleNotifier notifier,
  ) {
    return _settingCard(
      children: [
        SwitchListTile(
          key: const ValueKey('reader-menu-title-capsule-switch'),
          dense: true,
          contentPadding: EdgeInsets.zero,
          title: Text(AppStrings.titleCapsuleLayout),
          subtitle: Text(AppStrings.titleCapsuleLayoutDesc),
          value: style.titleCapsule,
          onChanged: notifier.setTitleCapsule,
        ),
        // 参考版：胶囊开启时隐藏标题显示方式下拉
        if (!style.titleCapsule)
          _dropdownRow(
            key: const ValueKey('reader-menu-title-mode-dropdown'),
            title: AppStrings.titleDisplayMode,
            value: style.titleBarMode,
            options: _titleModeOptions,
            onChanged: notifier.setTitleBarMode,
          ),
        _dropdownRow(
          key: const ValueKey('reader-menu-title-icon-style-dropdown'),
          title: AppStrings.iconContainerStyle,
          value: '${style.titleIconStyle}',
          options: _iconStyleOptions,
          onChanged: (v) => notifier.setTitleIconStyle(int.parse(v)),
        ),
        SwitchListTile(
          key: const ValueKey('reader-menu-title-compact-switch'),
          dense: true,
          contentPadding: EdgeInsets.zero,
          title: Text(AppStrings.compactTitle),
          subtitle: Text(AppStrings.compactTitleDesc),
          value: style.titleBarCompact,
          onChanged: notifier.setTitleBarCompact,
        ),
        SwitchListTile(
          key: const ValueKey('reader-menu-top-blur-switch'),
          dense: true,
          contentPadding: EdgeInsets.zero,
          title: Text(AppStrings.topBarBlur),
          subtitle: Text(AppStrings.translucentBlurDesc),
          value: style.topBarBlurMode != ReaderMenuBlurMode.none,
          onChanged: (v) => notifier.setTopBarBlurMode(
            v ? ReaderMenuBlurMode.haze : ReaderMenuBlurMode.none,
          ),
        ),
        _dropdownRow(
          key: const ValueKey('reader-menu-top-blur-style-dropdown'),
          title: AppStrings.blurStyle,
          value: '${style.topBarBlurStyle}',
          options: const {'0': 'Solid', '1': 'Progressive'},
          onChanged: (v) => notifier.setTopBarBlurStyle(int.parse(v)),
        ),
        SwitchListTile(
          key: const ValueKey('reader-menu-top-glass-buttons-switch'),
          dense: true,
          contentPadding: EdgeInsets.zero,
          title: Text(AppStrings.liquidGlassButtons),
          subtitle: Text(AppStrings.liquidGlassTopBarButtonsDesc),
          value: style.topBarLiquidGlassButtons,
          onChanged: notifier.setTopBarLiquidGlassButtons,
        ),
        SwitchListTile(
          key: const ValueKey('reader-menu-merge-switch'),
          dense: true,
          contentPadding: EdgeInsets.zero,
          title: Text(AppStrings.mergeTopBarButtons),
          subtitle: Text(AppStrings.mergeTopBarButtonsDesc),
          value: style.mergeButtons,
          onChanged: notifier.setMergeButtons,
        ),
      ],
    );
  }

  // ===== 通用行构建 =====

  Widget _settingCard({required List<Widget> children}) {
    return Card(
      elevation: 0,
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var i = 0; i < children.length; i++) ...[
              if (i > 0) const Divider(height: 1),
              children[i],
            ],
          ],
        ),
      ),
    );
  }

  Widget _dropdownRow({
    required Key key,
    required String title,
    required String value,
    required Map<String, String> options,
    required ValueChanged<String> onChanged,
  }) {
    final effectiveValue = options.containsKey(value)
        ? value
        : options.keys.first;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Expanded(
            child: Text(title, style: Theme.of(context).textTheme.bodyLarge),
          ),
          const SizedBox(width: 12),
          DropdownButton<String>(
            key: key,
            value: effectiveValue,
            isDense: true,
            alignment: Alignment.centerRight,
            underline: const SizedBox.shrink(),
            items: [
              for (final entry in options.entries)
                DropdownMenuItem(value: entry.key, child: Text(entry.value)),
            ],
            onChanged: (v) {
              if (v != null) onChanged(v);
            },
          ),
        ],
      ),
    );
  }

  Widget _sliderRow({
    required Key key,
    required String title,
    required double value,
    required double min,
    required double max,
    required int divisions,
    required String label,
    required ValueChanged<double> onChanged,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: Theme.of(context).textTheme.bodyLarge,
                ),
              ),
              Text(
                label,
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
          Slider(
            key: key,
            value: value.clamp(min, max),
            min: min,
            max: max,
            divisions: divisions,
            label: label,
            onChanged: onChanged,
          ),
        ],
      ),
    );
  }

  Widget _colorRow({
    required Key key,
    required String title,
    required int value,
    required bool isNight,
    required ValueChanged<int> onPick,
  }) {
    final color = value == 0 ? null : Color(normalizeReaderMenuColor(value));
    return InkWell(
      key: key,
      onTap: () => _pickColor(
        title: title,
        initialColor: value,
        isNight: isNight,
        onPick: onPick,
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(
          children: [
            Container(
              width: 28,
              height: 28,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: color ?? Colors.transparent,
                border: Border.all(
                  color: Theme.of(context).colorScheme.outlineVariant,
                  width: value == 0 ? 1.5 : 1,
                ),
              ),
              child: value == 0
                  ? Text(
                      'A',
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    )
                  : null,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(title, style: Theme.of(context).textTheme.bodyLarge),
            ),
            Text(
              value == 0
                  ? AppStrings.defaultLabelShort
                  : '#${value.toRadixString(16).toUpperCase()}',
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(width: 4),
            const Icon(Icons.chevron_right, size: 20),
          ],
        ),
      ),
    );
  }

  Future<void> _pickColor({
    required String title,
    required int initialColor,
    required bool isNight,
    required ValueChanged<int> onPick,
  }) async {
    final selected = await showDialog<int>(
      context: context,
      builder: (_) => ContainerColorDialog(
        title: title,
        initialColor: initialColor,
        defaultHint: isNight
            ? AppStrings.restoreNightDefaults
            : AppStrings.restoreDayDefaults,
        presetColors: kContainerColorPresets,
      ),
    );
    if (selected == null || !mounted) return;
    onPick(selected);
  }
}
