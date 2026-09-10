import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:url_launcher/url_launcher.dart';

import 'ios_widgets.dart';

/// 规则语法帮助弹层（静态速查）
///
/// 三块内容：阅读 3.0 源规则说明 / @规则语法 / jsLib 与内置变量，
/// 内容全部为编译期常量，不发起网络请求、不引入新依赖。
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
  static const List<_HelpEntry> _sourceRules = [
    _HelpEntry(
      '搜索规则',
      'searchUrl：列表页请求地址，{{key}} 表示关键词、{{page}} 表示页码。',
    ),
    _HelpEntry(
      '发现规则',
      'exploreUrl：发现页的分类/榜单地址，可用规则生成分类与子列表。',
    ),
    _HelpEntry(
      '详情规则',
      'bookInfoRule：从详情页解析书名、作者、封面、简介与目录页链接。',
    ),
    _HelpEntry(
      '目录规则',
      'tocRule：从目录页解析章节名与章节链接列表（含分卷结构）。',
    ),
    _HelpEntry(
      '正文规则',
      'contentRule：从章节页解析正文内容，可用 ## 做正则替换清洗。',
    ),
  ];

  /// @ 前缀规则语法
  static const List<_HelpEntry> _prefixRules = [
    _HelpEntry(
      '@css:',
      '按 CSS 选择器从 HTML 中取文本或属性。',
      sample: r'@css:.book-list .title@text',
    ),
    _HelpEntry(
      '@json:',
      '按 JSONPath 从 JSON 响应中取值。',
      sample: r'@json:$.data.list[*].name',
    ),
    _HelpEntry(
      '@js:',
      '交给 JavaScript 处理上一步结果并返回最终值。',
      sample: r'@js:result.replace(/\s+/g, "")',
    ),
    _HelpEntry(
      '@XPath:',
      '按 XPath 从 HTML/XML 中取值。',
      sample: r'@XPath://div[@class="content"]/text()',
    ),
  ];

  /// jsLib 与常用内置变量/函数
  static const List<_HelpEntry> _jsLibEntries = [
    _HelpEntry(
      'java.ajax(url)',
      '发起 HTTP 请求并返回响应文本（自动携带 Cookie 与请求头）。',
    ),
    _HelpEntry(
      'java.base64Decode(str)',
      '对 Base64 字符串解码并返回原始文本。',
    ),
    _HelpEntry(
      'book',
      '当前书籍对象，含 bookUrl / name / author / tocUrl 等字段。',
    ),
    _HelpEntry(
      'baseUrl',
      '当前规则对应的页面地址。',
    ),
    _HelpEntry(
      'chapter',
      '当前章节对象，含 url / title 等字段。',
    ),
    _HelpEntry(
      'result',
      '上一步规则的输出结果（链式规则中继续处理时使用）。',
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
    messenger.showSnackBar(const SnackBar(content: Text('已复制链接：$wikiUrl')));
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
            Text('规则语法帮助', style: theme.textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(
              '书源规则速查：各规则含义、@ 前缀语法与 jsLib 常用函数。',
              style: theme.textTheme.bodySmall?.copyWith(
                color: cs.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 16),
            _SectionHeader('阅读 3.0 源规则说明'),
            const _CodeBlock(
              '搜索: searchUrl   发现: exploreUrl\n'
              '详情: bookInfoRule   目录: tocRule   正文: contentRule',
            ),
            const SizedBox(height: 4),
            for (final entry in _sourceRules) _EntryRow(entry: entry),
            const SizedBox(height: 4),
            _LinkRow(url: wikiUrl, onTap: () => _openWiki(context)),
            const Divider(height: 28),
            _SectionHeader('@规则语法'),
            Text(
              '规则前缀决定解析方式；不加前缀时默认按 HTML 规则解析。'
              '常用组合：|| 取首个非空、&& 合并、%% 交错、## 正则替换。',
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
            _SectionHeader('jsLib 与内置变量'),
            Text(
              'jsLib 中定义的函数可被 search / getChapters / getContent 复用'
              '（JS 书源即 mainJs 顶层函数）。常用内置对象与函数：',
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
            sample == null ? entry.desc : '${entry.desc} 例：$sample',
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
