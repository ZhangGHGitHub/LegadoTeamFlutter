import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;

import '../models/models.dart';
import '../providers/providers.dart';
import '../providers/source/source_notifier.dart';
import '../routes.dart';
import '../widgets/loading_indicator.dart';

/// 书源编辑页面
///
/// 对标 Android `BookSourceEditActivity`，采用多 Tab 表单编辑书源的全部规则：
/// 基本信息 / 搜索规则 / 发现规则 / 详情规则 / 目录规则 / 内容规则 / 评论规则 / 测试。
/// 表单字段以数据驱动方式定义（[_Field] 列表），controller 按 key 惰性创建，
/// 与原版基于 `EditEntity` 列表的配置化编辑思路一致。
class SourceEditScreen extends ConsumerStatefulWidget {
  /// 书源 URL（编辑模式），null 表示新建
  final String? sourceUrl;

  const SourceEditScreen({super.key, this.sourceUrl});

  @override
  ConsumerState<SourceEditScreen> createState() => _SourceEditScreenState();
}

/// 表单字段定义
class _Field {
  /// 控制器 key（唯一），同时用于 [_SourceEditScreenState._sourceToValues]
  /// 与 [_SourceEditScreenState._buildSource] 的字段映射。
  final String key;

  /// 字段标签（不含必填星号）
  final String label;

  /// 提示文本
  final String? hint;

  /// 最大行数
  final int maxLines;

  /// 是否必填（参与表单校验）
  final bool required;

  /// 键盘类型
  final TextInputType? keyboardType;

  const _Field(
    this.key,
    this.label, {
    this.hint,
    this.maxLines = 2,
    this.required = false,
    this.keyboardType,
  });
}

class _SourceEditScreenState extends ConsumerState<SourceEditScreen> {
  final _formKey = GlobalKey<FormState>();
  bool _saving = false;

  /// 所有文本字段控制器（按 key 惰性创建）
  final Map<String, TextEditingController> _ctrls = {};

  // 开关状态（非文本字段）
  bool _enabledExplore = true;
  bool _reviewEnabled = false;

  // 测试
  final _testKeywordCtrl = TextEditingController();
  bool _testing = false;
  List<SearchResult> _testResults = [];
  String? _testError;

  // 规则验证状态
  bool _validating = false;
  String? _validateResult; // JSON 格式验证结果
  bool _validateSuccess = false; // 验证是否成功

  bool get isNew => widget.sourceUrl == null;

  /// 按 key 惰性获取控制器
  TextEditingController _ctrl(String key) =>
      _ctrls.putIfAbsent(key, () => TextEditingController());

  // ─── 基本信息字段 ───────────────────────────────────────
  static const _basicFields = [
    _Field('bookSourceName', '书源名称', required: true, maxLines: 1),
    _Field('bookSourceUrl', '书源 URL', required: true, maxLines: 1),
    _Field('bookSourceGroup', '分组', maxLines: 1),
    _Field(
      'bookSourceType',
      '类型（0=文本, 1=音频, 2=图片, 3=文件, 4=视频）',
      maxLines: 1,
      keyboardType: TextInputType.number,
    ),
    _Field('header', '请求头（JSON 格式）', maxLines: 3),
    _Field('loginUrl', '登录 URL', maxLines: 1),
    _Field('bookSourceComment', '备注', maxLines: 3),
  ];

  // ─── 搜索规则字段 ───────────────────────────────────────
  static const _searchFields = [
    _Field(
      'searchUrl',
      '搜索 URL',
      maxLines: 1,
      hint: '例如：https://example.com/search?q=searchKey',
    ),
    _Field('s_checkKeyWord', '校验关键字'),
    _Field('s_bookList', '书籍列表'),
    _Field('s_name', '书名'),
    _Field('s_author', '作者'),
    _Field('s_intro', '简介'),
    _Field('s_kind', '分类'),
    _Field('s_lastChapter', '最新章节'),
    _Field('s_updateTime', '更新时间'),
    _Field('s_bookUrl', '书籍 URL'),
    _Field('s_coverUrl', '封面 URL'),
    _Field('s_wordCount', '字数'),
  ];

