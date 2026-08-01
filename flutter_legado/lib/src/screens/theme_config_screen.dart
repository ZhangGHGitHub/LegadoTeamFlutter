import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;

import '../providers/theme/theme_notifier.dart';
import '../services/settings_service.dart';

/// 主题配置页面
///
/// 管理应用主题模式、全局字体缩放（对齐原版 fontScale）以及阅读器字体大小、行距、背景色等外观设置。
/// 主题模式与全局字体缩放经 [ThemeNotifier] 全局实时生效。
class ThemeConfigScreen extends ConsumerStatefulWidget {
  const ThemeConfigScreen({super.key});

  @override
  ConsumerState<ThemeConfigScreen> createState() => _ThemeConfigScreenState();
}

class _ThemeConfigScreenState extends ConsumerState<ThemeConfigScreen> {
  final _settingsService = SettingsService();

  double _fontSize = 18.0;
  double _lineHeight = 1.6;
  int _bgColorIndex = 0;
  bool _loading = true;

  /// 可选背景色列表
  static const _bgColors = [
    Color(0xFFFFFFFF), // 白色
    Color(0xFFF5F5DC), // 米黄
    Color(0xFFF0E6D3), // 暖黄
    Color(0xFFE8F5E9), // 浅绿
    Color(0xFF1A1A2E), // 深色
  ];

  static const _bgColorNames = ['白色', '米黄', '暖黄', '浅绿', '深色'];

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    final fontSize = await _settingsService.getFontSize();
    final lineHeight = await _settingsService.getLineHeight();
    final bgColorIndex = await _settingsService.getBgColorIndex();

