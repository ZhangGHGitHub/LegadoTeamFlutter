import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:url_launcher/url_launcher.dart';

import '../l10n/app_strings.dart';
import 'ios_widgets.dart';

/// 规则语法帮助弹层（静态速查）
///
/// 三块内容：阅读 3.0 源规则说明 / @规则语法 / jsLib 与内置变量，
/// 文案经 [AppStrings] 按 locale 取用（代码样例仍为常量），不发起网络
/// 请求、不引入新依赖。
/// 弹层壳沿用 `reader_tip_config_sheet.dart` 规范（IosGrabber +
/// DraggableScrollableSheet + 全量滚动）。
/// — full-stack-engineer + UI | 2026-09-09
class SourceRuleHelpSheet extends StatelessWidget {
  const SourceRuleHelpSheet({super.key});

  /// 源规则完整教程（占位 Wiki 地址，可点打开/复制）
  static const String wikiUrl = 'https://github.com/gedoor/legado/wiki';

  /// 展示弹层（对齐 ReaderTipConfigSheet.show 的壳）
  static Future<void> show(BuildContext context) {
    return showModalBottomSheet<void>(
      context: context,
      showDragHandle: false,
      isScrollControlled: true,
      builder: (_) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.72,
        minChildSize: 0.45,
        maxChildSize: 0.92,
        builder: (_, scrollController) => SingleChildScrollView(
          controller: scrollController,
          child: const SourceRuleHelpSheet(),
        ),
      ),
    );
  }

  /// 源规则基础写法（搜索/发现/详情/目录/正文）
  static List<_HelpEntry> get _sourceRules => [
        _HelpEntry(
          AppStrings.sourceSearchRules,
          AppStrings.sourceRuleSearchDesc,
        ),
        _HelpEntry(
          AppStrings.sourceExploreRules,
          AppStrings.sourceRuleExploreDesc,
        ),
        _HelpEntry(
          AppStrings.sourceInfoRules,
          AppStrings.sourceRuleInfoDesc,
        ),
        _HelpEntry(
          AppStrings.sourceTocRules,
          AppStrings.sourceRuleTocDesc,
        ),
        _HelpEntry(
          AppStrings.sourceContentRules,
          AppStrings.sourceRuleContentDesc,
        ),
      ];

  /// @ 前缀规则语法
  static List<_HelpEntry> get _prefixRules => [
        _HelpEntry(
          '@css:',
          AppStrings.sourceRuleCssDesc,
          sample: r'@css:.book-list .title@text',
        ),
        _HelpEntry(
          '@json:',
          AppStrings.sourceRuleJsonDesc,
          sample: r'@json:$.data.list[*].name',
        ),
        _HelpEntry(
          '@js:',
          AppStrings.sourceRuleJsDesc,
          sample: r'@js:result.replace(/\s+/g, "")',
        ),
        _HelpEntry(
          '@XPath:',
          AppStrings.sourceRuleXPathDesc,
          sample: r'@XPath://div[@class="content"]/text()',
        ),
      ];

  /// jsLib 与常用内置变量/函数
  static List<_HelpEntry> get _jsLibEntries => [
        _HelpEntry(
          'java.ajax(url)',
          AppStrings.sourceRuleAjaxDesc,
        ),
        _HelpEntry(
          'java.base64Decode(str)',
          AppStrings.sourceRuleBase64Desc,
        ),
        _HelpEntry(
          'book',
          AppStrings.sourceRuleBookDesc,
        ),
        _HelpEntry(
          'baseUrl',
          AppStrings.sourceRuleBaseUrlDesc,
        ),
        _HelpEntry(
          'chapter',
          AppStrings.sourceRuleChapterDesc,
        ),
        _HelpEntry(
          'result',
          AppStrings.sourceRuleResultDesc,
        ),
      ];

  Future<void> _openWiki(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    final uri = Uri.parse(wikiUrl);
    try {
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
        return;
      }
    } catch (_) {
      // 桌面端无可用浏览器时降级为复制链接
    }
    await Clipboard.setData(const ClipboardData(text: wikiUrl));
    messenger.showSnackBar(
      SnackBar(content: Text(AppStrings.copiedLink(wikiUrl))),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Center(child: IosGrabber()),
            const SizedBox(height: 12),
            Text(AppStrings.sourceRuleHelpTitle,
                style: theme.textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(
              AppStrings.sourceRuleHelpSubtitle,
              style: theme.textTheme.bodySmall?.copyWith(
                color: cs.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 16),
            _SectionHeader(AppStrings.sourceRuleSection30),
            _CodeBlock(AppStrings.sourceRuleCode30),
            const SizedBox(height: 4),
            for (final entry in _sourceRules) _EntryRow(entry: entry),
            const SizedBox(height: 4),
            _LinkRow(url: wikiUrl, onTap: () => _openWiki(context)),
            const Divider(height: 28),
            _SectionHeader(AppStrings.sourceRulePrefixSection),
            Text(
              AppStrings.sourceRulePrefixDesc,
              style: theme.textTheme.bodySmall?.copyWith(
                color: cs.onSurfaceVariant,
                height: 1.5,
              ),
            ),
            const SizedBox(height: 8),
            for (final entry in _prefixRules) _EntryRow(entry: entry),
            const _CodeBlock(
              '@css:.item .name@text\n'
              r'@json:$.data[*].title'
              '\n'
              '@XPath://h3/text()\n'
              r'@js:result.trim()',
            ),
            const Divider(height: 28),
            _SectionHeader(AppStrings.sourceRuleJsLibSection),
            Text(
              AppStrings.sourceRuleJsLibDesc,
              style: theme.textTheme.bodySmall?.copyWith(
                color: cs.onSurfaceVariant,
                height: 1.5,
              ),
            ),
            const SizedBox(height: 8),
            for (final entry in _jsLibEntries) _EntryRow(entry: entry),
            const _CodeBlock(
              'var html = java.ajax(baseUrl);\n'
              'var text = java.base64Decode(encoded);\n'
              'var name = book.name;',
            ),
          ],
        ),
      ),
    );
  }
}