  // ─── 发现规则字段 ───────────────────────────────────────
  static const _exploreFields = [
    _Field(
      'exploreUrl',
      '发现 URL',
      maxLines: 3,
      hint: '例如：分类名::https://example.com/sort\n或 url 形式',
    ),
    _Field('e_bookList', '书籍列表'),
    _Field('e_name', '书名'),
    _Field('e_author', '作者'),
    _Field('e_intro', '简介'),
    _Field('e_kind', '分类'),
    _Field('e_lastChapter', '最新章节'),
    _Field('e_updateTime', '更新时间'),
    _Field('e_bookUrl', '书籍 URL'),
    _Field('e_coverUrl', '封面 URL'),
    _Field('e_wordCount', '字数'),
  ];

  // ─── 详情规则字段 ───────────────────────────────────────
  static const _infoFields = [
    _Field('i_init', '初始化'),
    _Field('i_name', '书名'),
    _Field('i_author', '作者'),
    _Field('i_intro', '简介'),
    _Field('i_kind', '分类'),
    _Field('i_lastChapter', '最新章节'),
    _Field('i_updateTime', '更新时间'),
    _Field('i_coverUrl', '封面 URL'),
    _Field('i_tocUrl', '目录 URL'),
    _Field('i_wordCount', '字数'),
    _Field('i_canReName', '修改书名'),
    _Field('i_downloadUrls', '下载 URL'),
  ];

  // ─── 目录规则字段 ───────────────────────────────────────
  static const _tocFields = [
    _Field('t_preUpdateJs', '列表预处理 JS'),
    _Field('t_chapterList', '章节列表'),
    _Field('t_chapterName', '章节名称'),
    _Field('t_chapterUrl', '章节 URL'),
    _Field('t_formatJs', '名称格式化 JS'),
    _Field('t_isVolume', '卷标识'),
    _Field('t_isVip', 'VIP 标识'),
    _Field('t_isPay', '付费标识'),
    _Field('t_updateTime', '更新时间'),
    _Field('t_nextTocUrl', '下一页 URL'),
  ];

  // ─── 内容规则字段 ───────────────────────────────────────
  static const _contentFields = [
    _Field('c_content', '正文内容', maxLines: 3),
    _Field('c_subContent', '子正文'),
    _Field('c_title', '标题'),
    _Field('c_nextContentUrl', '下一页 URL'),
    _Field('c_webJs', 'Web JS', maxLines: 4),
    _Field('c_sourceRegex', '资源正则'),
    _Field('c_replaceRegex', '替换正则'),
    _Field('c_imageStyle', '图片样式'),
    _Field('c_imageDecode', '图片解码'),
    _Field('c_payAction', '付费操作'),
    _Field('c_callBackJs', '回调 JS'),
  ];

  // ─── 评论规则字段 ───────────────────────────────────────
  static const _reviewFields = [
    _Field('r_reviewUrl', '段评 URL'),
    _Field('r_avatarRule', '头像规则'),
    _Field('r_contentRule', '内容规则'),
    _Field('r_postTimeRule', '发布时间规则'),
    _Field('r_reviewQuoteUrl', '评论引用 URL'),
    _Field('r_voteUpUrl', '点赞 URL'),
    _Field('r_voteDownUrl', '点踩 URL'),
    _Field('r_postReviewUrl', '发表评论 URL'),
    _Field('r_postQuoteUrl', '发表引用 URL'),
    _Field('r_deleteUrl', '删除 URL'),
    _Field('r_reviewSummaryUrl', '评论摘要 URL'),
    _Field('r_summaryListRule', '摘要列表规则'),
    _Field('r_summaryParagraphIndexRule', '摘要段落索引规则'),
    _Field('r_summaryParagraphDataRule', '摘要段落数据规则'),
    _Field('r_summaryCountRule', '摘要数量规则'),
    _Field('r_reviewDetailUrl', '评论详情 URL'),
    _Field('r_reviewDetailNextPageUrl', '评论详情下一页 URL'),
    _Field('r_detailListRule', '详情列表规则'),
    _Field('r_detailIdRule', '详情 ID 规则'),
    _Field('r_detailAvatarRule', '详情头像规则'),
    _Field('r_detailNameRule', '详情昵称规则'),
    _Field('r_detailBadgeRule', '详情徽章规则'),
    _Field('r_detailContentRule', '详情内容规则'),
    _Field('r_replyListRule', '回复列表规则'),
    _Field('r_replyIdRule', '回复 ID 规则'),
    _Field('r_replyAvatarRule', '回复头像规则'),
    _Field('r_replyNameRule', '回复昵称规则'),
    _Field('r_replyBadgeRule', '回复徽章规则'),
    _Field('r_replyContentRule', '回复内容规则'),
  ];

