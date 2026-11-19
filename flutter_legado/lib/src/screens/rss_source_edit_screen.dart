import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import '../widgets/app_scaffold.dart';
import '../widgets/legado_app_bar.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:share_plus/share_plus.dart';

import '../models/models.dart';
import '../l10n/app_strings.dart';
import '../providers/providers.dart';
import '../routes.dart';
import '../utils/error_message.dart';
import '../widgets/confirm_dialog.dart';
import '../widgets/help/help_assets.dart';
import '../widgets/help/show_help.dart';
import 'code_edit_screen.dart';

/// 编辑字段定义（key 与 RssSource JSON 字段名一致）
class _FieldSpec {
  final String key;
  final String label;
  final String hint;
  final int maxLines;

  const _FieldSpec(this.key, this.label, [this.hint = '', this.maxLines = 1]);
}

/// RSS 源编辑器页面（对标原版 RssSourceEditActivity）
///
/// - 可折叠选项面板：启用 / 单 URL / Cookie / 预加载 + 源类型 + 文章样式
/// - 4 Tab：基本（15 字段）/ 预处理（4）/ 列表规则（7）/ WEB_VIEW（10）
/// - 菜单：调试源 / 复制源 / 粘贴源 / 分享文本 / 帮助
/// - 编辑走 updateRssSource，新建走 addRssSource；退出时未保存提示
class RssSourceEditScreen extends ConsumerStatefulWidget {
  /// 编辑模式时传入已有源，null 表示新建
  final RssSource? source;

  const RssSourceEditScreen({super.key, this.source});

  @override
  ConsumerState<RssSourceEditScreen> createState() =>
      _RssSourceEditScreenState();
}

class _RssSourceEditScreenState extends ConsumerState<RssSourceEditScreen> {
  // ===== 字段定义（对标原版 sourceEntities 4 Tab 分组） =====

  static final _baseFields = [
    _FieldSpec('sourceName', AppStrings.rssFieldSourceName),
    _FieldSpec('sourceUrl', AppStrings.rssFieldSourceUrl,
        'https://example.com/feed'),
    _FieldSpec('sourceIcon', AppStrings.rssFieldSourceIcon,
        AppStrings.rssFieldIconUrl),
    _FieldSpec('sourceGroup', AppStrings.rssFieldSourceGroup,
        AppStrings.rssFieldGroupHint),
    _FieldSpec('sourceComment', AppStrings.rssFieldSourceComment, '', 2),
    _FieldSpec('searchUrl', AppStrings.coverSearchUrl),
    _FieldSpec('sortUrl', AppStrings.rssFieldSortUrl,
        AppStrings.rssFieldSortUrlHint, 2),
    _FieldSpec('loginUrl', AppStrings.rssFieldLoginUrl),
    _FieldSpec('loginUi', AppStrings.rssFieldLoginUi),
    _FieldSpec('loginCheckJs', AppStrings.rssFieldLoginCheckJs),
    _FieldSpec('coverDecodeJs', AppStrings.rssFieldCoverDecodeJs),
    _FieldSpec('header', AppStrings.rssFieldHeader),
    _FieldSpec('variableComment', AppStrings.rssFieldVariableComment,
        'variableComment'),
    _FieldSpec('concurrentRate', AppStrings.rssFieldConcurrentRate,
        AppStrings.rssFieldConcurrentRateHint),
    _FieldSpec('jsLib', AppStrings.rssFieldJsLib,
        AppStrings.rssFieldJsLibHint),
  ];

  static final _preFields = [
    _FieldSpec('startHtml', AppStrings.rssFieldStartHtml, 'startHtml'),
    _FieldSpec('startStyle', AppStrings.rssFieldStartStyle, 'startStyle', 2),
    _FieldSpec('startJs', AppStrings.rssFieldStartJs, 'startJs'),
    _FieldSpec('preloadJs', AppStrings.rssFieldPreloadJs, 'preloadJs'),
  ];