    setState(() {
      _fontSize = fontSize;
      _lineHeight = lineHeight;
      _bgColorIndex = bgColorIndex;
      _loading = false;
    });
  }

  Future<void> _setFontSize(double size) async {
    setState(() => _fontSize = size);
    await _settingsService.setFontSize(size);
  }

  Future<void> _setLineHeight(double height) async {
    setState(() => _lineHeight = height);
    await _settingsService.setLineHeight(height);
  }

  Future<void> _setBgColor(int index) async {
    setState(() => _bgColorIndex = index);
    await _settingsService.setBgColorIndex(index);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final themeState = ref.watch(themeNotifierProvider);
    final themeNotifier = ref.read(themeNotifierProvider.notifier);

    return Scaffold(
      appBar: AppBar(title: const Text('主题配置')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                // === 主题模式 ===
                _sectionHeader(theme, '主题模式'),
                const SizedBox(height: 8),
                SegmentedButton<ThemeMode>(
                  segments: const [
                    ButtonSegment(
                      value: ThemeMode.system,
                      label: Text('跟随系统'),
                      icon: Icon(Icons.brightness_auto),
                    ),
                    ButtonSegment(
                      value: ThemeMode.light,
                      label: Text('浅色'),
                      icon: Icon(Icons.light_mode),
                    ),
                    ButtonSegment(
                      value: ThemeMode.dark,
                      label: Text('深色'),
                      icon: Icon(Icons.dark_mode),
                    ),
                  ],
                  selected: {themeState.themeMode},
                  onSelectionChanged: (selected) =>
                      themeNotifier.setThemeMode(selected.first),
                ),

                const SizedBox(height: 32),

                // === 全局字体缩放（对齐原版 fontScale）===
                _sectionHeader(theme, '全局字体大小'),
                const SizedBox(height: 8),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.format_size),
                  title: const Text('字体缩放'),
                  subtitle: Text(themeState.fontScaleLabel),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () =>
                      _showFontScalePicker(context, themeState, themeNotifier),
                ),

                const SizedBox(height: 32),

                // === 阅读器字体大小 ===
                _sectionHeader(theme, '阅读器字体大小'),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Text('${_fontSize.toInt()}',
                        style: theme.textTheme.bodyLarge),
                    Expanded(
                      child: Slider(
                        value: _fontSize,
                        min: 12,
                        max: 32,
                        divisions: 20,
                        label: '${_fontSize.toInt()} px',
                        onChanged: _setFontSize,
                      ),
                    ),
                    Text('${_fontSize.toInt()} px',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        )),
                  ],
                ),
                // 预览文本
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: _bgColors[_bgColorIndex.clamp(0, _bgColors.length - 1)],
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: theme.colorScheme.outlineVariant),
                  ),
                  child: Text(
                    '这是阅读预览文本。The quick brown fox jumps over the lazy dog.',
                    style: TextStyle(
                      fontSize: _fontSize,
                      height: _lineHeight,
                      color: _bgColorIndex == 4
                          ? Colors.white
                          : Colors.black87,
                    ),
                  ),
                ),

                const SizedBox(height: 32),

                // === 行距 ===
                _sectionHeader(theme, '行距'),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Text(_lineHeight.toStringAsFixed(1),
                        style: theme.textTheme.bodyLarge),
                    Expanded(
                      child: Slider(
                        value: _lineHeight,
                        min: 1.0,
                        max: 3.0,
                        divisions: 20,
                        label: _lineHeight.toStringAsFixed(1),
                        onChanged: _setLineHeight,
                      ),
                    ),
                    Text('×',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        )),
                  ],
                ),

                const SizedBox(height: 32),

                // === 背景色 ===
                _sectionHeader(theme, '阅读背景'),
                const SizedBox(height: 12),
                Row(
                  children: List.generate(_bgColors.length, (index) {
                    final isSelected = _bgColorIndex == index;
                    return Padding(
                      padding: const EdgeInsets.only(right: 12),
                      child: GestureDetector(
                        onTap: () => _setBgColor(index),
                        child: Column(
                          children: [
                            Container(
                              width: 48,
                              height: 48,
                              decoration: BoxDecoration(
                                color: _bgColors[index],
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: isSelected
                                      ? theme.colorScheme.primary
                                      : theme.colorScheme.outlineVariant,
                                  width: isSelected ? 3 : 1,
                                ),
                              ),
                              child: isSelected
                                  ? Icon(
                                      Icons.check,
                                      color: index == 4
                                          ? Colors.white
                                          : theme.colorScheme.primary,
                                      size: 20,
                                    )
                                  : null,
                            ),
                            const SizedBox(height: 4),
                            Text(
                              _bgColorNames[index],
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: isSelected
                                    ? theme.colorScheme.primary
                                    : theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  }),
                ),

                const SizedBox(height: 32),
              ],
            ),
    );
  }

  Widget _sectionHeader(ThemeData theme, String title) {
    return Text(
      title,
      style: theme.textTheme.titleMedium?.copyWith(
        fontWeight: FontWeight.bold,
      ),
    );
  }

  /// 全局字体缩放选择（对齐原版 ThemeConfigFragment fontScale NumberPickerDialog）
  ///
  /// 原版取值 8~16（0.8x~1.6x），「默认」按钮重置为 0（跟随系统）。
  void _showFontScalePicker(
    BuildContext context,
    ThemeState themeState,
    ThemeNotifier notifier,
  ) {
    // 跟随系统时默认展示 1.0x
    var current = themeState.fontScaleRaw.toDouble();
    if (current < 8 || current > 16) current = 10;
    showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('字体缩放'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '当前字体大小：${(current / 10).toStringAsFixed(1)}',
                style: Theme.of(ctx).textTheme.bodyMedium,
              ),
              const SizedBox(height: 8),
              Slider(
                value: current,
                min: 8,
                max: 16,
                divisions: 8,
                label: (current / 10).toStringAsFixed(1),
                onChanged: (v) => setDialogState(() => current = v),
              ),
            ],
          ),
          actions: [
            // 对齐原版「默认」按钮：重置为跟随系统
            TextButton(
              onPressed: () {
                notifier.setFontScale(0);
                Navigator.pop(ctx);
              },
              child: const Text('跟随系统'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () {
                notifier.setFontScale(current.round());
                Navigator.pop(ctx);
              },
              child: const Text('确定'),
            ),
          ],
        ),
      ),
    );
  }
}