  @override
  void initState() {
    super.initState();
    if (!isNew) {
      _loadSource();
    }
  }

  void _loadSource() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final notifier = ref.read(sourceNotifierProvider.notifier);
      final source = notifier.getSource(widget.sourceUrl!);
      if (source != null) {
        _populateFields(source);
      }
    });
  }

  void _populateFields(BookSource source) {
    final values = _sourceToValues(source);
    values.forEach((key, value) => _ctrl(key).text = value);
    _enabledExplore = source.enabledExplore;
    _reviewEnabled = source.ruleReview?.enabled ?? false;
    setState(() {});
  }

  @override
  void dispose() {
    for (final controller in _ctrls.values) {
      controller.dispose();
    }
    _testKeywordCtrl.dispose();
    super.dispose();
  }

  /// 将 [BookSource] 展平为 key→文本 映射，供 [_populateFields] 回填控制器。
  Map<String, String> _sourceToValues(BookSource source) {
    String v(String? value) => value ?? '';
    final sr = source.ruleSearch;
    final er = source.ruleExplore;
    final ir = source.ruleBookInfo;
    final tr = source.ruleToc;
    final cr = source.ruleContent;
    final rr = source.ruleReview;
    return {
      // 基本信息
      'bookSourceName': source.bookSourceName,
      'bookSourceUrl': source.bookSourceUrl,
      'bookSourceGroup': v(source.bookSourceGroup),
      'bookSourceType': source.bookSourceType.toString(),
      'header': v(source.header),
      'loginUrl': v(source.loginUrl),
      'bookSourceComment': v(source.bookSourceComment),
      // 搜索规则
      'searchUrl': v(source.searchUrl),
      's_checkKeyWord': v(sr?.checkKeyWord),
      's_bookList': v(sr?.bookList),
      's_name': v(sr?.name),
      's_author': v(sr?.author),
      's_intro': v(sr?.intro),
      's_kind': v(sr?.kind),
      's_lastChapter': v(sr?.lastChapter),
      's_updateTime': v(sr?.updateTime),
      's_bookUrl': v(sr?.bookUrl),
      's_coverUrl': v(sr?.coverUrl),
      's_wordCount': v(sr?.wordCount),
      // 发现规则
      'exploreUrl': v(source.exploreUrl),
      'e_bookList': v(er?.bookList),
      'e_name': v(er?.name),
      'e_author': v(er?.author),
      'e_intro': v(er?.intro),
      'e_kind': v(er?.kind),
      'e_lastChapter': v(er?.lastChapter),
      'e_updateTime': v(er?.updateTime),
      'e_bookUrl': v(er?.bookUrl),
      'e_coverUrl': v(er?.coverUrl),
      'e_wordCount': v(er?.wordCount),
      // 详情规则
      'i_init': v(ir?.init),
      'i_name': v(ir?.name),
      'i_author': v(ir?.author),
      'i_intro': v(ir?.intro),
      'i_kind': v(ir?.kind),
      'i_lastChapter': v(ir?.lastChapter),
      'i_updateTime': v(ir?.updateTime),
      'i_coverUrl': v(ir?.coverUrl),
      'i_tocUrl': v(ir?.tocUrl),
      'i_wordCount': v(ir?.wordCount),
      'i_canReName': v(ir?.canReName),
      'i_downloadUrls': v(ir?.downloadUrls),
      // 目录规则
      't_preUpdateJs': v(tr?.preUpdateJs),
      't_chapterList': v(tr?.chapterList),
      't_chapterName': v(tr?.chapterName),
      't_chapterUrl': v(tr?.chapterUrl),
      't_formatJs': v(tr?.formatJs),
      't_isVolume': v(tr?.isVolume),
      't_isVip': v(tr?.isVip),
      't_isPay': v(tr?.isPay),
      't_updateTime': v(tr?.updateTime),
      't_nextTocUrl': v(tr?.nextTocUrl),
      // 内容规则
      'c_content': v(cr?.content),
      'c_subContent': v(cr?.subContent),
      'c_title': v(cr?.title),
      'c_nextContentUrl': v(cr?.nextContentUrl),
      'c_webJs': v(cr?.webJs),
      'c_sourceRegex': v(cr?.sourceRegex),
      'c_replaceRegex': v(cr?.replaceRegex),
      'c_imageStyle': v(cr?.imageStyle),
      'c_imageDecode': v(cr?.imageDecode),
      'c_payAction': v(cr?.payAction),
      'c_callBackJs': v(cr?.callBackJs),
      // 评论规则
      'r_reviewUrl': v(rr?.reviewUrl),
      'r_avatarRule': v(rr?.avatarRule),
      'r_contentRule': v(rr?.contentRule),
      'r_postTimeRule': v(rr?.postTimeRule),
      'r_reviewQuoteUrl': v(rr?.reviewQuoteUrl),
      'r_voteUpUrl': v(rr?.voteUpUrl),
      'r_voteDownUrl': v(rr?.voteDownUrl),
      'r_postReviewUrl': v(rr?.postReviewUrl),
      'r_postQuoteUrl': v(rr?.postQuoteUrl),
      'r_deleteUrl': v(rr?.deleteUrl),
      'r_reviewSummaryUrl': v(rr?.reviewSummaryUrl),
      'r_summaryListRule': v(rr?.summaryListRule),
      'r_summaryParagraphIndexRule': v(rr?.summaryParagraphIndexRule),
      'r_summaryParagraphDataRule': v(rr?.summaryParagraphDataRule),
      'r_summaryCountRule': v(rr?.summaryCountRule),
      'r_reviewDetailUrl': v(rr?.reviewDetailUrl),
      'r_reviewDetailNextPageUrl': v(rr?.reviewDetailNextPageUrl),
      'r_detailListRule': v(rr?.detailListRule),
      'r_detailIdRule': v(rr?.detailIdRule),
      'r_detailAvatarRule': v(rr?.detailAvatarRule),
      'r_detailNameRule': v(rr?.detailNameRule),
      'r_detailBadgeRule': v(rr?.detailBadgeRule),
      'r_detailContentRule': v(rr?.detailContentRule),
      'r_replyListRule': v(rr?.replyListRule),
      'r_replyIdRule': v(rr?.replyIdRule),
      'r_replyAvatarRule': v(rr?.replyAvatarRule),
      'r_replyNameRule': v(rr?.replyNameRule),
      'r_replyBadgeRule': v(rr?.replyBadgeRule),
      'r_replyContentRule': v(rr?.replyContentRule),
    };
  }

  /// 从控制器收集字段，构建 [BookSource]。
  BookSource _buildSource() {
    // 文本（trim 后）
    String t(String key) => _ctrl(key).text.trim();
    // 可空文本：空串归一为 null
    String? n(String key) => t(key).isEmpty ? null : t(key);

    return BookSource(
      bookSourceName: t('bookSourceName'),
      bookSourceUrl: t('bookSourceUrl'),
      bookSourceGroup: n('bookSourceGroup'),
      bookSourceType: int.tryParse(t('bookSourceType')) ?? 0,
      header: n('header'),
      loginUrl: n('loginUrl'),
      bookSourceComment: n('bookSourceComment'),
      enabledExplore: _enabledExplore,
      // 搜索规则
      searchUrl: n('searchUrl'),
      ruleSearch: SearchRule(
        checkKeyWord: n('s_checkKeyWord'),
        bookList: n('s_bookList'),
        name: n('s_name'),
        author: n('s_author'),
        intro: n('s_intro'),
        kind: n('s_kind'),
        lastChapter: n('s_lastChapter'),
        updateTime: n('s_updateTime'),
        bookUrl: n('s_bookUrl'),
        coverUrl: n('s_coverUrl'),
        wordCount: n('s_wordCount'),
      ),
      // 发现规则
      exploreUrl: n('exploreUrl'),
      ruleExplore: ExploreRule(
        bookList: n('e_bookList'),
        name: n('e_name'),
        author: n('e_author'),
        intro: n('e_intro'),
        kind: n('e_kind'),
        lastChapter: n('e_lastChapter'),
        updateTime: n('e_updateTime'),
        bookUrl: n('e_bookUrl'),
        coverUrl: n('e_coverUrl'),
        wordCount: n('e_wordCount'),
      ),
      // 详情规则
      ruleBookInfo: BookInfoRule(
        init: n('i_init'),
        name: n('i_name'),
        author: n('i_author'),
        intro: n('i_intro'),
        kind: n('i_kind'),
        lastChapter: n('i_lastChapter'),
        updateTime: n('i_updateTime'),
        coverUrl: n('i_coverUrl'),
        tocUrl: n('i_tocUrl'),
        wordCount: n('i_wordCount'),
        canReName: n('i_canReName'),
        downloadUrls: n('i_downloadUrls'),
      ),
      // 目录规则
      ruleToc: TocRule(
        preUpdateJs: n('t_preUpdateJs'),
        chapterList: n('t_chapterList'),
        chapterName: n('t_chapterName'),
        chapterUrl: n('t_chapterUrl'),
        formatJs: n('t_formatJs'),
        isVolume: n('t_isVolume'),
        isVip: n('t_isVip'),
        isPay: n('t_isPay'),
        updateTime: n('t_updateTime'),
        nextTocUrl: n('t_nextTocUrl'),
      ),
      // 内容规则
      ruleContent: ContentRule(
        content: n('c_content'),
        subContent: n('c_subContent'),
        title: n('c_title'),
        nextContentUrl: n('c_nextContentUrl'),
        webJs: n('c_webJs'),
        sourceRegex: n('c_sourceRegex'),
        replaceRegex: n('c_replaceRegex'),
        imageStyle: n('c_imageStyle'),
        imageDecode: n('c_imageDecode'),
        payAction: n('c_payAction'),
        callBackJs: n('c_callBackJs'),
      ),
      // 评论规则
      ruleReview: ReviewRule(
        enabled: _reviewEnabled,
        reviewUrl: n('r_reviewUrl'),
        avatarRule: n('r_avatarRule'),
        contentRule: n('r_contentRule'),
        postTimeRule: n('r_postTimeRule'),
        reviewQuoteUrl: n('r_reviewQuoteUrl'),
        voteUpUrl: n('r_voteUpUrl'),
        voteDownUrl: n('r_voteDownUrl'),
        postReviewUrl: n('r_postReviewUrl'),
        postQuoteUrl: n('r_postQuoteUrl'),
        deleteUrl: n('r_deleteUrl'),
        reviewSummaryUrl: n('r_reviewSummaryUrl'),
        summaryListRule: n('r_summaryListRule'),
        summaryParagraphIndexRule: n('r_summaryParagraphIndexRule'),
        summaryParagraphDataRule: n('r_summaryParagraphDataRule'),
        summaryCountRule: n('r_summaryCountRule'),
        reviewDetailUrl: n('r_reviewDetailUrl'),
        reviewDetailNextPageUrl: n('r_reviewDetailNextPageUrl'),
        detailListRule: n('r_detailListRule'),
        detailIdRule: n('r_detailIdRule'),
        detailAvatarRule: n('r_detailAvatarRule'),
        detailNameRule: n('r_detailNameRule'),
        detailBadgeRule: n('r_detailBadgeRule'),
        detailContentRule: n('r_detailContentRule'),
        replyListRule: n('r_replyListRule'),
        replyIdRule: n('r_replyIdRule'),
        replyAvatarRule: n('r_replyAvatarRule'),
        replyNameRule: n('r_replyNameRule'),
        replyBadgeRule: n('r_replyBadgeRule'),
        replyContentRule: n('r_replyContentRule'),
      ),
    );
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() => _saving = true);
    try {
      final source = _buildSource();
      final notifier = ref.read(sourceNotifierProvider.notifier);
      await notifier.saveSource(source);
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(isNew ? '书源已创建' : '书源已保存')));
        Navigator.of(context).pop();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('保存失败：$e')));
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
      final notifier = ref.read(sourceNotifierProvider.notifier);
      await notifier.saveSource(source);

      if (!mounted) return;
      final api = ref.read(bookApiProvider);
      final results = await api.searchBooks(
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
                              ? Colors.green.withValues(alpha: 0.12)
                              : Theme.of(ctx).colorScheme.errorContainer,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                            color: _validateSuccess
                                ? Colors.green.withValues(alpha: 0.5)
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
                                        ? (Theme.of(ctx).brightness ==
                                                  Brightness.dark
                                              ? Colors.green.shade300
                                              : Colors.green.shade800)
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
                                      const SnackBar(content: Text('已复制到剪贴板')),
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
      final notifier = ref.read(sourceNotifierProvider.notifier);
      await notifier.saveSource(source);

      final sourceJson = jsonEncode(source.toJson());
      final api = ref.read(bookApiProvider);
      String result;

      switch (type) {
        case 'search':
          // 搜索验证
          result = await api.webbookSearch(sourceJson, url, 1);
        case 'info':
          // 书籍详情验证
          result = await api.webbookInfo(sourceJson, url);
        case 'chapters':
          // 章节目录验证
          result = await api.webbookChapters(sourceJson, url);
        case 'content':
          // 章节内容验证
          result = await api.webbookContent(sourceJson, url);
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
      length: 8,
      child: Scaffold(
        appBar: AppBar(
          title: Text(isNew ? '新建书源' : '编辑书源'),
          bottom: const TabBar(
            isScrollable: true,
            // 页签文案对齐原版 source_tab_* 短标签
            tabs: [
              Tab(text: '基本'),
              Tab(text: '搜索'),
              Tab(text: '发现'),
              Tab(text: '详情'),
              Tab(text: '目录'),
              Tab(text: '正文'),
              Tab(text: '段评'),
              Tab(text: '调试'),
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
              onPressed: () => Navigator.pushNamed(context, AppRoutes.dict),
            ),
            TextButton.icon(
              // AppBar 为 primary 底色，TextButton 默认 primary 前景会蓝底蓝字不可见，
              // 显式使用 onPrimary（白）对齐 AppBar 前景色。
              style: TextButton.styleFrom(
                foregroundColor: Theme.of(context).colorScheme.onPrimary,
              ),
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
              _buildFormTab(_basicFields),
              _buildFormTab(_searchFields),
              _buildFormTab(
                _exploreFields,
                leading: [
                  SwitchListTile(
                    title: const Text('启用发现'),
                    subtitle: const Text('关闭后书架发现页不显示该书源'),
                    value: _enabledExplore,
                    onChanged: (value) =>
                        setState(() => _enabledExplore = value),
                  ),
                  const Divider(),
                ],
              ),
              _buildFormTab(_infoFields),
              _buildFormTab(_tocFields),
              _buildFormTab(_contentFields),
              _buildFormTab(
                _reviewFields,
                leading: [
                  SwitchListTile(
                    title: const Text('启用段评'),
                    subtitle: const Text('开启后阅读页展示该书源段评'),
                    value: _reviewEnabled,
                    onChanged: (value) =>
                        setState(() => _reviewEnabled = value),
                  ),
                  const Divider(),
                ],
              ),
              _buildTestTab(),
            ],
          ),
        ),
      ),
    );
  }

  /// 通用表单 Tab：按字段列表构建 [TextFormField]
  Widget _buildFormTab(List<_Field> fields, {List<Widget> leading = const []}) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [...leading, for (final field in fields) _buildField(field)],
    );
  }

  /// 构建单个表单字段
  Widget _buildField(_Field field) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextFormField(
        controller: _ctrl(field.key),
        maxLines: field.maxLines,
        keyboardType: field.keyboardType,
        decoration: InputDecoration(
          labelText: field.required ? '${field.label} *' : field.label,
          hintText: field.hint,
          border: const OutlineInputBorder(),
        ),
        validator: field.required
            ? (value) => (value == null || value.trim().isEmpty)
                  ? '请输入${field.label}'
                  : null
            : null,
      ),
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
          const Expanded(child: Center(child: Text('输入关键词测试书源搜索功能')))
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
