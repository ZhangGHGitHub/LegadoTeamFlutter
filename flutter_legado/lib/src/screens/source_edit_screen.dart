import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import '../widgets/legado_app_bar.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:path_provider/path_provider.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/models.dart';
import '../providers/explore/explore_notifier.dart';
import '../providers/providers.dart';
import '../providers/search/search_notifier.dart';
import '../providers/source/source_notifier.dart';
import '../routes.dart';
import '../utils/source_login_entry.dart';
import '../widgets/help/help_assets.dart';
import '../widgets/help/show_help.dart';
import 'code_edit_screen.dart';

/// 书源编辑页面
///
/// 对标 Android `BookSourceEditActivity`，采用多 Tab 表单编辑书源的全部规则：
/// 基本信息 / 搜索规则 / 发现规则 / 详情规则 / 目录规则 / 内容规则 / 评论规则 / 测试。
/// 表单字段以数据驱动方式定义（[_Field] 列表），controller 按 key 惰性创建，
/// 与原版基于 `EditEntity` 列表的配置化编辑思路一致。
class SourceEditScreen extends ConsumerStatefulWidget {
  /// 书源 URL（编辑模式），null 表示新建
  final String? sourceUrl;

  /// 书源对象（发现页编辑入口直接传入，避免依赖 notifier 已加载
  /// 内存书源列表导致空表单）— DeepSeek Harness + UI（2026-08-14）
  final BookSource? source;

  const SourceEditScreen({super.key, this.sourceUrl, this.source});

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
  final Map<String, FocusNode> _focusNodes = {};
  String? _focusedFieldKey;
  final Map<String, String> _fieldLabels = {};

  // 开关状态（非文本字段，对标原版可折叠「设置」面板）
  bool _enabled = true;
  bool _enabledExplore = true;
  bool _reviewEnabled = false;
  bool _cookieJar = false;
  bool _eventListener = false;
  bool _customButton = false;
  int _bookSourceType = 0;

  /// 被编辑书源既有的自定义变量（评审 C1：表单不含 variable 字段，
  /// 保存时透传此值避免编辑任意书源一次即抹掉已设置的源变量；
  /// 粘贴/扫码/全屏编辑回填时随 _populateFields 同步更新）
  String _preservedVariable = '';

  /// 被编辑书源的原始对象（表单未展示字段透传，保存不丢数据）
  BookSource? _originalSource;

  bool get isNew => widget.sourceUrl == null && widget.source == null;

  /// 按 key 惰性获取控制器
  TextEditingController _ctrl(String key) =>
      _ctrls.putIfAbsent(key, () => TextEditingController());

  FocusNode _focus(String key) => _focusNodes.putIfAbsent(
    key,
    () => FocusNode()..addListener(() {
      if (_focusNodes[key]?.hasFocus == true) {
        _focusedFieldKey = key;
      }
    }),
  );

  /// 书源类型（对标原版 sp_type / @array/source_type）
  static const _typeLabels = ['文本', '音频', '图片', '文件', '视频'];

  // ─── 基本信息字段（对齐原版 BookSourceEditActivity sourceEntities 顺序/标签） ───
  static const _basicFields = [
    _Field('bookSourceUrl', '源 URL（sourceUrl）', required: true, maxLines: 1),
    _Field('bookSourceName', '源名称（sourceName）', required: true, maxLines: 1),
    _Field('bookSourceGroup', '源分组（sourceGroup）', maxLines: 1),
    _Field('bookSourceComment', '源注释（sourceComment）', maxLines: 3),
    _Field('loginUrl', '登录 URL(loginUrl)', maxLines: 3),
    _Field('loginUi', '登录 UI（loginUi）', maxLines: 4),
    _Field('loginCheckJs', '登录检查 JS（loginCheckJs）', maxLines: 4),
    _Field('coverDecodeJs', '封面解密（coverDecodeJs）', maxLines: 4),
    _Field('bookUrlPattern', '书籍 URL 正则（bookUrlPattern）', maxLines: 2),
    _Field('header', '请求头（header）', hint: 'JSON 格式', maxLines: 3),
    _Field('variableComment', '变量说明(variableComment)', maxLines: 2),
    _Field('concurrentRate', '并发率（concurrentRate）', maxLines: 1),
    _Field('jsLib', 'jsLib', maxLines: 8),
  ];

