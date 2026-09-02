import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
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
part 'source_edit_screen_load.part.dart';
part 'source_edit_screen_actions.part.dart';
part 'source_edit_screen_builders.part.dart';
part 'source_edit_screen_dialogs.part.dart';

// ↑ 分域 part 文件（体检 §三.16 超长文件拆分）：非生命周期方法按域拆入 extension，
// 零行为变更（同 library 私有成员可访问）。

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

class _SourceEditScreenState extends ConsumerState<SourceEditScreen>
    with SingleTickerProviderStateMixin {
  final _formKey = GlobalKey<FormState>();
  bool _saving = false;

  /// Tab 控制器（对齐原版 TabLayout：设置卡片在 Tab 上方，字段导航条在下方）
  late final TabController _tabController = TabController(
    length: 7,
    vsync: this,
  )..addListener(() {
      if (_tabController.indexIsChanging) return;
      if (_lastFieldNavTab != _tabController.index) {
        setState(() {
          _lastFieldNavTab = _tabController.index;
          // 切换主 Tab 后字段导航条选中回到该 Tab 首字段
          _selectedNavField = null;
        });
      }
    });

  /// 字段导航条当前 Tab（跟随主 Tab 切换）
  int _lastFieldNavTab = 0;

  /// 字段导航条当前选中字段（对齐原版 field_nav 选中项主色指示线）
  String? _selectedNavField;

  /// 字段 GlobalKey（字段导航条跳转定位）
  final Map<String, GlobalKey> _fieldKeys = {};

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
  bool _settingsExpanded = false;
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
        // 字段获得焦点时同步字段导航条选中（高亮指示线跟随）
        if (_selectedNavField != key) {
          if (mounted) setState(() => _selectedNavField = key);
        }
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

  @override
  void dispose() {
    _tabController.dispose();
    for (final controller in _ctrls.values) {
      controller.dispose();
    }
    for (final node in _focusNodes.values) {
      node.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: LegadoAppBar(
        // 标题字号 20sp 与原版 ToolbarTitle 一致；防极端设备字号缩放截断
        title: Text(
          isNew ? '新建书源' : '编辑书源',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          // 全屏代码编辑（对齐原版 menu_fullscreen_edit → 编辑内容，图标位）
          IconButton(
            icon: const Icon(Symbols.code_rounded),
            tooltip: '编辑内容',
            // 压缩触控区 48→40dp：给标题留出更多空间（字体放大时标题
            // 保持原版字号完整显示，避免截断/缩放）
            visualDensity: VisualDensity.compact,
            onPressed: _showFullscreenEdit,
          ),
          // 保存（对齐原版 menu_save：仅图标，无文字）
          IconButton(
            icon: const Icon(Symbols.save_rounded),
            tooltip: '保存',
            visualDensity: VisualDensity.compact,
            onPressed: _saving ? null : _save,
          ),
          // 调试源（对齐原版 menu_debug_source，图标位）
          IconButton(
            icon: const Icon(Symbols.bug_report_rounded),
            tooltip: '调试源',
            visualDensity: VisualDensity.compact,
            onPressed: _saving ? null : _debugSource,
          ),
          // overflow 菜单（对齐原版 source_edit.xml 折叠项顺序/内容）
          // 用 showMenu 显式锚定在按钮下方（AppBar 内 PopupMenuButton 的
          // 弹出层会覆盖顶栏按钮，与原版「菜单在按钮下方」不一致）
          Builder(
            builder: (btnContext) => IconButton(
              icon: const Icon(Symbols.more_vert_rounded),
              tooltip: '更多选项',
              visualDensity: VisualDensity.compact,
              onPressed: () => _showOverflowMenu(btnContext),
            ),
          ),
        ],
      ),
      body: Form(
        key: _formKey,
        child: Column(
          children: [
            // 对齐原版布局顺序：设置卡片 → Tab 栏 → 字段导航条 → 表单
            _buildSettingsPanel(),
            // 对齐原版 tab_layout：高度 36dp + 滚动页签 + 主色指示线
            SizedBox(
              height: 36,
              child: TabBar(
                controller: _tabController,
                isScrollable: true,
                labelPadding: const EdgeInsets.symmetric(horizontal: 12),
                labelStyle: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                ),
                unselectedLabelStyle: const TextStyle(fontSize: 14),
                // 页签文案对齐原版 source_tab_* 短标签
                tabs: const [
                  Tab(text: '基本'),
                  Tab(text: '搜索'),
                  Tab(text: '发现'),
                  Tab(text: '详情'),
                  Tab(text: '目录'),
                  Tab(text: '正文'),
                  Tab(text: '段评'),
                ],
              ),
            ),
            _buildFieldNav(),
            Expanded(
              child: TabBarView(
                controller: _tabController,
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
    );
  }
}
