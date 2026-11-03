// 阅读器菜单系统设置面板（批3a）
//
// 对齐参考版 `ui/book/read/sheet/SystemMenuPage.kt` 三个子页：
// - 全局：工具栏样式（readBarStyle）、调色板、颜色来源、日/夜颜色；
// - 底栏布局：图标文字、图标容器三态、每行图标数/行数、圆角、浮动底栏；
// - 顶栏布局：标题胶囊、标题显示方式、图标容器三态、合并按钮。
//
// 本面板只做配置展示与写入，具体渲染在 `reader_menu_panel.dart`；
// 持久化在 `providers/reader/reader_menu_style_notifier.dart`。
//
// 编写：全栈工程师（批3a） ｜ 2026-11-04
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;

import '../providers/reader/reader_menu_style_notifier.dart';
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

  static const _tabLabels = ['全局', '底栏布局', '顶栏布局'];

  static const _barStyleOptions = {'0': '跟随系统', '1': '跟随阅读背景', '2': '自定义'};

  static const _iconStyleOptions = {'0': '无底衬', '1': '色调', '2': '描边'};

  static const _titleModeOptions = {
    '0': '顶栏显示',
    '1': '另起一行',
    '2': '仅章节',
    '3': '不显示',
  };

  @override
  Widget build(BuildContext context) {
    final style = ref.watch(readerMenuStyleProvider);
    final notifier = ref.read(readerMenuStyleProvider.notifier);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildTabBar(context),
        const SizedBox(height: 12),
        switch (_tab) {
          0 => _buildGlobalTab(context, style, notifier),
          1 => _buildBottomTab(context, style, notifier),
          _ => _buildTopTab(context, style, notifier),
        },
      ],
    );
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
  ) {
    // [批3a P2-8] 调色板仅在「自定义 + 种子色」生效；跟随阅读背景档
    // 的取种映射留 3b（参考 ReadBookColorTheme 从页面底色/图片取种）。
    final showPalette =
        style.readBarStyle == ReaderMenuBarStyle.custom &&
        style.colorMode == ReaderMenuColorMode.seed;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _settingCard(
          children: [
            _dropdownRow(
              key: const ValueKey('reader-menu-style-dropdown'),
              title: '工具栏样式',
              value: '${style.readBarStyle}',
              options: _barStyleOptions,
              onChanged: (v) => notifier.setReadBarStyle(int.parse(v)),
            ),
            if (showPalette)
              _dropdownRow(
                key: const ValueKey('reader-menu-palette-dropdown'),
                title: '调色板',
                value: style.paletteStyle,
                options: kReaderMenuPaletteLabels,
                onChanged: notifier.setPaletteStyle,
              ),
            if (style.readBarStyle == ReaderMenuBarStyle.custom) ...[
              _dropdownRow(
                key: const ValueKey('reader-menu-color-mode-dropdown'),
                title: '颜色来源',
                value: '${style.colorMode}',
                options: const {'0': '种子色', '1': '自定义主题色'},
                onChanged: (v) => notifier.setColorMode(int.parse(v)),
              ),
              if (style.colorMode == ReaderMenuColorMode.seed) ...[
                _colorRow(
                  key: const ValueKey('reader-menu-color-accent-day'),
                  title: '种子色（日）',
                  value: style.accentColor,
                  isNight: false,
                  onPick: (v) => notifier.setAccentColor(v, isNight: false),
                ),
                _colorRow(
                  key: const ValueKey('reader-menu-color-accent-night'),
                  title: '种子色（夜）',
                  value: style.accentColorNight,
                  isNight: true,
                  onPick: (v) => notifier.setAccentColor(v, isNight: true),
                ),
              ] else ...[
                _colorRow(
                  key: const ValueKey('reader-menu-color-bg-day'),
                  title: '背景颜色（日）',
                  value: style.bgColor,
                  isNight: false,
                  onPick: (v) => notifier.setBgColor(v, isNight: false),
                ),
                _colorRow(
                  key: const ValueKey('reader-menu-color-bg-night'),
                  title: '背景颜色（夜）',
                  value: style.bgColorNight,
                  isNight: true,
                  onPick: (v) => notifier.setBgColor(v, isNight: true),
                ),
                _colorRow(
                  key: const ValueKey('reader-menu-color-accent-day-custom'),
                  title: '强调色（日）',
                  value: style.accentColor,
                  isNight: false,
                  onPick: (v) => notifier.setAccentColor(v, isNight: false),
                ),
                _colorRow(
                  key: const ValueKey('reader-menu-color-accent-night-custom'),
                  title: '强调色（夜）',
                  value: style.accentColorNight,
                  isNight: true,
                  onPick: (v) => notifier.setAccentColor(v, isNight: true),
                ),
                _colorRow(
                  key: const ValueKey('reader-menu-color-container-day'),
                  title: '容器颜色（日）',
                  value: style.containerColor,
                  isNight: false,
                  onPick: (v) => notifier.setContainerColor(v, isNight: false),
                ),
                _colorRow(
                  key: const ValueKey('reader-menu-color-container-night'),
                  title: '容器颜色（夜）',
                  value: style.containerColorNight,
                  isNight: true,
                  onPick: (v) => notifier.setContainerColor(v, isNight: true),
                ),
                _colorRow(
                  key: const ValueKey('reader-menu-color-text-day'),
                  title: '文字颜色（日）',
                  value: style.textColor,
                  isNight: false,
                  onPick: (v) => notifier.setTextColor(v, isNight: false),
                ),
                _colorRow(
                  key: const ValueKey('reader-menu-color-text-night'),
                  title: '文字颜色（夜）',
                  value: style.textColorNight,
                  isNight: true,
                  onPick: (v) => notifier.setTextColor(v, isNight: true),
                ),
              ],
            ],
          ],
        ),
        const SizedBox(height: 8),
        Text(
          '日间/夜间颜色分别用于对应主题',
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
          title: const Text('显示图标文字'),
          subtitle: const Text('图标下方显示按钮名称'),
          value: style.showIconText,
          onChanged: notifier.setShowIconText,
        ),
        _dropdownRow(
          key: const ValueKey('reader-menu-icon-style-dropdown'),
          title: '图标容器样式',
          value: '${style.iconStyle}',
          options: _iconStyleOptions,
          onChanged: (v) => notifier.setIconStyle(int.parse(v)),
        ),
        _sliderRow(
          key: const ValueKey('reader-menu-items-per-row-slider'),
          title: '每行图标数',
          value: style.itemsPerRow.toDouble(),
          min: 2,
          max: 8,
          divisions: 6,
          label: '${style.itemsPerRow}',
          onChanged: (v) => notifier.setItemsPerRow(v.round()),
        ),
        _sliderRow(
          key: const ValueKey('reader-menu-row-count-slider'),
          title: '图标行数',
          value: style.rowCount.toDouble(),
          min: 1,
          max: 2,
          divisions: 1,
          label: '${style.rowCount}',
          onChanged: (v) => notifier.setRowCount(v.round()),
        ),
        _sliderRow(
          key: const ValueKey('reader-menu-corner-slider'),
          title: '底栏圆角',
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
          title: const Text('浮动底栏'),
          subtitle: const Text('四周留边；关闭后贴底全宽'),
          value: style.floatingBottomBar,
          onChanged: notifier.setFloatingBottomBar,
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
          title: const Text('标题胶囊布局'),
          subtitle: const Text('返回键右侧显示书名 + 章名胶囊'),
          value: style.titleCapsule,
          onChanged: notifier.setTitleCapsule,
        ),
        // 参考版：胶囊开启时隐藏标题显示方式下拉
        if (!style.titleCapsule)
          _dropdownRow(
            key: const ValueKey('reader-menu-title-mode-dropdown'),
            title: '标题显示方式',
            value: style.titleBarMode,
            options: _titleModeOptions,
            onChanged: notifier.setTitleBarMode,
          ),
        _dropdownRow(
          key: const ValueKey('reader-menu-title-icon-style-dropdown'),
          title: '图标容器样式',
          value: '${style.titleIconStyle}',
          options: _iconStyleOptions,
          onChanged: (v) => notifier.setTitleIconStyle(int.parse(v)),
        ),
        SwitchListTile(
          key: const ValueKey('reader-menu-merge-switch'),
          dense: true,
          contentPadding: EdgeInsets.zero,
          title: const Text('合并顶栏按钮'),
          subtitle: const Text('将顶栏操作按钮合并为一个胶囊'),
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
              value == 0 ? '默认' : '#${value.toRadixString(16).toUpperCase()}',
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
        defaultHint: isNight ? '恢复夜间默认' : '恢复日间默认',
        presetColors: kContainerColorPresets,
      ),
    );
    if (selected == null || !mounted) return;
    onPick(selected);
  }
}