  // ─── 搜索规则字段（对齐原版 searchEntities 顺序/标签） ──────────
  static const _searchFields = [
    _Field(
      'searchUrl',
      '搜索地址（url）',
      maxLines: 1,
      hint: '例如：https://example.com/search?q=searchKey',
    ),
    _Field('s_checkKeyWord', '校验关键字（checkKeyWord）'),
    _Field('s_bookList', '书籍列表规则（bookList）'),
    _Field('s_name', '书名规则（name）'),
    _Field('s_author', '作者规则（author）'),
    _Field('s_kind', '分类规则（kind）'),
    _Field('s_wordCount', '字数规则（wordCount）'),
    _Field('s_lastChapter', '最新章节规则（lastChapter）'),
    _Field('s_intro', '简介规则（intro）'),
    _Field('s_coverUrl', '封面规则（coverUrl）'),
    _Field('s_bookUrl', '详情页 URL 规则（bookUrl）'),
  ];

  // ─── 发现规则字段（对齐原版 exploreEntities 顺序/标签） ──────────
  static const _exploreFields = [
    _Field(
      'exploreUrl',
      '发现地址规则（url）',
      maxLines: 3,
      hint: '例如：分类名::https://example.com/sort\n或 url 形式',
    ),
    _Field('e_bookList', '书籍列表规则（bookList）'),
    _Field('e_name', '书名规则（name）'),
    _Field('e_author', '作者规则（author）'),
    _Field('e_kind', '分类规则（kind）'),
    _Field('e_wordCount', '字数规则（wordCount）'),
    _Field('e_lastChapter', '最新章节规则（lastChapter）'),
    _Field('e_intro', '简介规则（intro）'),
    _Field('e_coverUrl', '封面规则（coverUrl）'),
    _Field('e_bookUrl', '详情页 URL 规则（bookUrl）'),
  ];

  // ─── 详情规则字段（对齐原版 infoEntities 顺序/标签） ─────────────
  static const _infoFields = [
    _Field('i_init', '预处理规则（bookInfoInit）'),
    _Field('i_name', '书名规则（name）'),
    _Field('i_author', '作者规则（author）'),
    _Field('i_kind', '分类规则（kind）'),
    _Field('i_wordCount', '字数规则（wordCount）'),
    _Field('i_lastChapter', '最新章节规则（lastChapter）'),
    _Field('i_intro', '简介规则（intro）'),
    _Field('i_coverUrl', '封面规则（coverUrl）'),
    _Field('i_tocUrl', '目录 URL 规则（tocUrl）'),
    _Field('i_canReName', '允许修改书名作者（canReName）'),
    _Field('i_downloadUrls', '下载URL规则(downloadUrls)'),
  ];

  // ─── 目录规则字段（对齐原版 tocEntities 顺序/标签） ─────────────
  static const _tocFields = [
    _Field('t_preUpdateJs', '更新之前 JS（preUpdateJs）'),
    _Field('t_chapterList', '目录列表规则（chapterList）'),
    _Field('t_chapterName', '章节名称规则（ChapterName）'),
    _Field('t_chapterUrl', '章节 URL 规则（chapterUrl）'),
    _Field('t_formatJs', '格式化规则(formatJs)'),
    _Field('t_isVolume', 'Volume 标识（isVolume）'),
    _Field('t_updateTime', '章节信息（ChapterInfo）'),
    _Field('t_isVip', 'VIP 标识（isVip）'),
    _Field('t_isPay', '购买标识（isPay）'),
    _Field('t_nextTocUrl', '目录下一页规则（nextTocUrl）'),
  ];

  // ─── 正文规则字段（对齐原版 contentEntities 顺序/标签） ──────────
  static const _contentFields = [
    _Field('c_content', '正文规则（content）', maxLines: 3),
    _Field('c_nextContentUrl', '正文下一页 URL 规则（nextContentUrl）'),
    _Field('c_subContent', '副文规则（subContent）'),
    _Field('c_replaceRegex', '替换规则（replaceRegex）', maxLines: 4),
    _Field('c_title', '标题（title）'),
    _Field('c_sourceRegex', '资源正则（sourceRegex）'),
    _Field('c_imageStyle', '图片样式（imageStyle）'),
    _Field('c_imageDecode', '图片解密（imageDecode）'),
    _Field('c_webJs', 'WebView JS（webJs）', maxLines: 4),
    _Field('c_payAction', '购买操作（payAction）'),
    _Field('c_callBackJs', '回调操作（callBackJs）'),
  ];