/// 一句话条目（名称 + 释义 + 可选行内示例）
class _HelpEntry {
  const _HelpEntry(this.name, this.desc, {this.sample});

  final String name;
  final String desc;
  final String? sample;
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.title);

  final String title;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Text(
      title,
      style: theme.textTheme.titleSmall?.copyWith(
        color: theme.colorScheme.primary,
        fontWeight: FontWeight.w600,
      ),
    );
  }
}

class _EntryRow extends StatelessWidget {
  const _EntryRow({required this.entry});

  final _HelpEntry entry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final sample = entry.sample;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            entry.name,
            style: const TextStyle(
              fontFamily: 'monospace',
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            sample == null
                ? entry.desc
                : AppStrings.sourceRuleExample(entry.desc, sample),
            style: theme.textTheme.bodySmall?.copyWith(
              color: cs.onSurfaceVariant,
              height: 1.5,
            ),
          ),
        ],
      ),
    );
  }
}

class _CodeBlock extends StatelessWidget {
  const _CodeBlock(this.code);

  final String code;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        // 与 Markdown 帮助（help_markdown_styles）代码块同族的 token 化底色
        color: cs.surfaceContainerHighest.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        code,
        style: TextStyle(
          fontFamily: 'monospace',
          fontSize: 12.5,
          height: 1.45,
          color: cs.onSurface,
        ),
      ),
    );
  }
}

class _LinkRow extends StatelessWidget {
  const _LinkRow({required this.url, required this.onTap});

  final String url;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          children: [
            Icon(Symbols.open_in_new_rounded, size: 16, color: cs.primary),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                url,
                style: TextStyle(
                  color: cs.primary,
                  fontSize: 12.5,
                  decoration: TextDecoration.underline,
                  decorationColor: cs.primary,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
