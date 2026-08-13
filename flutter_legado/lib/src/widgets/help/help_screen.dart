import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:url_launcher/url_launcher.dart';

import '../legado_app_bar.dart';
import 'help_sections.dart';

/// 帮助文档全页（对标 Android TextDialog Mode.MD + showToc）
///
/// 从 assets 加载原版 Markdown，支持目录抽屉与 iOS 风格 Large Title 排版。
class HelpScreen extends StatefulWidget {
  const HelpScreen({
    super.key,
    required this.assetPath,
    this.title = '帮助',
  });

  /// 资产路径，如 `assets/web/help/md/appHelp.md`
  final String assetPath;
  final String title;

  @override
  State<HelpScreen> createState() => _HelpScreenState();
}

class _HelpScreenState extends State<HelpScreen> {
  final _scrollCtrl = ScrollController();
  final _scaffoldKey = GlobalKey<ScaffoldState>();

  String? _markdown;
  String? _error;
  List<HelpSection> _sections = const [];
  int _selectedSection = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _scrollCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final text = await rootBundle.loadString(widget.assetPath);
      if (!mounted) return;
      setState(() {
        _markdown = text;
        _sections = parseHelpSections(text);
        _selectedSection = 0;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '$e');
    }
  }

  String get _displayMarkdown {
    final full = _markdown ?? '';
    if (_selectedSection == 0 || _sections.isEmpty) return full;
    return _sections[_selectedSection - 1].markdown;
  }

  Future<void> _openLink(String href) async {
    final uri = Uri.tryParse(href);
    if (uri == null) return;
    if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('无法打开链接：$href')),
        );
      }
    }
  }

  void _selectSection(int index) {
    setState(() {
      _selectedSection = index;
    });
    if (_scrollCtrl.hasClients) {
      _scrollCtrl.jumpTo(0);
    }
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    return Scaffold(
      key: _scaffoldKey,
      backgroundColor: theme.scaffoldBackgroundColor,
      endDrawer: _sections.isEmpty ? null : _buildTocDrawer(theme, cs),
      appBar: LegadoAppBar(
        showBack: false,
        leading: IconButton(
          icon: const Icon(Icons.close),
          tooltip: '关闭',
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: Text(widget.title),
        actions: [
          if (_sections.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.list_alt_outlined),
              tooltip: '目录',
              onPressed: () => _scaffoldKey.currentState?.openEndDrawer(),
            ),
        ],
      ),
      body: _buildBody(theme, cs),
    );
  }

  Widget _buildBody(ThemeData theme, ColorScheme cs) {
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text('加载帮助失败：$_error', textAlign: TextAlign.center),
        ),
      );
    }
    if (_markdown == null) {
      return const Center(child: CircularProgressIndicator());
    }

    return Markdown(
      controller: _scrollCtrl,
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
      data: _displayMarkdown,
      onTapLink: (_, href, linkText) {
        if (href != null) _openLink(href);
      },
      styleSheet: MarkdownStyleSheet.fromTheme(theme).copyWith(
        h1: theme.textTheme.headlineMedium?.copyWith(
          fontWeight: FontWeight.w700,
          height: 1.2,
        ),
        h2: theme.textTheme.titleLarge?.copyWith(
          fontWeight: FontWeight.w600,
          height: 1.25,
        ),
        h3: theme.textTheme.titleMedium?.copyWith(
          fontWeight: FontWeight.w600,
        ),
        p: theme.textTheme.bodyLarge?.copyWith(height: 1.5),
        listBullet: theme.textTheme.bodyLarge,
        blockquote: theme.textTheme.bodyMedium?.copyWith(
          color: cs.onSurfaceVariant,
        ),
        blockquoteDecoration: BoxDecoration(
          color: cs.surfaceContainerHighest.withValues(alpha: 0.45),
          borderRadius: BorderRadius.circular(8),
        ),
        code: TextStyle(
          fontFamily: 'Menlo',
          fontFamilyFallback: const ['Consolas', 'monospace'],
          fontSize: 13,
          backgroundColor: cs.surfaceContainerHighest.withValues(alpha: 0.6),
        ),
        horizontalRuleDecoration: BoxDecoration(
          border: Border(
            top: BorderSide(color: cs.outlineVariant.withValues(alpha: 0.6)),
          ),
        ),
      ),
    );
  }

  Widget _buildTocDrawer(ThemeData theme, ColorScheme cs) {
    final labels = ['全部', ..._sections.map((s) => s.title)];
    return Drawer(
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
              child: Text(
                '目录',
                style: theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            Expanded(
              child: ListView.builder(
                itemCount: labels.length,
                itemBuilder: (context, index) {
                  final selected = _selectedSection == index;
                  return ListTile(
                    selected: selected,
                    selectedTileColor:
                        cs.primaryContainer.withValues(alpha: 0.35),
                    title: Text(
                      labels[index],
                      style: theme.textTheme.bodyLarge?.copyWith(
                        fontWeight:
                            selected ? FontWeight.w600 : FontWeight.normal,
                      ),
                    ),
                    onTap: () => _selectSection(index),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