  // ─── 段评规则字段（对齐原版 reviewEntities 顺序/标签） ───────────
  static const _reviewFields = [
    _Field('r_reviewSummaryUrl', '段评统计 URL（reviewSummaryUrl）'),
    _Field('r_summaryListRule', '段评统计列表（summaryListRule）'),
    _Field('r_summaryParagraphIndexRule', '段落索引（summaryParagraphIndexRule）'),
    _Field('r_summaryCountRule', '段评数量（summaryCountRule）'),
    _Field('r_summaryParagraphDataRule', '段落数据（summaryParagraphDataRule）'),
    _Field('r_reviewDetailUrl', '段评详情 URL（reviewDetailUrl）'),
    _Field('r_reviewDetailNextPageUrl', '段评下一页 URL（reviewDetailNextPageUrl）'),
    _Field('r_detailListRule', '段评详情列表（detailListRule）'),
    _Field('r_detailIdRule', '段评 ID（detailIdRule）'),
    _Field('r_detailAvatarRule', '头像（detailAvatarRule）'),
    _Field('r_detailNameRule', '昵称（detailNameRule）'),
    _Field('r_detailBadgeRule', '徽章（detailBadgeRule）'),
    _Field('r_detailContentRule', '评论内容协议（detailContentRule）', maxLines: 3),
    _Field('r_reviewQuoteUrl', '段评回复URL（reviewQuoteUrl）'),
    _Field('r_replyListRule', '子评论列表（replyListRule）'),
    _Field('r_replyIdRule', '子评论 ID（replyIdRule）'),
    _Field('r_replyAvatarRule', '子评论头像（replyAvatarRule）'),
    _Field('r_replyNameRule', '子评论昵称（replyNameRule）'),
    _Field('r_replyBadgeRule', '子评论徽章（replyBadgeRule）'),
    _Field('r_replyContentRule', '子评论内容协议（replyContentRule）', maxLines: 3),
  ];