  static final _listFields = [
    _FieldSpec('ruleArticles', AppStrings.rssFieldArticles,
        AppStrings.rssFieldArticlesHint),
    _FieldSpec('ruleNextPage', AppStrings.rssFieldNextPage, 'ruleNextPage'),
    _FieldSpec('ruleTitle', AppStrings.rssFieldTitle, 'ruleTitle'),
    _FieldSpec('rulePubDate', AppStrings.rssFieldPubDate, 'rulePubDate'),
    _FieldSpec('ruleDescription', AppStrings.rssFieldDescription,
        'ruleDescription'),
    _FieldSpec('ruleImage', AppStrings.rssFieldImage, 'ruleImage'),
    _FieldSpec('ruleLink', AppStrings.rssFieldLink, 'ruleLink'),
  ];

  static final _webFields = [
    _FieldSpec('ruleContent', AppStrings.rssFieldContent, 'ruleContent'),
    _FieldSpec('style', AppStrings.rssFieldStyle,
        AppStrings.rssFieldStyleHint, 2),
    _FieldSpec('injectJs', AppStrings.rssFieldInjectJs, 'injectJs'),
    _FieldSpec('contentWhitelist', AppStrings.rssFieldContentWhitelist,
        'contentWhitelist'),
    _FieldSpec('contentBlacklist', AppStrings.rssFieldContentBlacklist,
        'contentBlacklist'),
    _FieldSpec('shouldOverrideUrlLoading', AppStrings.rssFieldUrlInterceptor,
        'shouldOverrideUrlLoading'),
  ];

  static final _allFieldSpecs = [
    ..._baseFields,
    ..._preFields,
    ..._listFields,
    ..._webFields,
  ];

  /// 源类型（对标原版 sp_type / @array/rss_type）
  static List<String> get _typeLabels => [
        AppStrings.rssTypeWeb,
        AppStrings.sourceTypeImage,
        AppStrings.sourceTypeVideo,
      ];

  /// 文章样式（对标原版 ly_type / @array/layout_type）
  static List<String> get _styleLabels => [
        AppStrings.layoutList,
        AppStrings.rssStyleSingle,
        AppStrings.rssStyleDouble,
        AppStrings.rssStyleWaterfall,
        AppStrings.rssStyleTriple,
      ];

  final Map<String, TextEditingController> _ctrls = {};
  final Map<String, FocusNode> _focusNodes = {};
  String? _focusedFieldKey;

  // 选项面板开关（对标原版 cb_is_enable 等）
  late bool _enabled;
  late bool _singleUrl;
  late bool _cookieJar;
  late bool _preload;

  // WEB_VIEW 页开关
  late bool _enableJs;
  late bool _loadWithBaseUrl;
  late bool _showWebLog;
  late bool _cacheFirst;

  late int _type;
  late int _articleStyle;

  bool _saving = false;
  bool _testing = false;
  String? _testResult;
  String? _testError;

  bool get _isEdit => widget.source != null;

  /// 进入时的字段快照（用于退出未保存提示）
  late final String _initialSnapshot;

  @override
  void initState() {
    super.initState();
    final s = widget.source;
    // 初始值直接取源 JSON（key 与字段定义一致）
    final initial = s?.toJson() ?? const <String, dynamic>{};
    for (final spec in _allFieldSpecs) {
      final v = initial[spec.key];
      _ctrls[spec.key] =
          TextEditingController(text: v == null ? '' : v.toString());
    }
    _enabled = s?.enabled ?? true;
    _singleUrl = s?.singleUrl ?? false;
    _cookieJar = s?.enabledCookieJar ?? false;
    _preload = s?.preload ?? false;
    _enableJs = s?.enableJs ?? true;
    _loadWithBaseUrl = s?.loadWithBaseUrl ?? true;
    _showWebLog = s?.showWebLog ?? false;
    _cacheFirst = s?.cacheFirst ?? false;
    // 越界归零（对标原版 spType/lyType selection 校验）
    _type = (s?.rssType ?? 0).clamp(0, _typeLabels.length - 1);
    _articleStyle = (s?.articleStyle ?? 0).clamp(0, _styleLabels.length - 1);
    _initialSnapshot = _snapshot();
  }

