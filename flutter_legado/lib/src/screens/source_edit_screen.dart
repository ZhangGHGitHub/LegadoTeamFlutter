import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../bridge/rust_lib.dart' as bridge;
import '../models/models.dart';
import '../providers/source_provider.dart';
import '../routes.dart';
import '../services/rust_api.dart';
import '../widgets/loading_indicator.dart';

/// 书源编辑页面
class SourceEditScreen extends StatefulWidget {
  /// 书源 URL（编辑模式），null 表示新建
  final String? sourceUrl;

  const SourceEditScreen({super.key, this.sourceUrl});

  @override
  State<SourceEditScreen> createState() => _SourceEditScreenState();
}

class _SourceEditScreenState extends State<SourceEditScreen> {
  final _formKey = GlobalKey<FormState>();
  bool _saving = false;

  // 基本信息控制器
  late TextEditingController _nameCtrl;
  late TextEditingController _urlCtrl;
  late TextEditingController _groupCtrl;
  late TextEditingController _typeCtrl;
  late TextEditingController _commentCtrl;
  late TextEditingController _loginUrlCtrl;
  late TextEditingController _headerCtrl;

  // 搜索规则控制器
  late TextEditingController _searchUrlCtrl;
  late TextEditingController _searchBookListCtrl;
  late TextEditingController _searchNameCtrl;
  late TextEditingController _searchAuthorCtrl;
  late TextEditingController _searchBookUrlCtrl;
  late TextEditingController _searchCoverUrlCtrl;
  late TextEditingController _searchIntroCtrl;

  // 目录规则控制器
  late TextEditingController _tocChapterListCtrl;
  late TextEditingController _tocChapterNameCtrl;
  late TextEditingController _tocChapterUrlCtrl;
  late TextEditingController _tocNextUrlCtrl;

  // 内容规则控制器
  late TextEditingController _contentContentCtrl;
  late TextEditingController _contentTitleCtrl;
  late TextEditingController _contentNextUrlCtrl;
  late TextEditingController _contentWebJsCtrl;

  // 测试
  late TextEditingController _testKeywordCtrl;
  bool _testing = false;
  List<SearchResult> _testResults = [];
  String? _testError;

  // 规则验证状态
  bool _validating = false;
  String? _validateResult; // JSON 格式验证结果
  bool _validateSuccess = false; // 验证是否成功

  bool get isNew => widget.sourceUrl == null;

  @override
  void initState() {
    super.initState();

    // 初始化控制器
    _nameCtrl = TextEditingController();
    _urlCtrl = TextEditingController();
    _groupCtrl = TextEditingController();
    _typeCtrl = TextEditingController(text: '0');
    _commentCtrl = TextEditingController();
    _loginUrlCtrl = TextEditingController();
    _headerCtrl = TextEditingController();

    _searchUrlCtrl = TextEditingController();
    _searchBookListCtrl = TextEditingController();
    _searchNameCtrl = TextEditingController();
    _searchAuthorCtrl = TextEditingController();
    _searchBookUrlCtrl = TextEditingController();
    _searchCoverUrlCtrl = TextEditingController();
    _searchIntroCtrl = TextEditingController();

    _tocChapterListCtrl = TextEditingController();
    _tocChapterNameCtrl = TextEditingController();
    _tocChapterUrlCtrl = TextEditingController();
    _tocNextUrlCtrl = TextEditingController();

    _contentContentCtrl = TextEditingController();
    _contentTitleCtrl = TextEditingController();
    _contentNextUrlCtrl = TextEditingController();
    _contentWebJsCtrl = TextEditingController();

    _testKeywordCtrl = TextEditingController();

    if (!isNew) {
      _loadSource();
    }
  }

