import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

/// 词典条目
class _DictEntry {
  final String word;
  final String phonetic;
  final List<String> definitions;

  const _DictEntry({
    required this.word,
    required this.phonetic,
    required this.definitions,
  });
}

/// 在线词典规则
class _DictRule {
  final String name;
  final String urlTemplate; // 使用 {{key}} 作为查询占位符

  const _DictRule({required this.name, required this.urlTemplate});

  Map<String, dynamic> toJson() => {'name': name, 'urlTemplate': urlTemplate};

  static _DictRule fromJson(Map<String, dynamic> json) => _DictRule(
        name: json['name'] as String? ?? '',
        urlTemplate: json['urlTemplate'] as String? ?? '',
      );

  String buildUrl(String key) => urlTemplate.replaceAll('{{key}}', key);
}

/// 字典查询页面
///
/// 优先查询内置本地词典，未命中时可通过在线词典规则跳转查询。
/// 词典规则持久化在 SharedPreferences 中。
class DictScreen extends StatefulWidget {
  const DictScreen({super.key});

  @override
  State<DictScreen> createState() => _DictScreenState();
}

class _DictScreenState extends State<DictScreen> {
  static const _rulesKey = 'dict_rules';

  final _searchController = TextEditingController();
  final _searchFocus = FocusNode();

  String? _queriedWord;
  _DictEntry? _result;
  List<_DictRule> _rules = [];

  /// 内置本地词典（常见阅读相关词汇）
  static const Map<String, _DictEntry> _localDict = {
    'chapter': _DictEntry(
      word: 'chapter',
      phonetic: '/ˈtʃæptə(r)/',
      definitions: ['n. 章，章节', 'n. （人生的）一段时期'],
    ),
    'novel': _DictEntry(
      word: 'novel',
      phonetic: '/ˈnɒvl/',
      definitions: ['n. 长篇小说', 'adj. 新奇的，异常的'],
    ),
    'author': _DictEntry(
      word: 'author',
      phonetic: '/ˈɔːθə(r)/',
      definitions: ['n. 作者，作家', 'v. 编写，创作'],
    ),
    'bookmark': _DictEntry(
      word: 'bookmark',
      phonetic: '/ˈbʊkmɑːk/',
      definitions: ['n. 书签', 'v. 将…加入书签'],
    ),
    'library': _DictEntry(
      word: 'library',
      phonetic: '/ˈlaɪbrəri/',
      definitions: ['n. 图书馆，藏书室', 'n. 文库，（软件）库'],
    ),
    'fiction': _DictEntry(
      word: 'fiction',
      phonetic: '/ˈfɪkʃn/',
      definitions: ['n. 小说，虚构作品', 'n. 虚构，想象'],
    ),
    'prologue': _DictEntry(
      word: 'prologue',
      phonetic: '/ˈprəʊlɒɡ/',
      definitions: ['n. 序言，开场白'],
    ),
    'epilogue': _DictEntry(
      word: 'epilogue',
      phonetic: '/ˈepɪlɒɡ/',
      definitions: ['n. 结语，尾声'],
    ),
    'paragraph': _DictEntry(
      word: 'paragraph',
      phonetic: '/ˈpærəɡrɑːf/',
      definitions: ['n. 段落', 'n. （报刊的）短讯'],
    ),
    'volume': _DictEntry(
      word: 'volume',
      phonetic: '/ˈvɒljuːm/',
      definitions: ['n. 卷，册', 'n. 音量', 'n. 体积，容量'],
    ),
  };

  @override
  void initState() {
    super.initState();
    _loadRules();
  }

