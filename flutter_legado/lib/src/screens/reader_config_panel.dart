import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:shared_preferences/shared_preferences.dart';

import '../models/flip_mode.dart';
import '../providers/providers.dart';
import '../providers/reader/reader_notifier.dart';
import '../routes.dart';
import '../services/system_brightness.dart';
import '../widgets/reader/reader_padding_config_sheet.dart';
import '../widgets/reader/reader_tip_config_sheet.dart';
part 'reader_config_panel_data.part.dart';
part 'reader_config_panel_builders.part.dart';

// ↑ 分域 part 文件（体检 §三.16 超长文件拆分）：数据模型与构建方法分别拆出，
// 零行为变更（同 library 私有成员可访问）。

/// 边距区域（对标原版 PaddingConfigDialog.Region）
enum PaddingRegion { header, body, footer }

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

/// 面板可单独展示的区块（界面 Sheet 的「边距/信息」按钮对标原版
/// ReadStyleDialog 的 showPaddingConfig / TipConfigDialog 独立弹层）
enum ReaderConfigSection { all, margins, statusBar }

/// 阅读器高级配置面板
///
/// 以底部弹出面板形式展示，支持：
/// - 自动翻页（开关 / 间隔 / 方向）
/// - 点击区域功能映射（左 / 中 / 右）
/// - 段落间距调节
/// - 状态栏提示栏项配置（电量 / 时间 / 进度 / 章节名）
/// - 翻页模式选择（仿真 / 滑动 / 覆盖 / 无动画）
/// - [UI-fix v2.0.2 | 2026-08-06] 字体选择/字距调节/首行缩进/
///   简繁转换/MoreConfig（两端对齐） — Qoder
class ReaderConfigPanel extends ConsumerStatefulWidget {
  final ReaderAdvancedConfig config;

  /// 配置变更回调（每次修改后触发，便于阅读器实时应用）
  final ValueChanged<ReaderAdvancedConfig>? onChanged;

  // [UI-fix v2.0.4 | 2026-08-08] 区块过滤：界面 Sheet 的「边距/信息」
  // 按钮仅展示对应区块（对标原版独立弹层）— Qoder
  final ReaderConfigSection section;

  const ReaderConfigPanel({
    super.key,
    required this.config,
    this.onChanged,
    this.section = ReaderConfigSection.all,
  });

  /// 便捷入口：弹出配置面板
  static Future<void> show(
    BuildContext context, {
    required ReaderAdvancedConfig config,
    ValueChanged<ReaderAdvancedConfig>? onChanged,
    ReaderConfigSection section = ReaderConfigSection.all,
  }) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => DraggableScrollableSheet(
        expand: false,
        // 单区块展示时降低初始高度（内容更短）
        initialChildSize: section == ReaderConfigSection.all ? 0.75 : 0.5,
        minChildSize: 0.4,
        maxChildSize: 0.92,
        builder: (_, scrollController) => SingleChildScrollView(
          controller: scrollController,
          child: ReaderConfigPanel(
            config: config,
            onChanged: onChanged,
            section: section,
          ),
        ),
      ),
    );
  }

  @override
  ConsumerState<ReaderConfigPanel> createState() => _ReaderConfigPanelState();
}

class _ReaderConfigPanelState extends ConsumerState<ReaderConfigPanel> {
  late ReaderAdvancedConfig _config = widget.config.copy();

  /// 当前阅读字体显示名（与 FontScreen 持久化键 reader_font_family 同步）
  String _fontLabel = '默认字体';

  /// 简繁转换类型（0=不转换 1=繁转简 2=简转繁，对标原版 chineseConvertType）
  int _convertType = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_loadFontLabel());
    unawaited(_loadConvertType());
  }

  Future<void> _loadFontLabel() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final family = prefs.getString('reader_font_family');
      if (!mounted || family == null) return;
      setState(() => _fontLabel = family.replaceFirst('Custom_', ''));
    } catch (_) {
      // 读取失败保持默认字体标签
    }
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

  void _commit() {
    unawaited(_config.save());
    widget.onChanged?.call(_config.copy());
    // [UI-fix v2.0.4 | 2026-08-08] 同步推送共享 Provider（界面 Sheet /
    // reader_screen 经 watch 实时感知面板修改）— Qoder
    ref.read(readerAdvConfigProvider.notifier).apply(_config.copy());
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    // [UI-fix v2.0.4 | 2026-08-08] 区块过滤模式：仅渲染指定区块 — Qoder
    final List<Widget> children;
    switch (widget.section) {
      case ReaderConfigSection.margins:
        children = [
          ReaderPaddingConfigSheet(
            config: _config.copy(),
            onChanged: (cfg) {
              _config = cfg.copy();
              widget.onChanged?.call(_config.copy());
            },
          ),
        ];
        break;
      case ReaderConfigSection.statusBar:
        children = [
          ReaderTipConfigSheet(
            config: _config.copy(),
            onChanged: (cfg) {
              _config = cfg.copy();
              widget.onChanged?.call(_config.copy());
            },
          ),
        ];
        break;
      case ReaderConfigSection.all:
        children = [
          Text('高级阅读设置', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          _buildFlipMode(),
          const Divider(),
          _buildAutoPageTurn(),
          const Divider(),
          _buildTapZones(),
          const Divider(),
          _buildParagraphSpacing(),
          const Divider(),
          _buildTypography(),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.crop_free),
            title: const Text('页面边距'),
            subtitle: const Text('页眉 / 正文 / 页脚四向边距'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => ReaderPaddingConfigSheet.show(
              context,
              config: _config.copy(),
              onChanged: (cfg) {
                _config = cfg.copy();
                _commit();
              },
            ),
          ),
          ListTile(
            leading: const Icon(Icons.info_outline),
            title: const Text('阅读提示信息'),
            subtitle: const Text('页眉页脚提示项与标题样式'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => ReaderTipConfigSheet.show(
              context,
              config: _config.copy(),
              onChanged: (cfg) {
                _config = cfg.copy();
                _commit();
              },
            ),
          ),
          const Divider(),
          _buildMoreConfig(),
          const Divider(),
          _buildBrightnessControl(),
        ];
        break;
    }

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
            ...children,
          ],
        ),
      ),
    );
  }
}
