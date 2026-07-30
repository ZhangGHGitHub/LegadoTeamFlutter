import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../providers/reader_provider.dart';

/// 点击区域可映射的功能
enum TapAction {
  none,
  prevPage,
  nextPage,
  toggleControls,
  openCatalog;

  String get label {
    switch (this) {
      case TapAction.none:
        return '无操作';
      case TapAction.prevPage:
        return '上一页/章';
      case TapAction.nextPage:
        return '下一页/章';
      case TapAction.toggleControls:
        return '切换工具栏';
      case TapAction.openCatalog:
        return '打开目录';
    }
  }
}

/// 阅读器高级配置（持久化到 SharedPreferences）
class ReaderAdvancedConfig {
  static const _prefix = 'reader_adv_';

  // 自动翻页
  bool autoPageTurn;
  double autoPageTurnInterval; // 秒
  bool autoPageTurnForward; // true=下一章 false=上一章

  // 点击区域映射
  TapAction leftAction;
  TapAction centerAction;
  TapAction rightAction;

  // 段落间距
  double paragraphSpacing;

  // 状态栏提示栏
  bool showBattery;
  bool showTime;
  bool showProgress;
  bool showChapterName;

  // 翻页模式
  PageTurnMode PageTurnMode;

  ReaderAdvancedConfig({
    this.autoPageTurn = false,
    this.autoPageTurnInterval = 10,
    this.autoPageTurnForward = true,
    this.leftAction = TapAction.prevPage,
    this.centerAction = TapAction.toggleControls,
    this.rightAction = TapAction.nextPage,
    this.paragraphSpacing = 12,
    this.showBattery = true,
    this.showTime = true,
    this.showProgress = true,
    this.showChapterName = true,
    this.PageTurnMode = PageTurnMode.slide,
  });

  /// 从持久化存储加载
  static Future<ReaderAdvancedConfig> load() async {
    final prefs = await SharedPreferences.getInstance();
    TapAction tap(String key, TapAction def) {
      final i = prefs.getInt('$_prefix$key');
      if (i == null || i < 0 || i >= TapAction.values.length) return def;
      return TapAction.values[i];
    }

    return ReaderAdvancedConfig(
      autoPageTurn: prefs.getBool('${_prefix}auto_page_turn') ?? false,
      autoPageTurnInterval: (prefs.getDouble('${_prefix}auto_interval') ?? 10)
          .clamp(3.0, 120.0),
      autoPageTurnForward: prefs.getBool('${_prefix}auto_forward') ?? true,
      leftAction: tap('left_action', TapAction.prevPage),
      centerAction: tap('center_action', TapAction.toggleControls),
      rightAction: tap('right_action', TapAction.nextPage),
      paragraphSpacing: (prefs.getDouble('${_prefix}paragraph_spacing') ?? 12)
          .clamp(0.0, 48.0),
      showBattery: prefs.getBool('${_prefix}show_battery') ?? true,
      showTime: prefs.getBool('${_prefix}show_time') ?? true,
      showProgress: prefs.getBool('${_prefix}show_progress') ?? true,
      showChapterName: prefs.getBool('${_prefix}show_chapter_name') ?? true,
      PageTurnMode: PageTurnMode.fromIndex(prefs.getInt('${_prefix}flip_mode') ?? PageTurnMode.slide.index),
    );
  }

  /// 持久化当前配置
  Future<void> save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('${_prefix}auto_page_turn', autoPageTurn);
    await prefs.setDouble('${_prefix}auto_interval', autoPageTurnInterval);
    await prefs.setBool('${_prefix}auto_forward', autoPageTurnForward);
    await prefs.setInt('${_prefix}left_action', leftAction.index);
    await prefs.setInt('${_prefix}center_action', centerAction.index);
    await prefs.setInt('${_prefix}right_action', rightAction.index);
    await prefs.setDouble('${_prefix}paragraph_spacing', paragraphSpacing);
    await prefs.setBool('${_prefix}show_battery', showBattery);
    await prefs.setBool('${_prefix}show_time', showTime);
    await prefs.setBool('${_prefix}show_progress', showProgress);
    await prefs.setBool('${_prefix}show_chapter_name', showChapterName);
    await prefs.setInt('${_prefix}flip_mode', PageTurnMode.index);
  }

  ReaderAdvancedConfig copy() => ReaderAdvancedConfig(
        autoPageTurn: autoPageTurn,
        autoPageTurnInterval: autoPageTurnInterval,
        autoPageTurnForward: autoPageTurnForward,
        leftAction: leftAction,
        centerAction: centerAction,
        rightAction: rightAction,
        paragraphSpacing: paragraphSpacing,
        showBattery: showBattery,
        showTime: showTime,
        showProgress: showProgress,
        showChapterName: showChapterName,
        PageTurnMode: PageTurnMode,
      );
}

