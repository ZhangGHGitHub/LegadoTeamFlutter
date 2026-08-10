import 'dart:convert';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/models.dart';
import '../providers/providers.dart';
import '../providers/source/source_notifier.dart';
import '../routes.dart';
import '../widgets/loading_indicator.dart';
import 'source_login_screen.dart';

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

  const _Field(
    this.key,
    this.label, {
    this.hint,
    this.maxLines = 2,
    this.required = false,
  });
}

class _SourceEditScreenState extends ConsumerState<SourceEditScreen> {
  final _formKey = GlobalKey<FormState>();
  bool _saving = false;

  /// 首次帮助已展示标志（对标原版 LocalConfig.ruleHelpVersionIsLast）
  static const _ruleHelpShownKey = 'source_rule_help_shown';

  /// 自动补全开关（对标原版 menu_auto_complete，会话级）
  bool _autoComplete = false;

  /// 所有文本字段控制器（按 key 惰性创建）
  final Map<String, TextEditingController> _ctrls = {};

  // 开关状态（非文本字段，对标原版可折叠「设置」面板）
  bool _enabled = true;
  bool _enabledExplore = true;
  bool _reviewEnabled = false;
  bool _cookieJar = false;
  bool _eventListener = false;
  bool _customButton = false;
  int _bookSourceType = 0;

  // 测试
  final _testKeywordCtrl = TextEditingController();
  bool _testing = false;
  List<SearchResult> _testResults = [];
  String? _testError;

  /// 被编辑书源既有的自定义变量（评审 C1：表单不含 variable 字段，
  /// 保存时透传此值避免编辑任意书源一次即抹掉已设置的源变量；
  /// 粘贴/扫码/全屏编辑回填时随 _populateFields 同步更新）
  String _preservedVariable = '';

  bool get isNew => widget.sourceUrl == null;

  /// 按 key 惰性获取控制器
  TextEditingController _ctrl(String key) =>
      _ctrls.putIfAbsent(key, () => TextEditingController());

  /// 书源类型（对标原版 sp_type / @array/source_type）
  static const _typeLabels = ['文本', '音频', '图片', '文件', '视频'];

  // ─── 基本信息字段 ───────────────────────────────────────
  static const _basicFields = [
    _Field('bookSourceName', '书源名称', required: true, maxLines: 1),
    _Field('bookSourceUrl', '书源 URL', required: true, maxLines: 1),
    _Field('bookSourceGroup', '分组', maxLines: 1),
    _Field('header', '请求头', hint: 'JSON 格式', maxLines: 3),
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
    // 对标原版 BookSourceEditActivity.onPostCreate：
    // if (!LocalConfig.ruleHelpVersionIsLast) showHelp("ruleHelp")
    _maybeShowFirstHelp();
  }