  @override
  void dispose() {
    _searchController.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  Future<void> _loadRules() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_rulesKey);
    if (raw != null && raw.isNotEmpty) {
      try {
        final list = jsonDecode(raw) as List<dynamic>;
        _rules = list
            .map((e) => _DictRule.fromJson(e as Map<String, dynamic>))
            .toList();
      } catch (_) {
        _rules = [];
      }
    } else {
      // 首次使用预置默认在线词典
      _rules = const [
        _DictRule(
          name: '有道词典',
          urlTemplate: 'https://dict.youdao.com/w/{{key}}',
        ),
        _DictRule(
          name: '剑桥词典',
          urlTemplate: 'https://dictionary.cambridge.org/dictionary/english-chinese-simplified/{{key}}',
        ),
      ];
      await _saveRules();
    }
    if (mounted) setState(() {});
  }

  Future<void> _saveRules() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _rulesKey,
      jsonEncode(_rules.map((e) => e.toJson()).toList()),
    );
  }

  void _search() {
    final word = _searchController.text.trim().toLowerCase();
    if (word.isEmpty) return;
    setState(() {
      _queriedWord = word;
      _result = _localDict[word];
    });
  }

  Future<void> _launchOnline(_DictRule rule) async {
    final word = _queriedWord ?? _searchController.text.trim();
    if (word.isEmpty) return;
    final uri = Uri.tryParse(rule.buildUrl(word));
    if (uri == null) return;
    if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('无法打开在线词典')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('字典查询'),
        actions: [
          IconButton(
            icon: const Icon(Icons.rule_folder_outlined),
            tooltip: '词典规则管理',
            onPressed: _showRuleManager,
          ),
        ],
      ),
      body: Column(
        children: [
          _buildSearchBar(theme),
          const Divider(height: 1),
          Expanded(child: _buildBody(theme)),
        ],
      ),
    );
  }

  Widget _buildSearchBar(ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _searchController,
              focusNode: _searchFocus,
              autofocus: true,
              textInputAction: TextInputAction.search,
              onSubmitted: (_) => _search(),
              decoration: InputDecoration(
                prefixIcon: const Icon(Icons.search),
                hintText: '输入单词查询释义',
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(24),
                ),
                contentPadding: const EdgeInsets.symmetric(horizontal: 16),
              ),
            ),
          ),
          const SizedBox(width: 8),
          FilledButton(
            onPressed: _search,
            child: const Text('查询'),
          ),
        ],
      ),
    );
  }

  Widget _buildBody(ThemeData theme) {
    if (_queriedWord == null) {
      return _buildEmptyHint(theme);
    }
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (_result != null) _buildResultCard(theme, _result!)
        else _buildNotFound(theme, _queriedWord!),
        const SizedBox(height: 20),
        _buildOnlineSection(theme),
      ],
    );
  }

  Widget _buildEmptyHint(ThemeData theme) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.menu_book, size: 64, color: theme.colorScheme.outline),
          const SizedBox(height: 16),
          Text('输入单词开始查询', style: theme.textTheme.bodyLarge),
          const SizedBox(height: 8),
          Text(
            '内置本地词典，未收录的词可跳转在线词典',
            style: theme.textTheme.bodySmall,
          ),
        ],
      ),
    );
  }

  Widget _buildResultCard(ThemeData theme, _DictEntry entry) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  entry.word,
                  style: theme.textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(width: 12),
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Text(
                    entry.phonetic,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.secondary,
                    ),
                  ),
                ),
                const Spacer(),
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primaryContainer,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    '本地词典',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onPrimaryContainer,
                    ),
                  ),
                ),
              ],
            ),
            const Divider(height: 24),
            ...entry.definitions.map(
              (d) => Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.circle, size: 6,
                        color: theme.colorScheme.primary),
                    const SizedBox(width: 10),
                    Expanded(child: Text(d, style: theme.textTheme.bodyLarge)),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildNotFound(ThemeData theme, String word) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            Icon(Icons.search_off, size: 40,
                color: theme.colorScheme.outline),
            const SizedBox(height: 8),
            Text(
              '本地词典未收录「$word」',
              style: theme.textTheme.titleSmall,
            ),
            const SizedBox(height: 4),
            Text(
              '可使用下方在线词典查询',
              style: theme.textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildOnlineSection(ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('在线词典', style: theme.textTheme.titleSmall),
        const SizedBox(height: 8),
        if (_rules.isEmpty)
          Text('暂无词典规则，点击右上角管理添加',
              style: theme.textTheme.bodySmall)
        else
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: _rules
                .map((rule) => ActionChip(
                      avatar: const Icon(Icons.open_in_new, size: 16),
                      label: Text(rule.name),
                      onPressed: () => _launchOnline(rule),
                    ))
                .toList(),
          ),
      ],
    );
  }

  // ========== 词典规则管理 ==========

  void _showRuleManager() {
    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('词典规则管理'),
          content: SizedBox(
            width: double.maxFinite,
            child: _rules.isEmpty
                ? const Padding(
                    padding: EdgeInsets.all(16),
                    child: Text('暂无规则，点击下方按钮添加'),
                  )
                : ListView.separated(
                    shrinkWrap: true,
                    itemCount: _rules.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (context, index) {
                      final rule = _rules[index];
                      return ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        title: Text(rule.name),
                        subtitle: Text(
                          rule.urlTemplate,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: IconButton(
                          icon: const Icon(Icons.delete_outline, size: 20),
                          onPressed: () async {
                            setDialogState(() => _rules.removeAt(index));
                            await _saveRules();
                            setState(() {});
                          },
                        ),
                      );
                    },
                  ),
          ),
          actions: [
            TextButton(
              onPressed: () =>
                  _showRuleEditor(ctx, onSaved: setDialogState),
              child: const Text('添加规则'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('完成'),
            ),
          ],
        ),
      ),
    );
  }

  void _showRuleEditor(BuildContext ctx, {required StateSetter onSaved}) {
    final nameCtrl = TextEditingController();
    final urlCtrl = TextEditingController(text: 'https://example.com/dict?q={{key}}');
    showDialog(
      context: ctx,
      builder: (editCtx) => AlertDialog(
        title: const Text('添加词典规则'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameCtrl,
              decoration: const InputDecoration(
                labelText: '规则名称',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: urlCtrl,
              decoration: const InputDecoration(
                labelText: '查询地址',
                hintText: '使用 {{key}} 作为单词占位符',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(editCtx).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () async {
              final name = nameCtrl.text.trim();
              final url = urlCtrl.text.trim();
              if (name.isEmpty || url.isEmpty) return;
              _rules.add(_DictRule(name: name, urlTemplate: url));
              await _saveRules();
              onSaved(() {});
              setState(() {});
              if (editCtx.mounted) Navigator.of(editCtx).pop();
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );
  }
}