/// 阅读器高级配置面板
///
/// 以底部弹出面板形式展示，支持：
/// - 自动翻页（开关 / 间隔 / 方向）
/// - 点击区域功能映射（左 / 中 / 右）
/// - 段落间距调节
/// - 状态栏提示栏项配置（电量 / 时间 / 进度 / 章节名）
/// - 翻页模式选择（仿真 / 滑动 / 覆盖 / 无动画）
class ReaderConfigPanel extends StatefulWidget {
  final ReaderAdvancedConfig config;

  /// 配置变更回调（每次修改后触发，便于阅读器实时应用）
  final ValueChanged<ReaderAdvancedConfig>? onChanged;

  const ReaderConfigPanel({
    super.key,
    required this.config,
    this.onChanged,
  });

  /// 便捷入口：弹出配置面板
  static Future<void> show(
    BuildContext context, {
    required ReaderAdvancedConfig config,
    ValueChanged<ReaderAdvancedConfig>? onChanged,
  }) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.75,
        minChildSize: 0.4,
        maxChildSize: 0.92,
        builder: (_, scrollController) => SingleChildScrollView(
          controller: scrollController,
          child: ReaderConfigPanel(config: config, onChanged: onChanged),
        ),
      ),
    );
  }

  @override
  State<ReaderConfigPanel> createState() => _ReaderConfigPanelState();
}

class _ReaderConfigPanelState extends State<ReaderConfigPanel> {
  late final ReaderAdvancedConfig _config = widget.config.copy();