  void _loadSource() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final provider = context.read<SourceProvider>();
      final source = provider.getSource(widget.sourceUrl!);
      if (source != null) {
        _populateFields(source);
      }
    });
  }

  void _populateFields(BookSource source) {
    _nameCtrl.text = source.bookSourceName;
    _urlCtrl.text = source.bookSourceUrl;
    _groupCtrl.text = source.bookSourceGroup ?? '';
    _typeCtrl.text = source.bookSourceType.toString();
    _commentCtrl.text = source.bookSourceComment ?? '';
    _loginUrlCtrl.text = source.loginUrl ?? '';
    _headerCtrl.text = source.header ?? '';

    // 搜索规则
    _searchUrlCtrl.text = source.searchUrl ?? '';
    final sr = source.ruleSearch;
    if (sr != null) {
      _searchBookListCtrl.text = sr.bookList ?? '';
      _searchNameCtrl.text = sr.name ?? '';
      _searchAuthorCtrl.text = sr.author ?? '';
      _searchBookUrlCtrl.text = sr.bookUrl ?? '';
      _searchCoverUrlCtrl.text = sr.coverUrl ?? '';
      _searchIntroCtrl.text = sr.intro ?? '';
    }

    // 目录规则
    final tr = source.ruleToc;
    if (tr != null) {
      _tocChapterListCtrl.text = tr.chapterList ?? '';
      _tocChapterNameCtrl.text = tr.chapterName ?? '';
      _tocChapterUrlCtrl.text = tr.chapterUrl ?? '';
      _tocNextUrlCtrl.text = tr.nextTocUrl ?? '';
    }

    // 内容规则
    final cr = source.ruleContent;
    if (cr != null) {
      _contentContentCtrl.text = cr.content ?? '';
      _contentTitleCtrl.text = cr.title ?? '';
      _contentNextUrlCtrl.text = cr.nextContentUrl ?? '';
      _contentWebJsCtrl.text = cr.webJs ?? '';
    }

    setState(() {});
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _urlCtrl.dispose();
    _groupCtrl.dispose();
    _typeCtrl.dispose();
    _commentCtrl.dispose();
    _loginUrlCtrl.dispose();
    _headerCtrl.dispose();

    _searchUrlCtrl.dispose();
    _searchBookListCtrl.dispose();
    _searchNameCtrl.dispose();
    _searchAuthorCtrl.dispose();
    _searchBookUrlCtrl.dispose();
    _searchCoverUrlCtrl.dispose();
    _searchIntroCtrl.dispose();

    _tocChapterListCtrl.dispose();
    _tocChapterNameCtrl.dispose();
    _tocChapterUrlCtrl.dispose();
    _tocNextUrlCtrl.dispose();

    _contentContentCtrl.dispose();
    _contentTitleCtrl.dispose();
    _contentNextUrlCtrl.dispose();
    _contentWebJsCtrl.dispose();

    _testKeywordCtrl.dispose();
    super.dispose();
  }

  BookSource _buildSource() {
    return BookSource(
      bookSourceName: _nameCtrl.text.trim(),
      bookSourceUrl: _urlCtrl.text.trim(),
      bookSourceGroup: _groupCtrl.text.trim().isNotEmpty
          ? _groupCtrl.text.trim()
          : null,
      bookSourceType: int.tryParse(_typeCtrl.text.trim()) ?? 0,
      bookSourceComment: _commentCtrl.text.trim().isNotEmpty
          ? _commentCtrl.text.trim()
          : null,
      loginUrl: _loginUrlCtrl.text.trim().isNotEmpty
          ? _loginUrlCtrl.text.trim()
          : null,
      header: _headerCtrl.text.trim().isNotEmpty
          ? _headerCtrl.text.trim()
          : null,
      searchUrl: _searchUrlCtrl.text.trim().isNotEmpty
          ? _searchUrlCtrl.text.trim()
          : null,
      ruleSearch: SearchRule(
        bookList: _searchBookListCtrl.text.trim().isNotEmpty
            ? _searchBookListCtrl.text.trim()
            : null,
        name: _searchNameCtrl.text.trim().isNotEmpty
            ? _searchNameCtrl.text.trim()
            : null,
        author: _searchAuthorCtrl.text.trim().isNotEmpty
            ? _searchAuthorCtrl.text.trim()
            : null,
        bookUrl: _searchBookUrlCtrl.text.trim().isNotEmpty
            ? _searchBookUrlCtrl.text.trim()
            : null,
        coverUrl: _searchCoverUrlCtrl.text.trim().isNotEmpty
            ? _searchCoverUrlCtrl.text.trim()
            : null,
        intro: _searchIntroCtrl.text.trim().isNotEmpty
            ? _searchIntroCtrl.text.trim()
            : null,
      ),
      ruleToc: TocRule(
        chapterList: _tocChapterListCtrl.text.trim().isNotEmpty
            ? _tocChapterListCtrl.text.trim()
            : null,
        chapterName: _tocChapterNameCtrl.text.trim().isNotEmpty
            ? _tocChapterNameCtrl.text.trim()
            : null,
        chapterUrl: _tocChapterUrlCtrl.text.trim().isNotEmpty
            ? _tocChapterUrlCtrl.text.trim()
            : null,
        nextTocUrl: _tocNextUrlCtrl.text.trim().isNotEmpty
            ? _tocNextUrlCtrl.text.trim()
            : null,
      ),
      ruleContent: ContentRule(
        content: _contentContentCtrl.text.trim().isNotEmpty
            ? _contentContentCtrl.text.trim()
            : null,
        title: _contentTitleCtrl.text.trim().isNotEmpty
            ? _contentTitleCtrl.text.trim()
            : null,
        nextContentUrl: _contentNextUrlCtrl.text.trim().isNotEmpty
            ? _contentNextUrlCtrl.text.trim()
            : null,
        webJs: _contentWebJsCtrl.text.trim().isNotEmpty
            ? _contentWebJsCtrl.text.trim()
            : null,
      ),
    );
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() => _saving = true);
    try {
      final source = _buildSource();
      final provider = context.read<SourceProvider>();
      await provider.saveSource(source);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(isNew ? '书源已创建' : '书源已保存')),
        );
        Navigator.of(context).pop();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('保存失败：$e')),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _testSource() async {
    final keyword = _testKeywordCtrl.text.trim();
    if (keyword.isEmpty) return;

    setState(() {
      _testing = true;
      _testResults = [];
      _testError = null;
    });

    try {
      final source = _buildSource();
      // 先保存书源以便搜索
      final provider = context.read<SourceProvider>();
      await provider.saveSource(source);

      if (!mounted) return;
      final results = await context.read<RustApi>().searchBooks(
        keyword,
        sourceUrls: [source.bookSourceUrl],
      );
      if (!mounted) return;
      setState(() {
        _testResults = results;
        _testing = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _testError = e.toString();
        _testing = false;
      });
    }
  }

  /// 显示规则验证对话框
  Future<void> _showValidateDialog() async {
    final urlCtrl = TextEditingController();
    // 默认验证类型：搜索
    String validateType = 'search';

    await showDialog<void>(
      context: context,
      builder: (dialogCtx) {
        return StatefulBuilder(
          builder: (ctx, setDialogState) {
            return AlertDialog(
              title: const Text('规则验证'),
              content: SizedBox(
                width: 500,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // 测试 URL 输入
                    TextField(
                      controller: urlCtrl,
                      decoration: const InputDecoration(
                        labelText: '测试 URL',
                        hintText: '搜索关键词 / 书籍URL / 章节URL',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                    ),
                    const SizedBox(height: 12),
                    // 验证类型选择
                    Wrap(
                      spacing: 8,
                      children: [
                        _buildValidateTypeChip(
                          label: '搜索',
                          value: 'search',
                          selected: validateType == 'search',
                          onSelected: () =>
                              setDialogState(() => validateType = 'search'),
                        ),
                        _buildValidateTypeChip(
                          label: '书籍详情',
                          value: 'info',
                          selected: validateType == 'info',
                          onSelected: () =>
                              setDialogState(() => validateType = 'info'),
                        ),
                        _buildValidateTypeChip(
                          label: '章节目录',
                          value: 'chapters',
                          selected: validateType == 'chapters',
                          onSelected: () =>
                              setDialogState(() => validateType = 'chapters'),
                        ),
                        _buildValidateTypeChip(
                          label: '章节内容',
                          value: 'content',
                          selected: validateType == 'content',
                          onSelected: () =>
                              setDialogState(() => validateType = 'content'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    // 验证结果区域
                    if (_validating)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 16),
                        child: Center(
                          child: Column(
                            children: [
                              CircularProgressIndicator(),
                              SizedBox(height: 8),
                              Text('验证中...'),
                            ],
                          ),
                        ),
                      )
                    else if (_validateResult != null)
                      Container(
                        constraints: const BoxConstraints(maxHeight: 300),
                        decoration: BoxDecoration(
                          color: _validateSuccess
                              ? Colors.green.shade50
                              : Theme.of(ctx).colorScheme.errorContainer,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                            color: _validateSuccess
                                ? Colors.green.shade300
                                : Theme.of(ctx).colorScheme.error,
                          ),
                        ),
                        padding: const EdgeInsets.all(12),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            // 状态标题栏
                            Row(
                              children: [
                                Icon(
                                  _validateSuccess
                                      ? Icons.check_circle
                                      : Icons.error,
                                  color: _validateSuccess
                                      ? Colors.green
                                      : Theme.of(ctx).colorScheme.error,
                                  size: 20,
                                ),
                                const SizedBox(width: 8),
                                Text(
                                  _validateSuccess ? '验证成功' : '验证失败',
                                  style: TextStyle(
                                    fontWeight: FontWeight.bold,
                                    color: _validateSuccess
                                        ? Colors.green.shade800
                                        : Theme.of(ctx).colorScheme.error,
                                  ),
                                ),
                                const Spacer(),
                                // 复制按钮
                                IconButton(
                                  icon: const Icon(Icons.copy, size: 18),
                                  tooltip: '复制结果',
                                  onPressed: () {
                                    Clipboard.setData(
                                      ClipboardData(text: _validateResult!),
                                    );
                                    ScaffoldMessenger.of(ctx).showSnackBar(
                                      const SnackBar(
                                          content: Text('已复制到剪贴板')),
                                    );
                                  },
                                ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            // JSON 预览
                            Flexible(
                              child: SingleChildScrollView(
                                child: SelectableText(
                                  _validateResult!,
                                  style: const TextStyle(
                                    fontFamily: 'monospace',
                                    fontSize: 11,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(dialogCtx).pop(),
                  child: const Text('关闭'),
                ),
                FilledButton.icon(
                  icon: const Icon(Icons.play_arrow),
                  label: const Text('验证'),
                  onPressed: _validating
                      ? null
                      : () async {
                          final url = urlCtrl.text.trim();
                          if (url.isEmpty) {
                            ScaffoldMessenger.of(ctx).showSnackBar(
                              const SnackBar(content: Text('请输入测试 URL')),
                            );
                            return;
                          }
                          // 执行验证
                          setDialogState(() {
                            _validating = true;
                            _validateResult = null;
                          });
                          await _runValidation(url, validateType);
                          setDialogState(() => _validating = false);
                        },
                ),
              ],
            );
          },
        );
      },
    );
    urlCtrl.dispose();
  }

  /// 构建验证类型选择芯片
  Widget _buildValidateTypeChip({
    required String label,
    required String value,
    required bool selected,
    required VoidCallback onSelected,
  }) {
    return FilterChip(
      label: Text(label),
      selected: selected,
      onSelected: (_) => onSelected(),
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      visualDensity: VisualDensity.compact,
    );
  }

  /// 执行规则验证
  Future<void> _runValidation(String url, String type) async {
    try {
      final source = _buildSource();
      // 先保存书源
      if (!mounted) return;
      final provider = context.read<SourceProvider>();
      await provider.saveSource(source);

      final sourceJson = jsonEncode(source.toJson());
      String result;

      switch (type) {
        case 'search':
          // 搜索验证
          result = await bridge.webbookSearch(
            sourceJson: sourceJson,
            query: url,
            page: 1,
          );
        case 'info':
          // 书籍详情验证
          result = await bridge.webbookInfo(
            sourceJson: sourceJson,
            bookUrl: url,
          );
        case 'chapters':
          // 章节目录验证
          result = await bridge.webbookChapters(
            sourceJson: sourceJson,
            bookUrl: url,
          );
        case 'content':
          // 章节内容验证
          result = await bridge.webbookContent(
            sourceJson: sourceJson,
            chapterJson: url,
          );
        default:
          result = '{"error": "未知验证类型"}';
      }

      // 格式化 JSON 输出
      String formatted;
      try {
        final decoded = jsonDecode(result);
        formatted = const JsonEncoder.withIndent('  ').convert(decoded);
      } catch (_) {
        formatted = result;
      }

      if (!mounted) return;
      setState(() {
        _validateResult = formatted;
        _validateSuccess = true;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _validateResult = '错误: $e';
        _validateSuccess = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 5,
      child: Scaffold(
        appBar: AppBar(
          title: Text(isNew ? '新建书源' : '编辑书源'),
          bottom: const TabBar(
            isScrollable: true,
            tabs: [
              Tab(text: '基本信息'),
              Tab(text: '搜索规则'),
              Tab(text: '目录规则'),
              Tab(text: '内容规则'),
              Tab(text: '测试'),
            ],
          ),
          actions: [
            // 验证规则按钮
            IconButton(
              icon: const Icon(Icons.rule_folder_outlined),
              tooltip: '验证规则',
              onPressed: _showValidateDialog,
            ),
            IconButton(
              icon: const Icon(Icons.menu_book_outlined),
              tooltip: '字典查询',
              onPressed: () =>
                  Navigator.pushNamed(context, AppRoutes.dict),
            ),
            TextButton.icon(
              icon: const Icon(Icons.save),
              label: const Text('保存'),
              onPressed: _saving ? null : _save,
            ),
          ],
        ),
        body: Form(
          key: _formKey,
          child: TabBarView(
            children: [
              _buildBasicInfoTab(),
              _buildSearchRuleTab(),
              _buildTocRuleTab(),
              _buildContentRuleTab(),
              _buildTestTab(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBasicInfoTab() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        TextFormField(
          controller: _nameCtrl,
          decoration: const InputDecoration(
            labelText: '书源名称 *',
            border: OutlineInputBorder(),
          ),
          validator: (v) => (v == null || v.trim().isEmpty) ? '请输入书源名称' : null,
        ),
        const SizedBox(height: 16),
        TextFormField(
          controller: _urlCtrl,
          decoration: const InputDecoration(
            labelText: '书源 URL *',
            border: OutlineInputBorder(),
          ),
          validator: (v) => (v == null || v.trim().isEmpty) ? '请输入书源 URL' : null,
        ),
        const SizedBox(height: 16),
        TextFormField(
          controller: _groupCtrl,
          decoration: const InputDecoration(
            labelText: '分组',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 16),
        TextFormField(
          controller: _typeCtrl,
          decoration: const InputDecoration(
            labelText: '类型（0=文本, 1=音频, 2=图片, 3=文件, 4=视频）',
            border: OutlineInputBorder(),
          ),
          keyboardType: TextInputType.number,
        ),
        const SizedBox(height: 16),
        TextFormField(
          controller: _headerCtrl,
          decoration: const InputDecoration(
            labelText: '请求头（JSON 格式）',
            border: OutlineInputBorder(),
          ),
          maxLines: 3,
        ),
        const SizedBox(height: 16),
        TextFormField(
          controller: _loginUrlCtrl,
          decoration: const InputDecoration(
            labelText: '登录 URL',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 16),
        TextFormField(
          controller: _commentCtrl,
          decoration: const InputDecoration(
            labelText: '备注',
            border: OutlineInputBorder(),
          ),
          maxLines: 3,
        ),
      ],
    );
  }

  Widget _buildRuleField({
    required String label,
    required TextEditingController controller,
    int maxLines = 2,
    String? hint,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextFormField(
        controller: controller,
        maxLines: maxLines,
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          border: const OutlineInputBorder(),
        ),
      ),
    );
  }

  Widget _buildSearchRuleTab() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _buildRuleField(
          label: '搜索 URL',
          controller: _searchUrlCtrl,
          hint: '例如：https://example.com/search?q=searchKey',
        ),
        const Divider(),
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 8),
          child: Text('搜索结果规则', style: TextStyle(fontWeight: FontWeight.bold)),
        ),
        _buildRuleField(label: '书籍列表', controller: _searchBookListCtrl),
        _buildRuleField(label: '书名', controller: _searchNameCtrl),
        _buildRuleField(label: '作者', controller: _searchAuthorCtrl),
        _buildRuleField(label: '书籍 URL', controller: _searchBookUrlCtrl),
        _buildRuleField(label: '封面 URL', controller: _searchCoverUrlCtrl),
        _buildRuleField(label: '简介', controller: _searchIntroCtrl),
      ],
    );
  }

  Widget _buildTocRuleTab() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 8),
          child: Text('目录规则', style: TextStyle(fontWeight: FontWeight.bold)),
        ),
        _buildRuleField(label: '章节列表', controller: _tocChapterListCtrl),
        _buildRuleField(label: '章节名称', controller: _tocChapterNameCtrl),
        _buildRuleField(label: '章节 URL', controller: _tocChapterUrlCtrl),
        _buildRuleField(label: '下一页 URL', controller: _tocNextUrlCtrl),
      ],
    );
  }

  Widget _buildContentRuleTab() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 8),
          child: Text('内容规则', style: TextStyle(fontWeight: FontWeight.bold)),
        ),
        _buildRuleField(
          label: '正文内容',
          controller: _contentContentCtrl,
          maxLines: 3,
        ),
        _buildRuleField(label: '标题', controller: _contentTitleCtrl),
        _buildRuleField(label: '下一页 URL', controller: _contentNextUrlCtrl),
        _buildRuleField(
          label: 'Web JS',
          controller: _contentWebJsCtrl,
          maxLines: 4,
        ),
      ],
    );
  }

  Widget _buildTestTab() {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _testKeywordCtrl,
                  decoration: const InputDecoration(
                    labelText: '测试关键词',
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              FilledButton.icon(
                icon: const Icon(Icons.play_arrow),
                label: const Text('测试'),
                onPressed: _testing ? null : _testSource,
              ),
            ],
          ),
        ),
        if (_testing)
          const Expanded(child: LoadingIndicator(message: '测试中...'))
        else if (_testError != null)
          Expanded(
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  '测试失败：$_testError',
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            ),
          )
        else if (_testResults.isEmpty)
          const Expanded(
            child: Center(
              child: Text('输入关键词测试书源搜索功能'),
            ),
          )
        else
          Expanded(
            child: ListView.separated(
              itemCount: _testResults.length,
              separatorBuilder: (_, _) => const Divider(height: 1, indent: 16),
              itemBuilder: (context, index) {
                final result = _testResults[index];
                return ListTile(
                  leading: const Icon(Icons.book),
                  title: Text(result.book.name),
                  subtitle: Text(result.book.author),
                  trailing: Text(
                    result.book.latestChapterTitle ?? '',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                );
              },
            ),
          ),
      ],
    );
  }
}
