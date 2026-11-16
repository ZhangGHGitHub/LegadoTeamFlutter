import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import '../l10n/app_strings.dart';
import '../widgets/app_scaffold.dart';
import '../widgets/legado_app_bar.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:path_provider/path_provider.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/models.dart';
import '../constants/pref_keys.dart';
import '../providers/explore/explore_notifier.dart';
import '../providers/providers.dart';
import '../providers/search/search_notifier.dart';
import '../providers/source/source_notifier.dart';
import '../routes.dart';
import '../utils/source_login_entry.dart';
import '../widgets/help/help_assets.dart';
import '../widgets/help/show_help.dart';
import 'code_edit_screen.dart';
import '../utils/error_message.dart';
part 'source_edit_screen_load.part.dart';
part 'source_edit_screen_actions.part.dart';
part 'source_edit_screen_builders.part.dart';
part 'source_edit_screen_dialogs.part.dart';

// ↑ 分域 part 文件（体检 §三.16 超长文件拆分）：非生命周期方法按域拆入 extension，
// 零行为变更（同 library 私有成员可访问）。

/// 书源编辑页面
///
/// 对标 Android `BookSourceEditActivity`，编辑书源的全部规则：
/// 设置 + 基本信息 / 搜索规则 / 发现规则 / 详情规则 / 目录规则 / 正文规则 /
/// 段评规则。
/// [B2-C2 2-8 | 全栈工程师] 表单改为扁平单列结构（对齐参考版 ref 09）：
/// 设置段与 7 大规则分组在同一滚动列内顺序展开，取消 Tab 页签与字段导航条；
/// 字段顺序与分组沿用原数据驱动定义（[_Field] 列表），controller 按 key
/// 惰性创建，与原版基于 `EditEntity` 列表的配置化编辑思路一致。
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

  // [B2-C2 2-8 | 全栈工程师] 扁平单列后取消 TabController/字段导航条
  // （原 _tabController/_lastFieldNavTab/_selectedNavField 一并移除），
  // 字段 GlobalKey 仍保留供焦点定位/校验滚动使用。
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
      // [B2-C2 2-8] 扁平化后无字段导航条，仅记录焦点字段 key
      if (_focusNodes[key]?.hasFocus == true) {
        _focusedFieldKey = key;
      }
    }),
  );

  /// 书源类型（对标原版 sp_type / @array/source_type）
  static List<String> get _typeLabels => [
    AppStrings.sourceTypeText,
    AppStrings.sourceTypeAudio,
    AppStrings.sourceTypeImage,
    AppStrings.sourceTypeFile,
    AppStrings.sourceTypeVideo,
  ];

  // ─── 基本信息字段（对齐原版 BookSourceEditActivity sourceEntities 顺序/标签） ───
  static List<_Field> get _basicFields => [
    _Field('bookSourceUrl', AppStrings.sourceFieldBookSourceUrl, required: true, maxLines: 1),
    _Field('bookSourceName', AppStrings.sourceFieldBookSourceName, required: true, maxLines: 1),
    _Field('bookSourceGroup', AppStrings.sourceFieldBookSourceGroup, maxLines: 1),
    _Field('bookSourceComment', AppStrings.sourceFieldBookSourceComment, maxLines: 3),
    _Field('loginUrl', AppStrings.sourceFieldLoginUrl, maxLines: 3),
    _Field('loginUi', AppStrings.sourceFieldLoginUi, maxLines: 4),
    _Field('loginCheckJs', AppStrings.sourceFieldLoginCheckJs, maxLines: 4),
    _Field('coverDecodeJs', AppStrings.sourceFieldCoverDecodeJs, maxLines: 4),
    _Field('bookUrlPattern', AppStrings.sourceFieldBookUrlPattern, maxLines: 2),
    _Field(
      'header',
      AppStrings.sourceFieldHeader,
      hint: AppStrings.sourceJsonFormatHint,
      maxLines: 3,
    ),
    _Field('variableComment', AppStrings.sourceFieldVariableComment, maxLines: 2),
    _Field('concurrentRate', AppStrings.sourceFieldConcurrentRate, maxLines: 1),
    _Field('jsLib', 'jsLib', maxLines: 8),
  ];

  // ─── 搜索规则字段（对齐原版 searchEntities 顺序/标签） ──────────
  static List<_Field> get _searchFields => [
    _Field(
      'searchUrl',
      AppStrings.sourceFieldSearchUrl,
      maxLines: 1,
      hint: AppStrings.sourceFieldSearchUrlHint,
    ),
    _Field('s_checkKeyWord', AppStrings.sourceFieldCheckKeyWord),
    _Field('s_bookList', AppStrings.sourceFieldBookList),
    _Field('s_name', AppStrings.sourceFieldName),
    _Field('s_author', AppStrings.sourceFieldAuthor),
    _Field('s_kind', AppStrings.sourceFieldKind),
    _Field('s_wordCount', AppStrings.sourceFieldWordCount),
    _Field('s_lastChapter', AppStrings.sourceFieldLastChapter),
    _Field('s_intro', AppStrings.sourceFieldIntro),
    _Field('s_coverUrl', AppStrings.sourceFieldCoverUrl),
    _Field('s_bookUrl', AppStrings.sourceFieldBookUrl),
  ];

  // ─── 发现规则字段（对齐原版 exploreEntities 顺序/标签） ──────────
  static List<_Field> get _exploreFields => [
    _Field(
      'exploreUrl',
      AppStrings.sourceFieldExploreUrl,
      maxLines: 3,
      hint: AppStrings.sourceExploreUrlHintExample,
    ),
    _Field('e_bookList', AppStrings.sourceFieldBookList),
    _Field('e_name', AppStrings.sourceFieldName),
    _Field('e_author', AppStrings.sourceFieldAuthor),
    _Field('e_kind', AppStrings.sourceFieldKind),
    _Field('e_wordCount', AppStrings.sourceFieldWordCount),
    _Field('e_lastChapter', AppStrings.sourceFieldLastChapter),
    _Field('e_intro', AppStrings.sourceFieldIntro),
    _Field('e_coverUrl', AppStrings.sourceFieldCoverUrl),
    _Field('e_bookUrl', AppStrings.sourceFieldBookUrl),
  ];

  // ─── 详情规则字段（对齐原版 infoEntities 顺序/标签） ─────────────
  static List<_Field> get _infoFields => [
    _Field('i_init', AppStrings.sourceFieldBookInfoInit),
    _Field('i_name', AppStrings.sourceFieldName),
    _Field('i_author', AppStrings.sourceFieldAuthor),
    _Field('i_kind', AppStrings.sourceFieldKind),
    _Field('i_wordCount', AppStrings.sourceFieldWordCount),
    _Field('i_lastChapter', AppStrings.sourceFieldLastChapter),
    _Field('i_intro', AppStrings.sourceFieldIntro),
    _Field('i_coverUrl', AppStrings.sourceFieldCoverUrl),
    _Field('i_tocUrl', AppStrings.sourceFieldTocUrl),
    _Field('i_canReName', AppStrings.sourceFieldCanReName),
    _Field('i_downloadUrls', AppStrings.sourceFieldDownloadUrls),
  ];

  // ─── 目录规则字段（对齐原版 tocEntities 顺序/标签） ─────────────
  static List<_Field> get _tocFields => [
    _Field('t_preUpdateJs', AppStrings.sourceFieldPreUpdateJs),
    _Field('t_chapterList', AppStrings.sourceFieldChapterList),
    _Field('t_chapterName', AppStrings.sourceFieldChapterName),
    _Field('t_chapterUrl', AppStrings.sourceFieldChapterUrl),
    _Field('t_formatJs', AppStrings.sourceFieldFormatJs),
    _Field('t_isVolume', AppStrings.sourceFieldIsVolume),
    _Field('t_updateTime', AppStrings.sourceFieldChapterInfo),
    _Field('t_isVip', AppStrings.sourceFieldIsVip),
    _Field('t_isPay', AppStrings.sourceFieldIsPay),
    _Field('t_nextTocUrl', AppStrings.sourceFieldNextTocUrl),
  ];

  // ─── 正文规则字段（对齐原版 contentEntities 顺序/标签） ──────────
  static List<_Field> get _contentFields => [
    _Field('c_content', AppStrings.sourceFieldContent, maxLines: 3),
    _Field('c_nextContentUrl', AppStrings.sourceFieldNextContentUrl),
    _Field('c_subContent', AppStrings.sourceFieldSubContent),
    _Field('c_replaceRegex', AppStrings.sourceFieldReplaceRegex, maxLines: 4),
    _Field('c_title', AppStrings.sourceFieldTitle),
    _Field('c_sourceRegex', AppStrings.sourceFieldSourceRegex),
    _Field('c_imageStyle', AppStrings.sourceFieldImageStyle),
    _Field('c_imageDecode', AppStrings.sourceFieldImageDecode),
    _Field('c_webJs', 'WebView JS（webJs）', maxLines: 4),
    _Field('c_payAction', AppStrings.sourceFieldPayAction),
    _Field('c_callBackJs', AppStrings.sourceFieldCallBackJs),
  ];

  // ─── 段评规则字段（对齐原版 reviewEntities 顺序/标签） ───────────
  static List<_Field> get _reviewFields => [
    _Field('r_reviewSummaryUrl', AppStrings.sourceFieldReviewSummaryUrl),
    _Field('r_summaryListRule', AppStrings.sourceFieldSummaryListRule),
    _Field('r_summaryParagraphIndexRule', AppStrings.sourceFieldSummaryParagraphIndexRule),
    _Field('r_summaryCountRule', AppStrings.sourceFieldSummaryCountRule),
    _Field('r_summaryParagraphDataRule', AppStrings.sourceFieldSummaryParagraphDataRule),
    _Field('r_reviewDetailUrl', AppStrings.sourceFieldReviewDetailUrl),
    _Field('r_reviewDetailNextPageUrl', AppStrings.sourceFieldReviewDetailNextPageUrl),
    _Field('r_detailListRule', AppStrings.sourceFieldDetailListRule),
    _Field('r_detailIdRule', AppStrings.sourceFieldDetailIdRule),
    _Field('r_detailAvatarRule', AppStrings.sourceFieldDetailAvatarRule),
    _Field('r_detailNameRule', AppStrings.sourceFieldDetailNameRule),
    _Field('r_detailBadgeRule', AppStrings.sourceFieldDetailBadgeRule),
    _Field('r_detailContentRule', AppStrings.sourceFieldDetailContentRule, maxLines: 3),
    _Field('r_reviewQuoteUrl', AppStrings.sourceFieldReviewQuoteUrl),
    _Field('r_replyListRule', AppStrings.sourceFieldReplyListRule),
    _Field('r_replyIdRule', AppStrings.sourceFieldReplyIdRule),
    _Field('r_replyAvatarRule', AppStrings.sourceFieldReplyAvatarRule),
    _Field('r_replyNameRule', AppStrings.sourceFieldReplyNameRule),
    _Field('r_replyBadgeRule', AppStrings.sourceFieldReplyBadgeRule),
    _Field('r_replyContentRule', AppStrings.sourceFieldReplyContentRule, maxLines: 3),
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
    // 批9a 项7：读取「源编辑框最大行数」偏好（进页读一次；对齐原版
    // BookSourceEditAdapter.kt:99-103——全部编辑实体统一套用
    // editEntityMaxLine 无字段过滤；我方映射为**所有多行字段**
    // （maxLines≥2），单行字段不套用，语义见 _sourceEditMaxLine）
    _loadSourceEditMaxLine();
  }

  /// 源编辑框最大行数（批9a 项7，对齐原版 BookSourceEditAdapter
  /// `editEntityMaxLine = AppConfig.sourceEditMaxLine`）
  ///
  /// 语义映射（P2-3 修正）：原版是「编辑实体输入框」**统一**行数上限
  /// （BookSourceEditAdapter.kt:99 `editText.maxLines = editEntityMaxLine`，
  /// 对基本信息/搜索/发现/详情/目录/正文全部 EditEntity 生效，无字段
  /// 白名单；仅 isUnsafeText 超长预览分支除外）。我方为逐字段表单，
  /// 映射到**所有多行字段**（maxLines≥2）；单行字段（maxLines=1：源
  /// URL/名称/分组/并发率）保持 1 不套用。合法下限 10（对齐设置页
  /// 区间），越界回落默认 99。
  int _sourceEditMaxLine = _defaultSourceEditMaxLine;

  /// 偏好默认 99（原版默认 Int.MAX_VALUE，我方 UI 默认 99，对齐设置页口径）
  static const int _defaultSourceEditMaxLine = 99;

  /// 合法下限（对齐设置页 min=10；越界回落默认）
  static const int _minSourceEditMaxLine = 10;

  Future<void> _loadSourceEditMaxLine() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final v = prefs.getInt(PrefKeys.sourceEditMaxLine) ??
          _defaultSourceEditMaxLine;
      if (!mounted) return;
      setState(() {
        _sourceEditMaxLine =
            v >= _minSourceEditMaxLine ? v : _defaultSourceEditMaxLine;
      });
    } catch (_) {
      // prefs 读取失败保持默认 99
    }
  }

  @override
  void dispose() {
    // [B2-C2 2-8] TabController 已随扁平化移除，无需 dispose
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
    // [GLOBALCOMP B4] 页壳统一：AppScaffold（行为等价直通 Scaffold）
    return AppScaffold(
      topBar: LegadoAppBar(
        // 标题字号 20sp 与原版 ToolbarTitle 一致；防极端设备字号缩放截断
        title: Text(
          isNew ? AppStrings.sourceAdd : AppStrings.sourceEdit,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          // 全屏代码编辑（对齐原版 menu_fullscreen_edit → 编辑内容，图标位）
          IconButton(
            icon: const Icon(Symbols.code_rounded),
            tooltip: AppStrings.sourceEditContent,
            // 压缩触控区 48→40dp：给标题留出更多空间（字体放大时标题
            // 保持原版字号完整显示，避免截断/缩放）
            visualDensity: VisualDensity.compact,
            onPressed: _showFullscreenEdit,
          ),
          // 保存（对齐原版 menu_save：仅图标，无文字）
          IconButton(
            icon: const Icon(Symbols.save_rounded),
            tooltip: AppStrings.save,
            visualDensity: VisualDensity.compact,
            onPressed: _saving ? null : _save,
          ),
          // 调试源（对齐原版 menu_debug_source，图标位）
          IconButton(
            icon: const Icon(Symbols.bug_report_rounded),
            tooltip: AppStrings.sourceDebug,
            visualDensity: VisualDensity.compact,
            onPressed: _saving ? null : _debugSource,
          ),
          // overflow 菜单（对齐原版 source_edit.xml 折叠项顺序/内容）
          // 用 showMenu 显式锚定在按钮下方（AppBar 内 PopupMenuButton 的
          // 弹出层会覆盖顶栏按钮，与原版「菜单在按钮下方」不一致）
          Builder(
            builder: (btnContext) => IconButton(
              icon: const Icon(Symbols.more_vert_rounded),
              tooltip: AppStrings.rssMoreOptions,
              visualDensity: VisualDensity.compact,
              onPressed: () => _showOverflowMenu(btnContext),
            ),
          ),
        ],
      ),
      // [B2-C2 2-8 | 全栈工程师] 表单扁平单列（对齐参考版 ref 09）：
      // 设置段 + 7 大规则分组在同一滚动列内顺序展开，取消 Tab 页签与字段
      // 导航条；字段顺序沿用原各 Tab 内的数据驱动定义
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.only(bottom: 24),
          children: [
            _buildSettingsSection(),
            _buildFormSection(AppStrings.sourceBasicInfo, _basicFields),
            _buildFormSection(AppStrings.sourceSearchRules, _searchFields),
            _buildFormSection(AppStrings.sourceExploreRules, _exploreFields),
            _buildFormSection(AppStrings.sourceInfoRules, _infoFields),
            _buildFormSection(AppStrings.sourceTocRules, _tocFields),
            _buildFormSection(AppStrings.sourceContentRules, _contentFields),
            _buildFormSection(AppStrings.sourceReviewRules, _reviewFields),
          ],
        ),
      ),
    );
  }
}