  /// 首次打开编辑页自动弹出规则帮助（对标原版 ruleHelpVersionIsLast 标志）
  Future<void> _maybeShowFirstHelp() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getBool(_ruleHelpShownKey) ?? false) return;
      await prefs.setBool(_ruleHelpShownKey, true);
      if (!mounted) return;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _showHelp();
      });
    } catch (_) {
      // 偏好存储异常不阻断编辑流程
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
    // 评审 C1：同步记录既有 variable，_buildSource 时透传不抹掉
    _preservedVariable = source.variable;
    _enabled = source.enabled;
    _enabledExplore = source.enabledExplore;
    _reviewEnabled = source.ruleReview?.enabled ?? false;
    _cookieJar = source.enabledCookieJar ?? false;
    _eventListener = source.eventListener;
    _customButton = source.customButton;
    _bookSourceType =
        source.bookSourceType.clamp(0, _typeLabels.length - 1);
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
      bookSourceType: _bookSourceType,
      enabled: _enabled,
      enabledCookieJar: _cookieJar,
      eventListener: _eventListener,
      customButton: _customButton,
      header: n('header'),
      loginUrl: n('loginUrl'),
      bookSourceComment: n('bookSourceComment'),
      // 评审 C1：透传被编辑书源既有 variable（表单不编辑此字段，
      // 避免保存时把已设置的源变量抹掉为空串）
      variable: _preservedVariable,
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

  /// overflow 菜单分流（对标原版 source_edit.xml 折叠项）
  Future<void> _handleMenu(String value) async {
    switch (value) {
      case 'login':
        _openLogin();
      case 'search':
        _todo('搜索');
      case 'clear_cookie':
        _todo('清除 Cookie');
      case 'auto_complete':
        setState(() => _autoComplete = !_autoComplete);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(_autoComplete ? '自动补全已开启' : '自动补全已关闭'),
          ),
        );
      case 'copy_source':
        await _copySource();
      case 'paste_source':
        await _pasteSource();
      case 'set_source_variable':
        _todo('设置源变量');
      case 'import_qr':
        await _importFromQr();
      case 'share_qr':
        _todo('二维码分享');
      case 'share_str':
        await _shareSource();
      case 'log':
        // [UI-fix v2.0.1 | 2026-08-06] 日志菜单接通 AppLogScreen（对标原版 menu_log → AppLogDialog） — Qoder
        Navigator.pushNamed(context, AppRoutes.appLog);
      case 'help':
        _showHelp();
    }
  }

  /// 待 FFI 层支持的原版功能占位提示
  void _todo(String feature) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('「$feature」功能开发中')),
    );
  }

  /// 登录（对标原版 menu_login → SourceLoginActivity）
  void _openLogin() {
    final loginUrl = _ctrl('loginUrl').text.trim();
    if (loginUrl.isEmpty) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => SourceLoginScreen(
          sourceUrl: _ctrl('bookSourceUrl').text.trim(),
          sourceName: _ctrl('bookSourceName').text.trim(),
          loginUrl: loginUrl,
        ),
      ),
    );
  }

  /// 拷贝源（对标原版 menu_copy_source：JSON 写入剪贴板）
  Future<void> _copySource() async {
    final json = const JsonEncoder.withIndent(
      '  ',
    ).convert(_buildSource().toJson());
    await Clipboard.setData(ClipboardData(text: json));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('已复制到剪贴板')),
    );
  }

  /// 粘贴源（对标原版 menu_paste_source：解析剪贴板 JSON 回填表单）
  Future<void> _pasteSource() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim();
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    if (text == null || text.isEmpty) {
      messenger.showSnackBar(const SnackBar(content: Text('剪贴板为空')));
      return;
    }
    try {
      final decoded = jsonDecode(text);
      final map = decoded is List
          ? decoded.first as Map<String, dynamic>
          : decoded as Map<String, dynamic>;
      final source = BookSource.fromJson(map);
      _populateFields(source);
      messenger.showSnackBar(
        SnackBar(content: Text('已粘贴书源：${source.bookSourceName}')),
      );
    } catch (_) {
      messenger.showSnackBar(
        const SnackBar(content: Text('剪贴板内容不是有效的书源 JSON')),
      );
    }
  }

  /// 字符串分享（对标原版 menu_share_str）
  Future<void> _shareSource() async {
    try {
      final json = jsonEncode(_buildSource().toJson());
      await Share.share(json, subject: '书源分享');
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('分享失败：$e')),
      );
    }
  }

  /// 二维码导入（对标原版 menu_qr_code_camera：扫码内容解析回填表单）
  Future<void> _importFromQr() async {
    // [fix Task#24 | 2026-08-08] 去掉 <String> 泛型，避免 routes 表
    // MaterialPageRoute<dynamic> 运行时强转崩溃 — Qoder
    final raw = await Navigator.of(context).pushNamed(AppRoutes.qrcode);
    final content = raw is String ? raw : null;
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    if (content == null || content.trim().isEmpty) return;

    final trimmed = content.trim();
    if (trimmed.startsWith('[') || trimmed.startsWith('{')) {
      try {
        final decoded = jsonDecode(trimmed);
        final map = decoded is List
            ? decoded.first as Map<String, dynamic>
            : decoded as Map<String, dynamic>;
        final source = BookSource.fromJson(map);
        _populateFields(source);
        messenger.showSnackBar(
          SnackBar(content: Text('已导入书源：${source.bookSourceName}')),
        );
      } catch (_) {
        messenger.showSnackBar(
          const SnackBar(content: Text('扫码内容不是有效的书源 JSON')),
        );
      }
      return;
    }

    if (trimmed.startsWith('legado://')) {
      messenger.showSnackBar(
        const SnackBar(content: Text('legado 协议链接请使用「关联导入」页处理')),
      );
      return;
    }

    messenger.showSnackBar(
      const SnackBar(content: Text('URL 内容请使用书源管理页的网络导入处理')),
    );
  }

  /// 显示规则帮助（对标原版 showHelp("ruleHelp")）
  void _showHelp() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => const _RuleHelpSheet(),
    );
  }

  /// 调试源（对标原版 menu_debug_source：保存后进入源调试页）
  Future<void> _debugSource() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _saving = true);
    try {
      final source = _buildSource();
      final notifier = ref.read(sourceNotifierProvider.notifier);
      await notifier.saveSource(source);
      if (!mounted) return;
      Navigator.of(context).pushNamed(
        AppRoutes.sourceDebug,
        arguments: source.bookSourceUrl,
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('调试失败：$e')),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// 全屏编辑（对标原版 menu_fullscreen_edit：整体编辑书源 JSON）
  Future<void> _showFullscreenEdit() async {
    // controller 由对话框内容组件自持（随子树卸载释放，
    // 避免退场动画期间 dispose 引发框架断言）；
    // 关闭返回 null，应用返回编辑后的 JSON 文本
    final text = await showDialog<String>(
      context: context,
      builder: (_) => _FullscreenJsonEditDialog(
        initialText: const JsonEncoder.withIndent(
          '  ',
        ).convert(_buildSource().toJson()),
      ),
    );
    if (text == null || !mounted) return;
    try {
      final source = BookSource.fromJson(
        jsonDecode(text) as Map<String, dynamic>,
      );
      _populateFields(source);
    } catch (_) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('JSON 格式错误，未应用修改')),
      );
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
            // 全屏编辑（对标原版 menu_fullscreen_edit，always）
            IconButton(
              icon: const Icon(Icons.code),
              tooltip: '全屏编辑',
              onPressed: _showFullscreenEdit,
            ),
            // 调试源（对标原版 menu_debug_source，always）
            IconButton(
              icon: const Icon(Icons.bug_report),
              tooltip: '调试源',
              onPressed: _saving ? null : _debugSource,
            ),
            // 保存（对标原版 menu_save，always）
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
            // overflow 菜单（对标原版 source_edit.xml 折叠项）
            PopupMenuButton<String>(
              tooltip: '更多选项',
              // 菜单在顶栏下方展开，不覆盖顶栏
              position: PopupMenuPosition.under,
              onSelected: _handleMenu,
              itemBuilder: (_) => [
                // 登录（对标 menu_login：仅在配置了登录 URL 时显示）
                if (_ctrl('loginUrl').text.trim().isNotEmpty)
                  const PopupMenuItem(
                    value: 'login',
                    child: Text('登录'),
                  ),
                const PopupMenuItem(value: 'search', child: Text('搜索')),
                const PopupMenuItem(
                  value: 'clear_cookie',
                  child: Text('清除 Cookie'),
                ),
                CheckedPopupMenuItem(
                  value: 'auto_complete',
                  checked: _autoComplete,
                  child: const Text('自动补全'),
                ),
                const PopupMenuItem(
                  value: 'copy_source',
                  child: Text('拷贝源'),
                ),
                const PopupMenuItem(
                  value: 'paste_source',
                  child: Text('粘贴源'),
                ),
                const PopupMenuItem(
                  value: 'set_source_variable',
                  child: Text('设置源变量'),
                ),
                const PopupMenuItem(
                  value: 'import_qr',
                  child: Text('二维码导入'),
                ),
                const PopupMenuItem(
                  value: 'share_qr',
                  child: Text('二维码分享'),
                ),
                const PopupMenuItem(
                  value: 'share_str',
                  child: Text('字符串分享'),
                ),
                const PopupMenuItem(value: 'log', child: Text('日志')),
                const PopupMenuItem(value: 'help', child: Text('帮助')),
              ],
            ),
          ],
        ),
        body: Form(
          key: _formKey,
          child: Column(
            children: [
              // 可折叠「设置」面板（对标原版：类型 + 启用/发现/CookieJar/
              // 段评/事件监听/定制按钮）
              _buildSettingsPanel(),
              Expanded(
                child: TabBarView(
                  children: [
                    _buildFormTab(_basicFields),
                    _buildFormTab(_searchFields),
                    _buildFormTab(_exploreFields),
                    _buildFormTab(_infoFields),
                    _buildFormTab(_tocFields),
                    _buildFormTab(_contentFields),
                    _buildFormTab(_reviewFields),
                    _buildTestTab(),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 可折叠「设置」面板（对标原版 BookSourceEditActivity 顶部设置区：
  /// 类型下拉 + 启用/发现/CookieJar/段评/事件监听/定制按钮）
  Widget _buildSettingsPanel() {
    final colorScheme = Theme.of(context).colorScheme;
    Widget checkChip(String label, bool value, ValueChanged<bool> onChanged) {
      return SizedBox(
        width: 132,
        child: CheckboxListTile(
          dense: true,
          controlAffinity: ListTileControlAffinity.leading,
          contentPadding: EdgeInsets.zero,
          title: Text(label, style: const TextStyle(fontSize: 14)),
          value: value,
          onChanged: (v) => setState(() => onChanged(v ?? false)),
        ),
      );
    }

    return ExpansionTile(
      initiallyExpanded: true,
      tilePadding: const EdgeInsets.symmetric(horizontal: 16),
      shape: const Border(),
      collapsedShape: const Border(),
      title: const Text('设置',
          style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
          child: Row(
            children: [
              Text('类型', style: TextStyle(color: colorScheme.onSurface)),
              const SizedBox(width: 8),
              DropdownButton<int>(
                value: _bookSourceType,
                isDense: true,
                onChanged: (v) => setState(() => _bookSourceType = v ?? 0),
                items: [
                  for (var i = 0; i < _typeLabels.length; i++)
                    DropdownMenuItem(value: i, child: Text(_typeLabels[i])),
                ],
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Wrap(
            children: [
              checkChip('启用', _enabled, (v) => _enabled = v),
              checkChip('发现', _enabledExplore, (v) => _enabledExplore = v),
              checkChip('CookieJar', _cookieJar, (v) => _cookieJar = v),
              checkChip('段评', _reviewEnabled, (v) => _reviewEnabled = v),
              checkChip('事件监听', _eventListener, (v) => _eventListener = v),
              checkChip('定制按钮', _customButton, (v) => _customButton = v),
            ],
          ),
        ),
        const Divider(height: 1),
      ],
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

/// 书源规则帮助内容（对标原版 assets/web/help/md/ruleHelp.md 精简版）
const String _ruleHelpContent = '''
* [阅读3.0(Legado)规则说明](https://mgz0227.github.io/The-tutorial-of-Legado/)
* [书源帮助文档](https://mgz0227.github.io/The-tutorial-of-Legado/Rule/source.html)
* [订阅源帮助文档](https://mgz0227.github.io/The-tutorial-of-Legado/Rule/rss.html)
* 辅助键盘中可插入URL参数模板,打开帮助,js教程,正则教程,选择文件

## 基础配置
* 规则标志, {{......}}内使用规则必须有明显的规则标志,没有规则标志当作js执行
```
@@ 默认规则,直接写时可以省略@@
@XPath: xpath规则,直接写时以//开头可省略@XPath
@Json: json规则,直接写时以\$.开头可省略@Json
: regex规则,不可省略,只可以用在书籍列表和目录列表
```
* jsLib
> 注入JavaScript到RhinoJs引擎中，支持两种格式，可实现[函数共用](https://github.com/LegadoTeam/legado/wiki/JavaScript%E5%87%BD%E6%95%B0%E5%85%B1%E7%94%A8)
> `JavaScript Code` 直接填写JavaScript片段
> `{"example":"https://www.example.com/js/example.js", ...}` 自动复用已经下载的js文件
> 注意此处定义的函数可能会被多个线程同时调用，函数内声明全局变量必须使用var
* 并发率
> 并发限制，单位ms，可填写两种格式
> `1000` 访问间隔1s
> `20/60000` 60s内访问次数20
* 书源类型: 文件
> 对于提供文件整合下载的网站，可以在书源详情的下载URL规则获取文件链接
* 书源类型: 音频
> 将正文获得的字符串作为音频链接，返回序列化后的链接数组会将多个链接拼接成一条音频
* CookieJar
> 启用后会自动保存每次返回头中的Set-Cookie中的值，适用于需要session的网站

## 登录
* 登录UI
> 不使用内置webView登录网站，需要使用`登录URL`规则实现登录逻辑，可使用`登录检查JS`检查登录结果
> 按钮支持调用`登录URL`规则里面的函数，必须实现`login`函数
* 登录URL
> 填写登录页面地址或登录逻辑，打开登录界面时执行

## 发现
* 发现URL
> 支持多行`分类名::url`格式，可返回字符串、数组、Map等
> 支持 <js></js> 与 @js: 追加 js 处理

## 请求与URL参数
* URL参数模板
> {{key, value}} 以JSON对象形式添加请求头/请求体参数
* 常用选项
> charset: 指定响应编码；method: GET/POST；body: 请求体
> headers: 自定义请求头；retry: 重试次数；webview: 使用webview加载

## 正文处理
* 正文内容
> 支持规则、js、正则替换，可使用 <js></js> 组合多种规则
* 替换正则
> 对正文结果做正则替换
* 图片样式 / 图片解码
> 控制正文图片展示方式与自定义解码逻辑

## 回调事件
* 回调 JS
> 翻页/加载完成等事件触发的 js 回调
''';

/// 规则帮助 sheet（对标原版 showHelp 弹窗，轻量 markdown 渲染：
/// ## 标题 / * 列表 / > 引用 / ``` 代码块 / [链接](url)）
class _RuleHelpSheet extends StatefulWidget {
  const _RuleHelpSheet();

  @override
  State<_RuleHelpSheet> createState() => _RuleHelpSheetState();
}

class _RuleHelpSheetState extends State<_RuleHelpSheet> {
  final List<TapGestureRecognizer> _recognizers = [];

  @override
  void dispose() {
    for (final r in _recognizers) {
      r.dispose();
    }
    super.dispose();
  }

  InlineSpan _linkSpan(String label, String url) {
    final recognizer = TapGestureRecognizer()
      ..onTap = () async {
        final uri = Uri.tryParse(url);
        if (uri == null) return;
        try {
          await launchUrl(uri, mode: LaunchMode.externalApplication);
        } catch (_) {
          // 打开失败静默处理
        }
      };
    _recognizers.add(recognizer);
    return TextSpan(
      text: label,
      style: TextStyle(color: Theme.of(context).colorScheme.primary),
      recognizer: recognizer,
    );
  }

  /// 行内解析 [label](url) 链接
  InlineSpan _renderInline(String text) {
    final spans = <InlineSpan>[];
    final regex = RegExp(r'\[(.+?)\]\((https?://[^)\s]+)\)');
    var last = 0;
    for (final m in regex.allMatches(text)) {
      if (m.start > last) {
        spans.add(TextSpan(text: text.substring(last, m.start)));
      }
      spans.add(_linkSpan(m.group(1)!, m.group(2)!));
      last = m.end;
    }
    if (last < text.length) {
      spans.add(TextSpan(text: text.substring(last)));
    }
    return TextSpan(children: spans);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return SizedBox(
      height: MediaQuery.of(context).size.height * 0.85,
      child: Column(
        children: [
          // iOS 风格抓手
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: colorScheme.outlineVariant,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Text('书源规则帮助', style: theme.textTheme.titleLarge),
          ),
          Divider(height: 1, color: colorScheme.outlineVariant),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
              children: _buildHelpLines(theme, colorScheme),
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _buildHelpLines(ThemeData theme, ColorScheme colorScheme) {
    final result = <Widget>[];
    var inCode = false;
    final codeLines = <String>[];
    for (final raw in _ruleHelpContent.split('\n')) {
      final line = raw.trimRight();
      if (line.trim() == '```') {
        if (inCode) {
          result.add(
            Container(
              width: double.maxFinite,
              margin: const EdgeInsets.only(bottom: 8, left: 4),
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8),
              ),
              child: SelectableText(
                codeLines.join('\n'),
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              ),
            ),
          );
          codeLines.clear();
          inCode = false;
        } else {
          inCode = true;
        }
        continue;
      }
      if (inCode) {
        codeLines.add(raw);
        continue;
      }
      if (line.trim().isEmpty) continue;
      if (line.startsWith('## ')) {
        result.add(
          Padding(
            padding: const EdgeInsets.only(top: 16, bottom: 6),
            child: Text(
              line.substring(3),
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        );
      } else if (line.startsWith('* ')) {
        result.add(
          Padding(
            padding: const EdgeInsets.only(bottom: 6, left: 4),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('• '),
                Expanded(child: Text.rich(_renderInline(line.substring(2)))),
              ],
            ),
          ),
        );
      } else if (line.startsWith('> ')) {
        result.add(
          Padding(
            padding: const EdgeInsets.only(bottom: 4, left: 16),
            child: Text.rich(
              _renderInline(line.substring(2)),
              style: TextStyle(
                color: colorScheme.onSurfaceVariant,
                fontSize: 13,
              ),
            ),
          ),
        );
      } else {
        result.add(
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Text.rich(_renderInline(line)),
          ),
        );
      }
    }
    return result;
  }
}

/// 全屏 JSON 编辑对话框：controller 生命周期绑定对话框子树，
/// 随子树卸载统一释放（避免退场动画期间 dispose 引发框架断言）
class _FullscreenJsonEditDialog extends StatefulWidget {
  final String initialText;

  const _FullscreenJsonEditDialog({required this.initialText});

  @override
  State<_FullscreenJsonEditDialog> createState() =>
      _FullscreenJsonEditDialogState();
}

class _FullscreenJsonEditDialogState
    extends State<_FullscreenJsonEditDialog> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.initialText);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Dialog.fullscreen(
      child: Scaffold(
        appBar: AppBar(
          title: const Text('全屏编辑'),
          leading: IconButton(
            icon: const Icon(Icons.close),
            tooltip: '关闭',
            onPressed: () => Navigator.pop(context),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, _controller.text),
              child: const Text('应用'),
            ),
          ],
        ),
        body: Padding(
          padding: const EdgeInsets.all(12),
          child: TextField(
            controller: _controller,
            maxLines: null,
            expands: true,
            textAlignVertical: TextAlignVertical.top,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
            ),
          ),
        ),
      ),
    );
  }
}