  @override
  void initState() {
    super.initState();
    // 直接传入书源对象（发现页编辑入口）时立即回填，不走内存列表查找
    final source = widget.source;
    if (source != null) {
      _populateFields(source);
      setState(() {});
    } else if (!isNew) {
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
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final notifier = ref.read(sourceNotifierProvider.notifier);
      var source = notifier.getSource(widget.sourceUrl!);
      // 内存书源列表未加载/不含该源（阅读页、听书页等直达入口）：
      // 兜底从 API 直接拉取，避免空表单（「编辑页没有任何书源信息」根因）
      if (source == null) {
        try {
          final api = ref.read(bookApiProvider);
          final sources = await api.getBookSources();
          for (final s in sources) {
            if (s.bookSourceUrl == widget.sourceUrl) {
              source = s;
              break;
            }
          }
        } catch (e) {
          debugPrint('SourceEdit 兜底加载书源失败: $e');
        }
      }
      if (!mounted) return;
      if (source != null) {
        _populateFields(source);
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('未找到书源，可能已被删除')),
        );
      }
    });
  }

  void _populateFields(BookSource source) {
    final values = _sourceToValues(source);
    values.forEach((key, value) => _ctrl(key).text = value);
    // 保存原始书源：_buildSource 时透传表单未展示字段（updateTime 等），
    // 避免保存一次编辑即抹掉既有规则数据（「修改后生效且不丢数据」）
    _originalSource = source;
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
    for (final node in _focusNodes.values) {
      node.dispose();
    }
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
      // 基本信息（对齐原版 sourceEntities）
      'bookSourceUrl': source.bookSourceUrl,
      'bookSourceName': source.bookSourceName,
      'bookSourceGroup': v(source.bookSourceGroup),
      'bookSourceComment': v(source.bookSourceComment),
      'loginUrl': v(source.loginUrl),
      'loginUi': v(source.loginUi),
      'loginCheckJs': v(source.loginCheckJs),
      'coverDecodeJs': v(source.coverDecodeJs),
      'bookUrlPattern': v(source.bookUrlPattern),
      'header': v(source.header),
      'variableComment': v(source.variableComment),
      'concurrentRate': v(source.concurrentRate),
      'jsLib': v(source.jsLib),
      // 搜索规则
      'searchUrl': v(source.searchUrl),
      's_checkKeyWord': v(sr?.checkKeyWord),
      's_bookList': v(sr?.bookList),
      's_name': v(sr?.name),
      's_author': v(sr?.author),
      's_kind': v(sr?.kind),
      's_wordCount': v(sr?.wordCount),
      's_lastChapter': v(sr?.lastChapter),
      's_intro': v(sr?.intro),
      's_coverUrl': v(sr?.coverUrl),
      's_bookUrl': v(sr?.bookUrl),
      // 发现规则
      'exploreUrl': v(source.exploreUrl),
      'e_bookList': v(er?.bookList),
      'e_name': v(er?.name),
      'e_author': v(er?.author),
      'e_kind': v(er?.kind),
      'e_wordCount': v(er?.wordCount),
      'e_lastChapter': v(er?.lastChapter),
      'e_intro': v(er?.intro),
      'e_coverUrl': v(er?.coverUrl),
      'e_bookUrl': v(er?.bookUrl),
      // 详情规则
      'i_init': v(ir?.init),
      'i_name': v(ir?.name),
      'i_author': v(ir?.author),
      'i_kind': v(ir?.kind),
      'i_wordCount': v(ir?.wordCount),
      'i_lastChapter': v(ir?.lastChapter),
      'i_intro': v(ir?.intro),
      'i_coverUrl': v(ir?.coverUrl),
      'i_tocUrl': v(ir?.tocUrl),
      'i_canReName': v(ir?.canReName),
      'i_downloadUrls': v(ir?.downloadUrls),
      // 目录规则
      't_preUpdateJs': v(tr?.preUpdateJs),
      't_chapterList': v(tr?.chapterList),
      't_chapterName': v(tr?.chapterName),
      't_chapterUrl': v(tr?.chapterUrl),
      't_formatJs': v(tr?.formatJs),
      't_isVolume': v(tr?.isVolume),
      't_updateTime': v(tr?.updateTime),
      't_isVip': v(tr?.isVip),
      't_isPay': v(tr?.isPay),
      't_nextTocUrl': v(tr?.nextTocUrl),
      // 正文规则
      'c_content': v(cr?.content),
      'c_nextContentUrl': v(cr?.nextContentUrl),
      'c_subContent': v(cr?.subContent),
      'c_replaceRegex': v(cr?.replaceRegex),
      'c_title': v(cr?.title),
      'c_sourceRegex': v(cr?.sourceRegex),
      'c_imageStyle': v(cr?.imageStyle),
      'c_imageDecode': v(cr?.imageDecode),
      'c_webJs': v(cr?.webJs),
      'c_payAction': v(cr?.payAction),
      'c_callBackJs': v(cr?.callBackJs),
      // 段评规则（对齐原版 reviewEntities）
      'r_reviewSummaryUrl': v(rr?.reviewSummaryUrl),
      'r_summaryListRule': v(rr?.summaryListRule),
      'r_summaryParagraphIndexRule': v(rr?.summaryParagraphIndexRule),
      'r_summaryCountRule': v(rr?.summaryCountRule),
      'r_summaryParagraphDataRule': v(rr?.summaryParagraphDataRule),
      'r_reviewDetailUrl': v(rr?.reviewDetailUrl),
      'r_reviewDetailNextPageUrl': v(rr?.reviewDetailNextPageUrl),
      'r_detailListRule': v(rr?.detailListRule),
      'r_detailIdRule': v(rr?.detailIdRule),
      'r_detailAvatarRule': v(rr?.detailAvatarRule),
      'r_detailNameRule': v(rr?.detailNameRule),
      'r_detailBadgeRule': v(rr?.detailBadgeRule),
      'r_detailContentRule': v(rr?.detailContentRule),
      'r_reviewQuoteUrl': v(rr?.reviewQuoteUrl),
      'r_replyListRule': v(rr?.replyListRule),
      'r_replyIdRule': v(rr?.replyIdRule),
      'r_replyAvatarRule': v(rr?.replyAvatarRule),
      'r_replyNameRule': v(rr?.replyNameRule),
      'r_replyBadgeRule': v(rr?.replyBadgeRule),
      'r_replyContentRule': v(rr?.replyContentRule),
    };
  }

  /// 从控制器收集字段，构建 [BookSource]。
  ///
  /// 对齐原版 BookSourceEditActivity.getSource：
  /// - 表单字段按 key 覆盖（空串 → null，即清空字段保存）；
  /// - 表单未展示的字段（updateTime 等）从 [_originalSource] 透传，
  ///   避免保存一次编辑即丢失既有规则数据。
  BookSource _buildSource() {
    // 文本（trim 后）
    String t(String key) => _ctrl(key).text.trim();
    // 可空文本：空串归一为 null（对齐原版 takeIf { isNotBlank }）
    String? n(String key) => t(key).isEmpty ? null : t(key);

    final orig = _originalSource;
    final oSr = orig?.ruleSearch;
    final oEr = orig?.ruleExplore;
    final oIr = orig?.ruleBookInfo;
    final oRr = orig?.ruleReview;

    return BookSource(
      bookSourceUrl: t('bookSourceUrl'),
      bookSourceName: t('bookSourceName'),
      bookSourceGroup: n('bookSourceGroup'),
      bookSourceType: _bookSourceType,
      enabled: _enabled,
      enabledCookieJar: _cookieJar,
      eventListener: _eventListener,
      customButton: _customButton,
      header: n('header'),
      loginUrl: n('loginUrl'),
      loginUi: n('loginUi'),
      loginCheckJs: n('loginCheckJs'),
      coverDecodeJs: n('coverDecodeJs'),
      bookUrlPattern: n('bookUrlPattern'),
      bookSourceComment: n('bookSourceComment'),
      variableComment: n('variableComment'),
      concurrentRate: n('concurrentRate'),
      jsLib: n('jsLib'),
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
        kind: n('s_kind'),
        wordCount: n('s_wordCount'),
        lastChapter: n('s_lastChapter'),
        intro: n('s_intro'),
        coverUrl: n('s_coverUrl'),
        bookUrl: n('s_bookUrl'),
        // 表单未展示字段透传（原版编辑页同样不展示 updateTime）
        updateTime: oSr?.updateTime,
      ),
      // 发现规则
      exploreUrl: n('exploreUrl'),
      ruleExplore: ExploreRule(
        bookList: n('e_bookList'),
        name: n('e_name'),
        author: n('e_author'),
        kind: n('e_kind'),
        wordCount: n('e_wordCount'),
        lastChapter: n('e_lastChapter'),
        intro: n('e_intro'),
        coverUrl: n('e_coverUrl'),
        bookUrl: n('e_bookUrl'),
        updateTime: oEr?.updateTime,
      ),
      // 详情规则
      ruleBookInfo: BookInfoRule(
        init: n('i_init'),
        name: n('i_name'),
        author: n('i_author'),
        kind: n('i_kind'),
        wordCount: n('i_wordCount'),
        lastChapter: n('i_lastChapter'),
        intro: n('i_intro'),
        coverUrl: n('i_coverUrl'),
        tocUrl: n('i_tocUrl'),
        canReName: n('i_canReName'),
        downloadUrls: n('i_downloadUrls'),
        updateTime: oIr?.updateTime,
      ),
      // 目录规则
      ruleToc: TocRule(
        preUpdateJs: n('t_preUpdateJs'),
        chapterList: n('t_chapterList'),
        chapterName: n('t_chapterName'),
        chapterUrl: n('t_chapterUrl'),
        formatJs: n('t_formatJs'),
        isVolume: n('t_isVolume'),
        updateTime: n('t_updateTime'),
        isVip: n('t_isVip'),
        isPay: n('t_isPay'),
        nextTocUrl: n('t_nextTocUrl'),
      ),
      // 正文规则
      ruleContent: ContentRule(
        content: n('c_content'),
        nextContentUrl: n('c_nextContentUrl'),
        subContent: n('c_subContent'),
        replaceRegex: n('c_replaceRegex'),
        title: n('c_title'),
        sourceRegex: n('c_sourceRegex'),
        imageStyle: n('c_imageStyle'),
        imageDecode: n('c_imageDecode'),
        webJs: n('c_webJs'),
        payAction: n('c_payAction'),
        callBackJs: n('c_callBackJs'),
      ),
      // 段评规则（对齐原版：仅编辑 reviewEntities 展示字段，其余透传）
      ruleReview: ReviewRule(
        enabled: _reviewEnabled,
        reviewUrl: oRr?.reviewUrl,
        avatarRule: oRr?.avatarRule,
        contentRule: oRr?.contentRule,
        postTimeRule: oRr?.postTimeRule,
        voteUpUrl: oRr?.voteUpUrl,
        voteDownUrl: oRr?.voteDownUrl,
        postReviewUrl: oRr?.postReviewUrl,
        postQuoteUrl: oRr?.postQuoteUrl,
        deleteUrl: oRr?.deleteUrl,
        reviewSummaryUrl: n('r_reviewSummaryUrl'),
        summaryListRule: n('r_summaryListRule'),
        summaryParagraphIndexRule: n('r_summaryParagraphIndexRule'),
        summaryCountRule: n('r_summaryCountRule'),
        summaryParagraphDataRule: n('r_summaryParagraphDataRule'),
        reviewDetailUrl: n('r_reviewDetailUrl'),
        reviewDetailNextPageUrl: n('r_reviewDetailNextPageUrl'),
        detailListRule: n('r_detailListRule'),
        detailIdRule: n('r_detailIdRule'),
        detailAvatarRule: n('r_detailAvatarRule'),
        detailNameRule: n('r_detailNameRule'),
        detailBadgeRule: n('r_detailBadgeRule'),
        detailContentRule: n('r_detailContentRule'),
        reviewQuoteUrl: n('r_reviewQuoteUrl'),
        replyListRule: n('r_replyListRule'),
        replyIdRule: n('r_replyIdRule'),
        replyAvatarRule: n('r_replyAvatarRule'),
        replyNameRule: n('r_replyNameRule'),
        replyBadgeRule: n('r_replyBadgeRule'),
        replyContentRule: n('r_replyContentRule'),
      ),
    );
  }

  /// 保存成功后刷新发现页书源缓存（对齐原版 setResult(RESULT_OK) 语义：
  /// 上层页面感知书源变更，立即反映新名称/开关等，避免内存旧对象
  /// 再次打开编辑页把已保存修改回退）
  void _afterSaveRefresh() {
    try {
      ref.read(exploreNotifierProvider.notifier).refresh();
    } catch (_) {}
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() => _saving = true);
    try {
      final source = _buildSource();
      final notifier = ref.read(sourceNotifierProvider.notifier);
      await notifier.saveSource(source);
      _afterSaveRefresh();
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

  /// overflow 菜单分流（对标原版 source_edit.xml 折叠项）
  Future<void> _handleMenu(String value) async {
    switch (value) {
      case 'login':
        _openLogin();
      case 'search':
        await _searchWithSource();
      case 'clear_cookie':
        await _clearCookie();
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
        await _setSourceVariable();
      case 'import_qr':
        await _importFromQr();
      case 'share_qr':
        await _shareQr();
      case 'share_str':
        await _shareSource();
      case 'log':
        // [UI-FIX v2.0.1 | 2026-08-06] 日志菜单接通 AppLogScreen（对标原版 menu_log → AppLogDialog） — Qoder
        Navigator.pushNamed(context, AppRoutes.appLog);
      case 'json_edit':
        await _showJsonEdit();
      case 'help':
        _showHelp();
    }
  }

  /// 保存当前书源后，以该源为搜索范围打开搜索页
  /// （对标原版 menu_search → SearchActivity.start(this, source)）
  Future<void> _searchWithSource() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _saving = true);
    try {
      final source = _buildSource();
      await ref.read(sourceNotifierProvider.notifier).saveSource(source);
      _afterSaveRefresh();
      if (!mounted) return;
      final search = ref.read(searchNotifierProvider.notifier);
      search.clearAllFilter();
      search.toggleSource(source.bookSourceUrl);
      await Navigator.of(context).pushNamed(AppRoutes.search);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('打开搜索失败：$e')),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// 清除 Cookie（对标原版 menu_clear_cookie → CookieStore.removeCookie）
  Future<void> _clearCookie() async {
    final url = _ctrl('bookSourceUrl').text.trim();
    if (url.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请先填写书源 URL')),
      );
      return;
    }
    try {
      await ref.read(bookApiProvider).clearCookie(url);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Cookie 已清除')),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('清除 Cookie 失败：$e')),
        );
      }
    }
  }

  /// 设置源变量（对标原版 menu_set_source_variable + VariableDialog）
  Future<void> _setSourceVariable() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _saving = true);
    try {
      final source = _buildSource();
      await ref.read(sourceNotifierProvider.notifier).saveSource(source);
      _afterSaveRefresh();
      if (!mounted) return;
      final srcComment = (source.variableComment ?? '').trim();
      final comment = srcComment.isNotEmpty
          ? srcComment
          : '源变量可在js中通过source.getVariable()获取';
      final input = await showDialog<String>(
        context: context,
        builder: (ctx) => _SourceVariableDialog(
          title: '设置源变量',
          comment: comment,
          initialText: _preservedVariable,
        ),
      );
      if (input == null || !mounted) return;
      await ref.read(bookApiProvider).setSourceVariable(
            source.bookSourceUrl,
            input,
          );
      if (!mounted) return;
      setState(() => _preservedVariable = input);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(input.isEmpty ? '源变量已清除' : '源变量已保存')),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('设置源变量失败：$e')),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// 二维码分享（对标原版 menu_share_qr → shareWithQr）
  Future<void> _shareQr() async {
    final json = jsonEncode(_buildSource().toJson());
    if (json.length > 2000) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('内容过长，无法生成二维码，请使用字符串分享')),
      );
      return;
    }
    await showDialog<void>(
      context: context,
      builder: (ctx) => _QrShareDialog(
        title: '分享书源',
        payload: json,
      ),
    );
  }

  /// 登录（对标原版 menu_login → SourceLoginActivity：
  /// hasLoginForm → 登录表单对话框；否则 WebView/手动凭据页）
  void _openLogin() {
    final loginUrl = _ctrl('loginUrl').text.trim();
    if (loginUrl.isEmpty && _ctrl('loginUi').text.trim().isEmpty) return;
    // 统一登录入口（V2 动态对话框 / 经典 loginUi 表单 / 手动凭据页）
    // — DeepSeek Harness + UI（2026-08-14 登录表单对齐）
    showSourceLogin(context, ref, _buildSource());
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

  /// 字符串分享（对标原版 menu_share_str：写缓存文件再分享）
  Future<void> _shareSource() async {
    try {
      final json = const JsonEncoder.withIndent('  ').convert(_buildSource().toJson());
      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/bookSource_share.json');
      await file.writeAsString(json);
      await Share.shareXFiles(
        [XFile(file.path, mimeType: 'application/json')],
        text: '书源分享',
      );
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
    showHelp(context, HelpAssets.ruleHelp);
  }

  /// 调试源（对标原版 menu_debug_source：保存后进入源调试页）
  Future<void> _debugSource() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _saving = true);
    try {
      final source = _buildSource();
      final notifier = ref.read(sourceNotifierProvider.notifier);
      await notifier.saveSource(source);
      _afterSaveRefresh();
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

  /// 全屏代码编辑（对标原版 menu_fullscreen_edit → CodeEditActivity）
  ///
  /// 需当前聚焦某一表单字段；无焦点时提示。JSON 整体编辑见 [_showJsonEdit]。
  Future<void> _showFullscreenEdit() async {
    final key = _focusedFieldKey;
    if (key == null || !_ctrls.containsKey(key)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请先将光标放在要编辑的输入框')),
      );
      return;
    }
    await _openCodeEditForField(key, title: _fieldLabels[key] ?? key);
  }

  Future<void> _openCodeEditForField(String key, {required String title}) async {
    final ctrl = _ctrl(key);
    final focus = _focus(key);
    final cursor = ctrl.selection.baseOffset.clamp(0, ctrl.text.length);
    final result = await CodeEditScreen.open(
      context,
      title: title,
      initialText: ctrl.text,
      cursorPosition: cursor < 0 ? 0 : cursor,
    );
    if (result == null || !mounted) return;
    setState(() {
      ctrl.text = result;
      ctrl.selection = TextSelection.collapsed(offset: result.length);
    });
    focus.requestFocus();
  }

  /// 整体 JSON 编辑（保留原 Flutter 便利能力，入口改到 overflow）
  Future<void> _showJsonEdit() async {
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
      // 对齐原版 7 个 Tab：基本/搜索/发现/详情/目录/正文/段评
      //（原版「调试源」为顶栏菜单，非 Tab）
      length: 7,
      child: Scaffold(
        appBar: LegadoAppBar(
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
            ],
          ),
          actions: [
            // 全屏代码编辑（对标原版 menu_fullscreen_edit → CodeEdit，需聚焦字段）
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
                  child: Text('清除Cookie'),
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
                const PopupMenuItem(
                  value: 'json_edit',
                  child: Text('JSON编辑'),
                ),
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
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 可折叠「设置」面板（对齐原版 BookSourceEditActivity 顶部设置区：
  /// 收起态标题显示摘要「类型 | 启用 | 发现 | CookieJar | 段评 |
  /// 事件监听 | 定制按钮」，展开显示类型下拉 + 开关）
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

    // 摘要（对齐原版 tvOptionsSummary：类型 + 勾选开关 join(" | ")）
    final summaryParts = <String>[_typeLabels[_bookSourceType]];
    void addSummary(String label, bool checked) {
      if (checked) summaryParts.add(label);
    }

    addSummary('启用', _enabled);
    addSummary('发现', _enabledExplore);
    addSummary('CookieJar', _cookieJar);
    addSummary('段评', _reviewEnabled);
    addSummary('事件监听', _eventListener);
    addSummary('定制按钮', _customButton);
    final summary = summaryParts.join(' | ');

    return ExpansionTile(
      // 默认收起，优先展示表单字段；收起态显示摘要（对齐原版紧凑设置行）
      initiallyExpanded: false,
      tilePadding: const EdgeInsets.symmetric(horizontal: 16),
      shape: const Border(),
      collapsedShape: const Border(),
      title: Text(
        '设置',
        style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
      ),
      subtitle: Text(
        summary,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 12,
          color: colorScheme.onSurfaceVariant,
        ),
      ),
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
    _fieldLabels[field.key] = field.label;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextFormField(
        controller: _ctrl(field.key),
        focusNode: _focus(field.key),
        maxLines: field.maxLines,
        decoration: InputDecoration(
          labelText: field.required ? '${field.label} *' : field.label,
          hintText: field.hint,
          border: const OutlineInputBorder(),
          suffixIcon: field.maxLines >= 2
              ? IconButton(
                  tooltip: '代码编辑',
                  icon: const Icon(Icons.code, size: 20),
                  onPressed: () => _openCodeEditForField(
                    field.key,
                    title: field.label,
                  ),
                )
              : null,
        ),
        validator: field.required
            ? (value) => (value == null || value.trim().isEmpty)
                  ? '请输入${field.label}'
                  : null
            : null,
      ),
    );
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
        appBar: LegadoAppBar(
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


/// 源变量对话框（自持 controller，对齐 book_info_screen._VariableDialog）
class _SourceVariableDialog extends StatefulWidget {
  final String title;
  final String comment;
  final String initialText;

  const _SourceVariableDialog({
    required this.title,
    required this.comment,
    required this.initialText,
  });

  @override
  State<_SourceVariableDialog> createState() => _SourceVariableDialogState();
}

class _SourceVariableDialogState extends State<_SourceVariableDialog> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.initialText);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: Text(widget.title),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.comment,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _controller,
              maxLines: 6,
              autofocus: true,
              decoration: const InputDecoration(
                hintText: '输入源变量（空则清除）',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _controller.text),
          child: const Text('确定'),
        ),
      ],
    );
  }
}