  FocusNode _focusNodeFor(String key) => _focusNodes.putIfAbsent(
    key,
    () => FocusNode()..addListener(() {
      if (_focusNodes[key]?.hasFocus == true) {
        _focusedFieldKey = key;
      }
    }),
  );

  Future<void> _openCodeEdit(String key, String title) async {
    final ctrl = _ctrls[key]!;
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
  }

  Future<void> _fullscreenCodeEdit() async {
    final key = _focusedFieldKey;
    if (key == null || !_ctrls.containsKey(key)) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(AppStrings.sourceFocusFieldFirst)),
      );
      return;
    }
    final label = _allFieldSpecs
        .where((s) => s.key == key)
        .map((s) => s.label)
        .firstOrNull;
    await _openCodeEdit(key, label ?? key);
  }

  @override
  void dispose() {
    for (final c in _ctrls.values) {
      c.dispose();
    }
    for (final n in _focusNodes.values) {
      n.dispose();
    }
    super.dispose();
  }

  // ===== 快照与构建 =====

  String _snapshot() {
    return jsonEncode({
      for (final spec in _allFieldSpecs) spec.key: _ctrls[spec.key]!.text,
      'enabled': _enabled,
      'singleUrl': _singleUrl,
      'enabledCookieJar': _cookieJar,
      'preload': _preload,
      'enableJs': _enableJs,
      'loadWithBaseUrl': _loadWithBaseUrl,
      'showWebLog': _showWebLog,
      'cacheFirst': _cacheFirst,
      'type': _type,
      'articleStyle': _articleStyle,
    });
  }

  String? _opt(String key) {
    final v = _ctrls[key]!.text.trim();
    return v.isEmpty ? null : v;
  }

  /// 组装完整源（显式构造全部字段，避免 copyWith 无法清空可空字段）
  RssSource _buildSource() {
    final old = widget.source;
    return RssSource(
      sourceName: _ctrls['sourceName']!.text.trim(),
      sourceUrl: _ctrls['sourceUrl']!.text.trim(),
      sourceIcon: _opt('sourceIcon') ?? '',
      sourceGroup: _opt('sourceGroup'),
      sourceComment: _opt('sourceComment'),
      enabled: _enabled,
      // 批28：阅读历史开关无 UI，编辑保存时从既有源透传（原版字段，默认 true）
      enableReadRecord: old?.enableReadRecord ?? true,
      variableComment: _opt('variableComment'),
      jsLib: _opt('jsLib'),
      enabledCookieJar: _cookieJar,
      concurrentRate: _opt('concurrentRate'),
      header: _opt('header'),
      loginUrl: _opt('loginUrl'),
      loginUi: _opt('loginUi'),
      loginCheckJs: _opt('loginCheckJs'),
      coverDecodeJs: _opt('coverDecodeJs'),
      sortUrl: _opt('sortUrl'),
      singleUrl: _singleUrl,
      articleStyle: _articleStyle,
      ruleArticles: _opt('ruleArticles'),
      ruleNextPage: _opt('ruleNextPage'),
      ruleTitle: _opt('ruleTitle'),
      rulePubDate: _opt('rulePubDate'),
      ruleDescription: _opt('ruleDescription'),
      ruleImage: _opt('ruleImage'),
      ruleLink: _opt('ruleLink'),
      ruleContent: _opt('ruleContent'),
      // 批28：正文下一页规则不在编辑表单内，保存时从既有源透传，避免被清空
      nextContentUrl: old?.nextContentUrl,
      contentWhitelist: _opt('contentWhitelist'),
      contentBlacklist: _opt('contentBlacklist'),
      shouldOverrideUrlLoading: _opt('shouldOverrideUrlLoading'),
      style: _opt('style'),
      enableJs: _enableJs,
      loadWithBaseUrl: _loadWithBaseUrl,
      injectJs: _opt('injectJs'),
      preloadJs: _opt('preloadJs'),
      startHtml: _opt('startHtml'),
      startStyle: _opt('startStyle'),
      startJs: _opt('startJs'),
      showWebLog: _showWebLog,
      // 编辑模式保留排序与更新时间（对标原版 viewModel.save 语义）
      lastUpdateTime: old?.lastUpdateTime ?? 0,
      customOrder: old?.customOrder ?? 0,
      rssType: _type,
      preload: _preload,
      cacheFirst: _cacheFirst,
      searchUrl: _opt('searchUrl'),
    );
  }

  // ===== 保存 / 测试 =====

  Future<void> _save() async {
    final name = _ctrls['sourceName']!.text.trim();
    final url = _ctrls['sourceUrl']!.text.trim();
    if (name.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(AppStrings.rssSourceNameRequired)),
      );
      return;
    }
    if (url.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(AppStrings.rssSourceUrlRequired)),
      );
      return;
    }

    setState(() => _saving = true);
    // [D3] 保存结果用 RssSource 承载：订阅源管理页以 `push<RssSource>` 打开
    // 本页，`pop(true)` 会在 MaterialRouteTransitionMixin.didPop 触发结果
    // 类型强转异常，把路由卡在 popping 态（页面不返回、返回键失效）。
    // 因此 pop 必须回传同类型对象；失败（saved == null）不 pop。
    RssSource? saved;
    try {
      final api = ref.read(bookApiProvider);
      final source = _buildSource();
      if (_isEdit) {
        await api.updateRssSource(source);
      } else {
        await api.addRssSource(source);
      }
      saved = source;
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(AppStrings.saveFailedWith(errorMessage(e)))),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
    if (saved == null || !mounted) return;
    // 保存成功后更新快照，退出不再提示未保存
    _initialSnapshotMark = _snapshot();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(_isEdit
            ? AppStrings.rssSourceUpdated
            : AppStrings.rssSourceAdded),
      ),
    );
    // 只 pop 一次并回传已保存源（强类型路由契约，见方法上方注释）
    Navigator.of(context).pop(saved);
  }

  /// 保存成功后覆盖初始快照的可变标记（late final 无法重赋值，独立持有）
  String? _savedSnapshot;
  String get _initialSnapshotMark => _savedSnapshot ?? _initialSnapshot;
  set _initialSnapshotMark(String v) => _savedSnapshot = v;

  bool get _dirty => _snapshot() != _initialSnapshotMark;

  /// 退出拦截：未保存时确认放弃（对标原版 exit 提示）
  Future<void> _tryExit({Object? result}) async {
    if (!_dirty) {
      Navigator.of(context).pop(result);
      return;
    }
    final discard = await showConfirmDialog(
      context,
      title: AppStrings.rssSourceUnsavedTitle,
      content: AppStrings.rssSourceUnsavedDesc,
      confirmText: AppStrings.rssSourceDiscard,
      isDestructive: true,
    );
    if (discard && mounted) {
      Navigator.of(context).pop(result);
    }
  }

  Future<void> _test() async {
    final url = _ctrls['sourceUrl']!.text.trim();
    if (url.isEmpty) {
      setState(() => _testError = AppStrings.rssSourceEnterUrlFirst);
      return;
    }
    setState(() {
      _testing = true;
      _testResult = null;
      _testError = null;
    });
    try {
      final api = ref.read(bookApiProvider);
      final articles = await api.getRssArticles(url);
      if (articles.isEmpty) {
        setState(() => _testResult = AppStrings.rssSourceTestNoArticles);
      } else {
        final titles = articles
            .take(5)
            .map((e) =>
                e.title.isEmpty ? AppStrings.rssSourceUntitled : e.title)
            .join('\n');
        setState(() => _testResult =
            AppStrings.rssSourceTestSuccess(articles.length, titles));
      }
    } catch (e) {
      setState(() => _testError = AppStrings.rssSourceTestFailed(errorMessage(e)));
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  // ===== 菜单操作 =====

  Future<void> _handleMenu(String action) async {
    switch (action) {
      case 'debug':
        final url = _ctrls['sourceUrl']!.text.trim();
        Navigator.of(context).pushNamed(
          AppRoutes.rssSourceDebug,
          arguments: url.isEmpty ? null : url,
        );
      case 'copy':
        final json = const JsonEncoder.withIndent('  ')
            .convert(_buildSource().toJson());
        await Clipboard.setData(ClipboardData(text: json));
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(AppStrings.rssSourceCopied)),
          );
        }
      case 'paste':
        await _pasteSource();
      case 'clear_cookie':
        await _clearCookie();
      case 'code_edit':
        await _fullscreenCodeEdit();
      case 'share':
        final json = jsonEncode(_buildSource().toJson());
        await Share.share(
          json,
          subject: AppStrings.rssSourceShareSubject(
            _ctrls['sourceName']!.text.trim(),
          ),
        );
      case 'help':
        _showHelpSheet();
    }
  }

  /// 清除 Cookie（对标原版 RssSourceEdit menu_clear_cookie）
  Future<void> _clearCookie() async {
    final url = _ctrls['sourceUrl']!.text.trim();
    if (url.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(AppStrings.rssSourceFillUrlFirst)),
        );
      }
      return;
    }
    try {
      await ref.read(bookApiProvider).clearCookie(url);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(AppStrings.sourceCookieCleared)),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(AppStrings.rssSourceClearCookieFailed(errorMessage(e))),
          ),
        );
      }
    }
  }

  /// 粘贴源（对标原版 menu_paste_source：剪贴板 JSON 回填字段）
  Future<void> _pasteSource() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim();
    if (text == null || text.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(AppStrings.sourceClipboardEmpty)),
        );
      }
      return;
    }
    try {
      final decoded = jsonDecode(text);
      final map = decoded is List && decoded.isNotEmpty
          ? decoded.first
          : decoded;
      if (map is! Map) {
        throw FormatException(AppStrings.rssSourceNotRssJson);
      }
      setState(() {
        for (final spec in _allFieldSpecs) {
          final v = map[spec.key];
          _ctrls[spec.key]!.text = v == null ? '' : v.toString();
        }
        _enabled = map['enabled'] == true;
        _singleUrl = map['singleUrl'] == true;
        _cookieJar = map['enabledCookieJar'] == true;
        _preload = map['preload'] == true;
        _enableJs = map['enableJs'] != false;
        _loadWithBaseUrl = map['loadWithBaseUrl'] != false;
        _showWebLog = map['showWebLog'] == true;
        _cacheFirst = map['cacheFirst'] == true;
        final type = map['type'];
        _type = type is int ? type.clamp(0, _typeLabels.length - 1) : 0;
        final style = map['articleStyle'];
        _articleStyle =
            style is int ? style.clamp(0, _styleLabels.length - 1) : 0;
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(AppStrings.rssSourcePasted)),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(AppStrings.rssSourcePasteFailed(errorMessage(e))),
          ),
        );
      }
    }
  }

  void _showHelpSheet() {
    showHelp(context, HelpAssets.rssRuleHelp);
  }

  // ===== 构建 =====

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _tryExit();
      },
      child: DefaultTabController(
        length: 4,
        child: AppScaffold(
          // [GLOBALCOMP B4] 页壳统一：AppScaffold（行为等价直通 Scaffold）
          topBar: LegadoAppBar(
            leading: IconButton(
              icon: const Icon(Symbols.arrow_back_rounded),
              onPressed: _tryExit,
            ),
            title: Text(_isEdit
                ? AppStrings.rssSourceEditTitle
                : AppStrings.rssSourceNewTitle),
            bottom: TabBar(
              // 全局 tabBarTheme 设了 TabAlignment.start，必须 isScrollable
              // 否则触发断言崩溃（对齐书源编辑页）
              isScrollable: true,
              tabs: [
                Tab(text: AppStrings.rssSourceTabBasic),
                Tab(text: AppStrings.rssSourceTabPreprocess),
                Tab(text: AppStrings.rssSourceTabListRules),
                const Tab(text: 'WEB_VIEW'),
              ],
            ),
            actions: [
              // 测试（快速验证源 URL 可用性）
              IconButton(
                tooltip: AppStrings.testAction,
                icon: _testing
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Symbols.science_rounded),
                onPressed: _testing ? null : _test,
              ),
              // 溢出菜单（对标原版 source_edit.xml 精简版）
              PopupMenuButton<String>(
                tooltip: AppStrings.rssMoreOptions,
                position: PopupMenuPosition.under,
                onSelected: _handleMenu,
                itemBuilder: (_) => [
                  PopupMenuItem(
                    value: 'debug',
                    child: Text(AppStrings.sourceDebug),
                  ),
                  PopupMenuItem(
                    value: 'copy',
                    child: Text(AppStrings.rssSourceCopy),
                  ),
                  PopupMenuItem(
                    value: 'paste',
                    child: Text(AppStrings.sourcePaste),
                  ),
                  PopupMenuItem(
                    value: 'clear_cookie',
                    child: Text(AppStrings.sourceClearCookie),
                  ),
                  PopupMenuItem(
                    value: 'code_edit',
                    child: Text(AppStrings.sourceCodeEdit),
                  ),
                  PopupMenuItem(
                    value: 'share',
                    child: Text(AppStrings.rssSourceShareText),
                  ),
                  PopupMenuItem(
                    value: 'help',
                    child: Text(AppStrings.helpLabel),
                  ),
                ],
              ),
              // 保存（对标原版 menu_save）
              FilledButton(
                onPressed: _saving ? null : _save,
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                ),
                child: _saving
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Text(AppStrings.save),
              ),
              const SizedBox(width: 8),
            ],
          ),
          body: Column(
            children: [
              // 可折叠选项面板（对标原版选项区：4 开关 + 类型 + 样式）
              _buildOptionPanel(),
              Expanded(
                child: TabBarView(
                  children: [
                    _buildFieldList(_baseFields, withTestResult: true),
                    _buildFieldList(_preFields),
                    _buildFieldList(_listFields),
                    _buildWebViewTab(),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 选项面板（对标原版 cb_is_enable/cb_single_url/cb_is_enable_cookie/
  /// cb_is_enable_preload + sp_type + ly_type）
  Widget _buildOptionPanel() {
    final colorScheme = Theme.of(context).colorScheme;
    return ExpansionTile(
      initiallyExpanded: true,
      tilePadding: const EdgeInsets.symmetric(horizontal: 16),
      shape: const Border(),
      collapsedShape: const Border(),
      title: Text(AppStrings.rssSourceOptions,
          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Wrap(
            children: [
              _checkChip(AppStrings.sourceEnabledLabel, _enabled,
                  (v) => _enabled = v),
              _checkChip(AppStrings.rssSourceSingleUrl, _singleUrl,
                  (v) => _singleUrl = v),
              _checkChip('Cookie', _cookieJar, (v) => _cookieJar = v),
              _checkChip(AppStrings.rssSourcePreload, _preload,
                  (v) => _preload = v),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          // 窄屏（360dp）英文文案下两组「标签 + 下拉」并排会右溢，改 Wrap
          // 换行（组内仍同行，宽屏视觉不变）。
          child: Wrap(
            spacing: 24,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(AppStrings.rssSourceTypeLabel,
                      style: TextStyle(color: colorScheme.onSurface)),
                  const SizedBox(width: 8),
                  DropdownButton<int>(
                    value: _type,
                    isDense: true,
                    onChanged: (v) => setState(() => _type = v ?? 0),
                    items: [
                      for (var i = 0; i < _typeLabels.length; i++)
                        DropdownMenuItem(
                            value: i, child: Text(_typeLabels[i])),
                    ],
                  ),
                ],
              ),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(AppStrings.rssFieldStyle,
                      style: TextStyle(color: colorScheme.onSurface)),
                  const SizedBox(width: 8),
                  DropdownButton<int>(
                    value: _articleStyle,
                    isDense: true,
                    onChanged: (v) => setState(() => _articleStyle = v ?? 0),
                    items: [
                      for (var i = 0; i < _styleLabels.length; i++)
                        DropdownMenuItem(
                            value: i, child: Text(_styleLabels[i])),
                    ],
                  ),
                ],
              ),
            ],
          ),
        ),
        const Divider(height: 1),
      ],
    );
  }

  Widget _checkChip(String label, bool value, ValueChanged<bool> onChanged) {
    return SizedBox(
      width: 112,
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

  Widget _buildFieldList(List<_FieldSpec> fields, {bool withTestResult = false}) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        for (final spec in fields) _field(spec),
        if (withTestResult && (_testResult != null || _testError != null)) ...[
          const SizedBox(height: 8),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: _testError != null
                  ? Theme.of(context).colorScheme.errorContainer
                  : Theme.of(context).colorScheme.primaryContainer,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              _testError ?? _testResult!,
              style: TextStyle(
                fontSize: 13,
                color: _testError != null
                    ? Theme.of(context).colorScheme.onErrorContainer
                    : Theme.of(context).colorScheme.onPrimaryContainer,
              ),
            ),
          ),
        ],
        const SizedBox(height: 24),
      ],
    );
  }

  Widget _field(_FieldSpec spec) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextField(
        controller: _ctrls[spec.key],
        focusNode: _focusNodeFor(spec.key),
        maxLines: spec.maxLines,
        decoration: InputDecoration(
          labelText: spec.label,
          hintText: spec.hint.isEmpty ? null : spec.hint,
          border: const OutlineInputBorder(),
          isDense: true,
          suffixIcon: spec.maxLines >= 2
              ? IconButton(
                  tooltip: AppStrings.sourceCodeEdit,
                  icon: const Icon(Symbols.code_rounded, size: 20),
                  onPressed: () => _openCodeEdit(spec.key, spec.label),
                )
              : null,
        ),
      ),
    );
  }

  /// WEB_VIEW Tab：4 开关 + 6 文本字段（对标原版 WEB_VIEW 页 10 项）
  Widget _buildWebViewTab() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        CheckboxListTile(
          dense: true,
          controlAffinity: ListTileControlAffinity.leading,
          contentPadding: EdgeInsets.zero,
          title: Text(AppStrings.rssSourceEnableJs),
          value: _enableJs,
          onChanged: (v) => setState(() => _enableJs = v ?? true),
        ),
        CheckboxListTile(
          dense: true,
          controlAffinity: ListTileControlAffinity.leading,
          contentPadding: EdgeInsets.zero,
          title: Text(AppStrings.rssSourceLoadWithBaseUrl),
          value: _loadWithBaseUrl,
          onChanged: (v) => setState(() => _loadWithBaseUrl = v ?? true),
        ),
        CheckboxListTile(
          dense: true,
          controlAffinity: ListTileControlAffinity.leading,
          contentPadding: EdgeInsets.zero,
          title: Text(AppStrings.rssSourceShowWebLog),
          value: _showWebLog,
          onChanged: (v) => setState(() => _showWebLog = v ?? false),
        ),
        CheckboxListTile(
          dense: true,
          controlAffinity: ListTileControlAffinity.leading,
          contentPadding: EdgeInsets.zero,
          title: Text(AppStrings.rssSourceCacheFirst),
          value: _cacheFirst,
          onChanged: (v) => setState(() => _cacheFirst = v ?? false),
        ),
        const SizedBox(height: 8),
        for (final spec in _webFields) _field(spec),
        const SizedBox(height: 24),
      ],
    );
  }
}