  void _commit() {
    unawaited(_config.save());
    widget.onChanged?.call(_config.copy());
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.onSurfaceVariant.withValues(alpha: 0.4),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Text('高级阅读设置', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            _buildPageTurnMode(),
            const Divider(),
            _buildAutoPageTurn(),
            const Divider(),
            _buildTapZones(),
            const Divider(),
            _buildParagraphSpacing(),
            const Divider(),
            _buildStatusBar(),
          ],
        ),
      ),
    );
  }

  Widget _sectionTitle(String title, IconData icon) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Icon(icon, size: 18, color: Theme.of(context).colorScheme.primary),
          const SizedBox(width: 8),
          Text(title,
              style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }

  // ===== 翻页模式 =====

  Widget _buildPageTurnMode() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionTitle('翻页模式', Icons.auto_stories_outlined),
        SegmentedButton<PageTurnMode>(
          segments: [
            for (final mode in PageTurnMode.values)
              ButtonSegment(
                value: mode,
                label: Text(mode.displayName),
                icon: Text(mode.icon),
              ),
          ],
          selected: {_config.PageTurnMode},
          onSelectionChanged: (sel) {
            _config.PageTurnMode = sel.first;
            _commit();
          },
        ),
      ],
    );
  }

  // ===== 自动翻页 =====

  Widget _buildAutoPageTurn() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionTitle('自动翻页', Icons.timer_outlined),
        SwitchListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          title: const Text('启用自动翻页'),
          value: _config.autoPageTurn,
          onChanged: (v) {
            _config.autoPageTurn = v;
            _commit();
          },
        ),
        if (_config.autoPageTurn) ...[
          Row(
            children: [
              Text('间隔 ${_config.autoPageTurnInterval.toStringAsFixed(0)} 秒',
                  style: Theme.of(context).textTheme.bodyMedium),
              Expanded(
                child: Slider(
                  value: _config.autoPageTurnInterval,
                  min: 3,
                  max: 60,
                  divisions: 57,
                  onChanged: (v) {
                    _config.autoPageTurnInterval = v;
                    _commit();
                  },
                ),
              ),
            ],
          ),
          Row(
            children: [
              Text('翻页方向', style: Theme.of(context).textTheme.bodyMedium),
              const SizedBox(width: 12),
              Expanded(
                child: SegmentedButton<bool>(
                  segments: const [
                    ButtonSegment(value: true, label: Text('下一章')),
                    ButtonSegment(value: false, label: Text('上一章')),
                  ],
                  selected: {_config.autoPageTurnForward},
                  onSelectionChanged: (sel) {
                    _config.autoPageTurnForward = sel.first;
                    _commit();
                  },
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }

  // ===== 点击区域 =====

  Widget _buildTapZones() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionTitle('点击区域', Icons.touch_app_outlined),
        _tapZoneRow('左侧区域', _config.leftAction, (a) {
          _config.leftAction = a;
          _commit();
        }),
        _tapZoneRow('中间区域', _config.centerAction, (a) {
          _config.centerAction = a;
          _commit();
        }),
        _tapZoneRow('右侧区域', _config.rightAction, (a) {
          _config.rightAction = a;
          _commit();
        }),
      ],
    );
  }

  Widget _tapZoneRow(String label, TapAction current, ValueChanged<TapAction> onPick) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          SizedBox(width: 72, child: Text(label, style: Theme.of(context).textTheme.bodyMedium)),
          Expanded(
            child: DropdownButton<TapAction>(
              value: current,
              isExpanded: true,
              onChanged: (a) {
                if (a != null) onPick(a);
              },
              items: [
                for (final a in TapAction.values)
                  DropdownMenuItem(value: a, child: Text(a.label)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ===== 段落间距 =====

  Widget _buildParagraphSpacing() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionTitle('段落间距', Icons.format_line_spacing_outlined),
        Row(
          children: [
            Text('小', style: Theme.of(context).textTheme.bodySmall),
            Expanded(
              child: Slider(
                value: _config.paragraphSpacing,
                min: 0,
                max: 48,
                divisions: 16,
                label: _config.paragraphSpacing.toStringAsFixed(0),
                onChanged: (v) {
                  _config.paragraphSpacing = v;
                  _commit();
                },
              ),
            ),
            Text('大', style: Theme.of(context).textTheme.bodySmall),
            SizedBox(
              width: 48,
              child: Text(
                '${_config.paragraphSpacing.toStringAsFixed(0)}px',
                textAlign: TextAlign.end,
                style: Theme.of(context).textTheme.labelMedium,
              ),
            ),
          ],
        ),
      ],
    );
  }

  // ===== 状态栏提示栏 =====

  Widget _buildStatusBar() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionTitle('状态栏提示栏', Icons.info_outline),
        // 实时预览
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.6),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            children: [
              if (_config.showBattery) ...[
                const Icon(Icons.battery_std, size: 14),
                const SizedBox(width: 4),
              ],
              if (_config.showTime) ...[
                Text(_nowText(), style: Theme.of(context).textTheme.labelSmall),
                const SizedBox(width: 8),
              ],
              const Spacer(),
              if (_config.showChapterName)
                Flexible(
                  child: Text('第一章 · 起始',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.labelSmall),
                ),
              if (_config.showProgress) ...[
                const SizedBox(width: 8),
                Text('42.0%', style: Theme.of(context).textTheme.labelSmall),
              ],
            ],
          ),
        ),
        const SizedBox(height: 4),
        _statusToggle('显示电量', Icons.battery_std, _config.showBattery, (v) {
          _config.showBattery = v;
          _commit();
        }),
        _statusToggle('显示时间', Icons.access_time, _config.showTime, (v) {
          _config.showTime = v;
          _commit();
        }),
        _statusToggle('显示进度', Icons.pie_chart_outline, _config.showProgress, (v) {
          _config.showProgress = v;
          _commit();
        }),
        _statusToggle('显示章节名', Icons.bookmark_outline, _config.showChapterName, (v) {
          _config.showChapterName = v;
          _commit();
        }),
      ],
    );
  }

  Widget _statusToggle(String label, IconData icon, bool value, ValueChanged<bool> onChanged) {
    return CheckboxListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      secondary: Icon(icon, size: 20),
      title: Text(label),
      value: value,
      onChanged: (v) => onChanged(v ?? false),
    );
  }

  String _nowText() {
    final now = DateTime.now();
    final h = now.hour.toString().padLeft(2, '0');
    final m = now.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }
}