/// 二维码分享对话框：预览 + 分享 PNG（对标原版 shareWithQr）
class _QrShareDialog extends StatelessWidget {
  final String title;
  final String payload;

  const _QrShareDialog({required this.title, required this.payload});

  Future<void> _shareImage(BuildContext context) async {
    try {
      final painter = QrPainter(
        data: payload,
        version: QrVersions.auto,
        errorCorrectionLevel: QrErrorCorrectLevel.L,
        gapless: true,
        // ignore: deprecated_member_use
        color: const Color(0xFF000000),
        // ignore: deprecated_member_use
        emptyColor: const Color(0xFFFFFFFF),
      );
      final imageData = await painter.toImageData(
        512,
        format: ui.ImageByteFormat.png,
      );
      if (imageData == null) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('二维码生成失败')),
          );
        }
        return;
      }
      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/legado_source_qr.png');
      await file.writeAsBytes(imageData.buffer.asUint8List());
      await Share.shareXFiles(
        [XFile(file.path, mimeType: 'image/png')],
        subject: title,
      );
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('分享失败：$e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: Text(title),
      content: SizedBox(
        width: 240,
        height: 240,
        child: QrImageView(
          data: payload,
          version: QrVersions.auto,
          errorCorrectionLevel: QrErrorCorrectLevel.L,
          backgroundColor: Colors.white,
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('关闭'),
        ),
        FilledButton(
          onPressed: () => _shareImage(context),
          child: const Text('分享图片'),
        ),
      ],
    );
  }
}
