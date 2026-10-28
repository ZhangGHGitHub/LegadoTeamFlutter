import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import '../widgets/app_scaffold.dart';
import '../widgets/legado_app_bar.dart';
import '../widgets/md3_fast_scroller.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' hide Provider, ChangeNotifierProvider;

import '../l10n/app_strings.dart';
import '../models/models.dart';
import '../providers/providers.dart';
import '../providers/reader/reader_notifier.dart';
import '../services/search_content_options.dart';
import '../services/settings_service.dart';
import '../widgets/app_progress_indicator.dart';
import '../widgets/empty_state.dart';
import '../widgets/pill_divider.dart';

/// 单条正文搜索结果
class _ContentMatch {
  final int chapterIndex;
  final String chapterTitle;
  final String snippet;

  const _ContentMatch({
    required this.chapterIndex,
    required this.chapterTitle,
    required this.snippet,
  });
}

/// 正文搜索三档范围取值别名（默认 = 仅本书已缓存，对齐原版/参考版口径）
///
/// 具体选项读写见 `services/search_content_options.dart`（批33 持久化）。
const _scopeCurrent = SettingsService.searchScopeCurrent;
const _scopeCached = SettingsService.searchScopeCached;
const _scopeNetwork = SettingsService.searchScopeNetwork;

/// 在正文中定位命中区间（搜索与高亮共用，纯函数便于单测）
///
/// 对齐原版 `SearchContentViewModel.searchPosition`：
/// - 正则模式：`Regex(pattern).findAll` 取每处匹配区间，非法表达式返回空列表；
/// - 普通模式：大小写不敏感的子串查找（逐处不重叠）。
/// [maxHits] 限制单段正文的命中数，防止宽泛正则在单章内炸出上万条。
List<({int start, int end})> findContentHits(
  String content,
  String query, {
  required bool useRegex,
  int maxHits = 50,
}) {
  final hits = <({int start, int end})>[];
  if (query.isEmpty) return hits;
  if (useRegex) {
    try {
      for (final m in RegExp(query).allMatches(content)) {
        hits.add((start: m.start, end: m.end));
        if (hits.length >= maxHits) break;
      }
    } catch (_) {
      return hits;
    }
    return hits;
  }
  final lower = content.toLowerCase();
  final lowerQuery = query.toLowerCase();
  var from = 0;
  var found = lower.indexOf(lowerQuery, from);
  while (found != -1) {
    hits.add((start: found, end: found + query.length));
    if (hits.length >= maxHits) break;
    from = found + query.length;
    found = lower.indexOf(lowerQuery, from);
  }
  return hits;
}

/// 正文搜索页面
///
/// 在指定书籍的全部章节正文中搜索关键词，支持高亮、搜索历史，
/// 点击结果可跳转阅读器对应章节。
class SearchContentScreen extends ConsumerStatefulWidget {
  /// 书籍对象（路由参数规范化：优先使用 Book 对象）
  final Book? book;

  /// 书籍 URL（向后兼容）
  final String bookUrl;

  /// 书名（向后兼容）
  final String bookName;

  // [UI-fix v2.0.2 | 2026-08-06] 初始查询词（阅读器长按选中文本传入，
  // 对标原版 searchContentQuery 预填 + 自动搜索） — Qoder
  final String? initialQuery;

  /// 搜索选项实例（测试注入用；省略时页面自建）
  ///
  /// 无论是否注入，页面 initState 都会调用 [SearchContentOptions.load]
  /// 从持久化刷新，保证 SharedPreferences 为最终口径。
  final SearchContentOptions? options;

  const SearchContentScreen({
    super.key,
    this.book,
    this.bookUrl = '',
    this.bookName = '',
    this.initialQuery,
    this.options,
  });

  /// 获取有效的 bookUrl
  String get effectiveBookUrl => book?.bookUrl ?? bookUrl;

  /// 获取有效的书名
  String get effectiveBookName => book?.name ?? bookName;

  @override
  ConsumerState<SearchContentScreen> createState() => _SearchContentScreenState();
}

class _SearchContentScreenState extends ConsumerState<SearchContentScreen> {
  // [UI_SYNC_REFACTOR R3] 快速滚动条控制器
  final ScrollController _fsController = ScrollController();
  final TextEditingController _controller = TextEditingController();

  List<_ContentMatch> _results = [];
  List<String> _history = [];
  bool _searching = false;
  String _query = '';
  int _scannedChapters = 0;
  int _totalChapters = 0;

  /// 搜索代号，用于丢弃过期搜索
  int _generation = 0;

  /// 搜索选项（批33 持久化：范围默认「仅本书（已缓存）」+ 替换/正则）
  late final SearchContentOptions _options;

  /// 选项加载完成信号：初始查询词须等持久化值就位后再发起搜索
  late final Future<void> _optionsReady;

  static const _maxResults = 200;

  /// 单章命中上限（防正则宽泛匹配在单章内炸出上万条）
  static const _maxInChapter = 50;
  static const _snippetRadius = 30;

  @override
  void initState() {
    super.initState();
    _options = widget.options ?? SearchContentOptions();
    _optionsReady = _options.load();
    _loadHistory();
    // 初始查询词：预填输入框并在首帧后自动触发搜索
    //（先等选项加载完成，避免用默认范围搜完后立刻被持久化值改写）
    final q = widget.initialQuery;
    if (q != null && q.trim().isNotEmpty) {
      _controller.text = q;
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        await _optionsReady;
        if (mounted) unawaited(_search(q));
      });
    }
  }

  @override
  void dispose() {
    _generation++; // 使所有进行中的搜索失效
    _controller.dispose();
    super.dispose();
  }

  Future<void> _loadHistory() async {
    try {
      final api = ref.read(bookApiProvider);
      final list = await api.getSearchHistory(limit: 20);
      if (!mounted) return;
      setState(() => _history = list.map((e) => e.word).toList());
    } catch (_) {
      // 历史加载失败不影响搜索
    }
  }

  Future<void> _search(String raw) async {
    final query = raw.trim();
    if (query.isEmpty) return;
    // [批33] 搜索前确保持久化选项已就位（手输/点击搜索可能早于异步加载）
    await _optionsReady;
    if (!mounted) return;

    final api = ref.read(bookApiProvider);
    final gen = ++_generation;

    setState(() {
      _query = query;
      _searching = true;
      _results = [];
      _scannedChapters = 0;
      _totalChapters = 0;
    });
    // [LAYOUT_PLAN P1] 提交藏键盘（SearchBar 无 focusNode，走 scope）
    FocusScope.of(context).unfocus();

    // 记录搜索历史
    api.addSearchKeyword(query, widget.effectiveBookName).catchError((_) {});

    try {
      final chapters = await api.getChapters(widget.effectiveBookUrl);
      if (gen != _generation || !mounted) return;
      setState(() => _totalChapters = chapters.length);

      // 正则模式：非法表达式按原版语义静默返回空结果（原版 try/catch 后直接返回）
      if (_options.useRegex) {
        var valid = true;
        try {
          RegExp(query);
        } catch (_) {
          valid = false;
        }
        if (!valid) {
          if (gen == _generation && mounted) {
            setState(() => _searching = false);
          }
          return;
        }
      }
      // 搜索范围准备：仅当前章 → 取阅读器当前章索引；
      // 本书已缓存 → 取该书的已缓存章节 URL 集合（cacheListCachedChapterUrls）
      final scope = _options.scope;
      final currentIndex = ref.read(readerNotifierProvider).currentChapterIndex;
      Set<String>? cachedUrls;
      if (scope == _scopeCached) {
        try {
          cachedUrls = (await api.listCachedChapterUrls(widget.effectiveBookUrl))
              .toSet();
        } catch (_) {
          cachedUrls = <String>{};
        }
      }
      if (gen != _generation || !mounted) return;

      for (var i = 0; i < chapters.length; i++) {
        if (gen != _generation) return; // 已被新搜索/退出取消
        final chapter = chapters[i];
        // 范围过滤（对齐重构版 search_content_page 的 i != durChapterIndex
        // continue / 已缓存判定语义）
        if (scope == _scopeCurrent && i != currentIndex) {
          continue;
        }
        if (scope == _scopeCached &&
            i != currentIndex &&
            !(cachedUrls?.contains(chapter.url) ?? false)) {
          continue;
        }
        try {
          // [C4 对齐 | Qoder UI] 正文口径随「替换」开关切换（对齐原版
          // ContentProcessor.getContent(useReplace = replaceEnabled)）：
          // 默认关闭替换规则，避免被替换/删除的词搜不到
          final content = _options.useReplace
              ? await api.getChapterContent(
                  widget.effectiveBookUrl, chapter.index)
              : await api.getChapterContentRaw(
                  widget.effectiveBookUrl, chapter.index);
          if (gen != _generation) return;

          final hits = findContentHits(
            content,
            query,
            useRegex: _options.useRegex,
            maxHits: _maxInChapter,
          );

          for (final hit in hits) {
            final start = hit.start > _snippetRadius ? hit.start - _snippetRadius : 0;
            var end = hit.end + _snippetRadius;
            if (end > content.length) end = content.length;
            var snippet = content.substring(start, end).replaceAll('\n', ' ');
            if (start > 0) snippet = '…$snippet';
            if (end < content.length) snippet = '$snippet…';
            _results.add(_ContentMatch(
              chapterIndex: chapter.index,
              chapterTitle: chapter.title,
              snippet: snippet,
            ));
            if (_results.length >= _maxResults) break;
          }
        } catch (_) {
          // 单章获取失败，跳过
        }
        if (gen != _generation || !mounted) return;
        setState(() => _scannedChapters = i + 1);
        if (_results.length >= _maxResults) break;
      }
    } catch (_) {
      // 目录加载失败
    } finally {
      if (gen == _generation && mounted) {
        setState(() => _searching = false);
      }
    }
  }

  void _cancelSearch() {
    _generation++;
    if (mounted) setState(() => _searching = false);
  }

  void _jumpToResult(_ContentMatch match) {
    final container = ProviderScope.containerOf(context);
    container.read(readerNotifierProvider.notifier).goToChapter(match.chapterIndex);
    Navigator.of(context).pop();
  }

  /// 构造带高亮的富文本
  ///
  /// [C4 对齐 | Qoder UI] 正则模式下按同一 RegExp 高亮（对齐原版结果项
  /// isRegex 判定）；非法正则或未命中时退化为纯文本。
  InlineSpan _highlight(String text, String query) {
    if (query.isEmpty) return TextSpan(text: text);
    final highlightStyle = TextStyle(
      color: Theme.of(context).colorScheme.primary,
      fontWeight: FontWeight.bold,
      backgroundColor:
          Theme.of(context).colorScheme.primaryContainer.withValues(alpha: 0.6),
    );
    final spans = <TextSpan>[];

    // 命中区间（与搜索同口径，共用 findContentHits；单段内不设上限以免高亮缺失）
    final ranges = findContentHits(
      text,
      query,
      useRegex: _options.useRegex,
      maxHits: text.length,
    );

    var cursor = 0;
    for (final r in ranges) {
      if (r.start < cursor) continue; // 防御：重叠区间跳过
      if (r.start > cursor) spans.add(TextSpan(text: text.substring(cursor, r.start)));
      spans.add(TextSpan(
        text: text.substring(r.start, r.end),
        style: highlightStyle,
      ));
      cursor = r.end;
    }
    if (cursor < text.length) spans.add(TextSpan(text: text.substring(cursor)));
    return TextSpan(children: spans);
  }

  @override
  Widget build(BuildContext context) {
    // [PARITY A6 | ⑦b 已裁决 2026-09-21] 输入盒填充统一 surfaceContainerLow
    // （裁决依据 docs/parity_shots/ref_dark_20260921/RECAPTURE_20260921.md
    // §3「项三 A6 搜索输入盒」，替代旧「[需设备重采对照]」在途分支）：
    // - 参考版 composeEngine=material 已确认（设备 prefs 持久值 + 外观页
    //   「主题风格」行 = Material Design、非 Miuix）→ SearchBar 填充槽 =
    //   MaterialTheme.colorScheme.surfaceContainerLow（M3 SearchBar 默认槽位，
    //   源码对照 SearchBar.kt:55 默认参数 / :103-108 解析 / :132-138
    //   Surface 落色）；
    // - 透明板深色 sCL = 0x00FFFFFF（全透明、背景透现）有像素证据：白底
    //   盒内 40/40 点 = 255、灰底 54/55 点 = 128（06/07 重采）；标准板
    //   12 板 dark sCL 全部为深色（Lemon #1E1B13 等，
    //   docs/A_GROUP_FINDINGS_20260920.md 12 板表）；
    // - 旧批采到的浅盒 #E8E2D4（= Lemon dark onSurface）曾归因「参考实例
    //   运行 Miuix 引擎的 surfaceContainer 槽」，本批 material 引擎确认 +
    //   sCL 槽像素证据使该归因失效，浅盒不再作为对齐基准；
    // - 故 backgroundColor 统一取 sCL（删掉此前在途的 isDark ? onSurface
    //   分支——该分支在透明板深色渲染不透明白盒 #EDE6FF，与参考「透明板
    //   盒全透明透现」矛盾；标准板深色亦与 12 板 sCL 深色值矛盾）；
    //   深色态盒内 hint / leading 图标改用 onSurface（参考 hint 实测
    //   #EDE6FF = 透明板 dark onSurface 角色；该板 surface = 0x00FFFFFF
    //   全透明不可见，故 hint/图标不可用 surface）；亮色态维持框架默认
    //   （hint 走 onSurfaceVariant 派生、图标 onSurfaceVariant），与参考
    //   亮色行为一致。
    final scheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    // [GLOBALCOMP B4] 页壳统一：AppScaffold（行为等价直通 Scaffold）
    return AppScaffold(
      topBar: LegadoAppBar(
        // [PARITY C1-C1] 标题对齐参考「搜索内容」
        title: Text('搜索内容', style: Theme.of(context).textTheme.titleMedium),
        actions: [
          if (_searching)
            IconButton(icon: const Icon(Symbols.close_rounded), onPressed: _cancelSearch),
          // [C4 对齐 | Qoder UI] 搜索选项菜单（对齐原版 content_search 菜单：
          // 替换 / 正则 两项可勾选，原版为 overflow 菜单 app:showAsAction="never"）
          PopupMenuButton<String>(
            tooltip: '搜索选项',
            onSelected: (v) async {
              // [批33] 先等持久化加载完成，避免用户早于加载的选择被覆盖
              await _optionsReady;
              if (!mounted) return;
              setState(() {
                switch (v) {
                  case 'replace':
                    _options.useReplace = !_options.useReplace;
                  case 'regex':
                    _options.useRegex = !_options.useRegex;
                  case 'scope_current':
                    _options.scope = _scopeCurrent;
                  case 'scope_cached':
                    _options.scope = _scopeCached;
                  case 'scope_network':
                    _options.scope = _scopeNetwork;
                }
              });
              // [批33] 选择即持久化（重进页面/重启应用保持上次选择）
              unawaited(_options.save());
              // 已有结果时立即按新选项重搜（旧搜索经 _generation 作废）
              if (_query.isNotEmpty) unawaited(_search(_query));
            },
            itemBuilder: (_) => [
              CheckedPopupMenuItem(
                value: 'replace',
                checked: _options.useReplace,
                child: const Text('替换'),
              ),
              CheckedPopupMenuItem(
                value: 'regex',
                checked: _options.useRegex,
                child: const Text('正则'),
              ),
              const PillMenuDivider(),
              // [C4 双基准对齐] 搜索范围三档：语义取重构版 SearchContentPrefsPort
              //（仅当前章 / 本书已缓存 / 本书含网络），参考版「仅本书」对应已缓存档
              CheckedPopupMenuItem(
                value: 'scope_current',
                checked: _options.scope == _scopeCurrent,
                child: const Text('仅当前章'),
              ),
              CheckedPopupMenuItem(
                value: 'scope_cached',
                checked: _options.scope == _scopeCached,
                child: const Text('仅本书（已缓存）'),
              ),
              CheckedPopupMenuItem(
                value: 'scope_network',
                checked: _options.scope == _scopeNetwork,
                child: const Text('本书 + 网络'),
              ),
            ],
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(56),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            // [LAYOUT_PLAN P1] 搜索框走 SearchBar 标准（32dp + surfaceContainerLow）
            child: SearchBar(
              controller: _controller,
              // [PARITY C1-C3] hint 对齐参考「搜索...」
              hintText: '搜索...',
              // [PARITY A6 | ⑦b 已裁决] 深色态 hint 用 onSurface（参考 hint
              // 实测 #EDE6FF = 透明板 dark onSurface 角色；旧 surface 色在该
              // 板 = 0x00FFFFFF 全透明不可见）；亮色态保持框架默认
              // （onSurfaceVariant 派生，此处传 null）
              hintStyle: WidgetStatePropertyAll(
                isDark ? TextStyle(color: scheme.onSurface) : null,
              ),
              // 原 TextField autofocus 语义保留：进页自动聚焦
              autoFocus: true,
              constraints: const BoxConstraints(minHeight: 40),
              elevation: const WidgetStatePropertyAll(0),
              // [PARITY A6 | ⑦b 已裁决] 盒填充统一 = surfaceContainerLow
              // （material 引擎 SearchBar 默认槽位：标准板深色为深色盒、
              // 透明板 = 全透明背景透现，见 build 头部裁决注释）
              backgroundColor:
                  WidgetStatePropertyAll(scheme.surfaceContainerLow),
              shape: WidgetStatePropertyAll(
                RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(32),
                ),
              ),
              padding: const WidgetStatePropertyAll(
                EdgeInsets.symmetric(horizontal: 12),
              ),
              leading: Icon(
                Symbols.search_rounded,
                size: 20,
                // [PARITY A6 | ⑦b 已裁决] 深色态图标用 onSurface（同 hint
                // 裁决；透明板 dark = #EDE6FF 与参考一致）；亮色态维持
                // onSurfaceVariant（框架默认，不动）
                color: isDark ? scheme.onSurface : scheme.onSurfaceVariant,
              ),
              trailing: [
                if (_controller.text.isNotEmpty)
                  IconButton(
                    icon: const Icon(Symbols.close_rounded, size: 18),
                    onPressed: () {
                      _controller.clear();
                      setState(() {
                        _query = '';
                        _results = [];
                      });
                    },
                  ),
                if (_searching)
                  IconButton(
                    icon: const Icon(Symbols.close_rounded, size: 18),
                    onPressed: _cancelSearch,
                  ),
              ],
              onChanged: (_) => setState(() {}),
              onSubmitted: _search,
            ),
          ),
        ),
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    // 未搜索时展示搜索历史
    if (_query.isEmpty && !_searching) {
      return _buildHistory();
    }
    if (_searching && _results.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // [STAGE-UI-P43UNIFY2 B3] 裸环换接统一封装（默认参数视觉等价）
            const AppCircularProgressIndicator(),
            const SizedBox(height: 16),
            Text(_totalChapters == 0
                ? AppStrings.searching
                : '扫描章节 $_scannedChapters / $_totalChapters ...'),
          ],
        ),
      );
    }
    if (_results.isEmpty) {
      return EmptyState(
        icon: Symbols.search_off_rounded,
        title: AppStrings.noResults,
        subtitle: '未找到「$_query」相关内容',
      );
    }
    return Column(
      children: [
        if (_searching)
          // [STAGE-UI-P43UNIFY2 B3] 顶栏 indeterminate 条换接统一封装
          //（progress null = indeterminate；确定性 x/y 语义经 progress 承载，
          // 视觉等价：无 minHeight 实参 → 默认 4dp）
          AppLinearProgressIndicator(
            progress: _totalChapters == 0 ? null : _scannedChapters / _totalChapters,
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Row(
            children: [
              Text('共 ${_results.length} 处匹配',
                  style: Theme.of(context).textTheme.labelMedium),
              if (_results.length >= _maxResults)
                Text('（已截断）',
                    style: Theme.of(context).textTheme.labelSmall),
            ],
          ),
        ),
        Expanded(
          // [UI_SYNC_REFACTOR R3] 结果列表快速滚动条
          child: Md3FastScroller(
            controller: _fsController,
            child: ListView.builder(
              controller: _fsController,
              itemCount: _results.length,
              itemBuilder: (context, i) => _buildResultTile(_results[i]),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildResultTile(_ContentMatch match) {
    final theme = Theme.of(context);
    return ListTile(
      // [LAYOUT_PLAN P1] 结果行字级走 M3 Type Scale
      title: Text(
        match.chapterTitle,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.titleSmall?.copyWith(
          fontWeight: FontWeight.w600,
        ),
      ),
      subtitle: Text.rich(
        _highlight(match.snippet, _query),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
      onTap: () => _jumpToResult(match),
    );
  }

  Widget _buildHistory() {
    if (_history.isEmpty) {
      return EmptyState(
        icon: Symbols.history_rounded,
        title: AppStrings.searchHistory,
        subtitle: '输入关键词开始搜索正文',
      );
    }
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Row(
          children: [
            Text(AppStrings.searchHistory,
                style: Theme.of(context).textTheme.titleSmall),
            const Spacer(),
            TextButton(
              onPressed: _clearHistory,
              child: Text(AppStrings.clearHistory),
            ),
            // [PARITY C1-C2] 「清空」居中：两侧 Spacer 均分（参考 13 清空
            // 位于屏中、右侧为「仅本书」胶囊）
            const Spacer(),
            // 「仅本书」胶囊（批33 已与搜索范围解绑，仅作按书搜索历史的
            // 视觉占位；参考 13：72×39dp，右侧 18dp 边距。当前固定描边态
            // 并提示「待后续版本支持」，点击不再切换范围/重搜）
            _buildScopeChip(),
          ],
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final word in _history)
              ActionChip(
                avatar: const Icon(Symbols.history_rounded, size: 16),
                label: Text(word),
                onPressed: () {
                  _controller.text = word;
                  _search(word);
                },
              ),
          ],
        ),
      ],
    );
  }

  /// [PARITY C1-C2] 「仅本书」胶囊（参考 13 量化：72×39dp）
  ///
  /// [批33 | 胶囊解绑] 参考版此胶囊只控制**搜索历史**的按书过滤，不改变
  /// 正文搜索范围；我方此前误把它绑到 scope_cached/scope_network，同一点击
  /// 既改历史意图又改搜索范围（语义串线）。按书搜索历史需要搜索结果带
  /// bookName 维度（现 `getSearchHistory` 仅返回 word/usage/lastUseTime，
  /// 无按书过滤参数），本批先解绑为「仅提示」并保留视觉位；范围统一由
  /// ⋮ 菜单三档控制。按书搜索历史登记为后续项（契约 §2.15 注）。
  Widget _buildScopeChip() {
    // 参考 13 深色实底（(82,96,112)）+ 白字；解绑后不再表达范围选中态，
    // 固定描边态（避免误导用户以为当前范围=仅本书）
    final fill = Color(0xFF526070);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(19),
        onTap: () {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('按书搜索历史待后续版本支持')),
          );
        },
        child: SizedBox(
          width: 72,
          height: 39,
          child: Container(
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: Colors.transparent,
              borderRadius: BorderRadius.circular(19),
              border: Border.all(color: fill, width: 1),
            ),
            child: Text(
              '仅本书',
              style: TextStyle(fontSize: 14, color: fill),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _clearHistory() async {
    try {
      final api = ref.read(bookApiProvider);
      await api.clearSearchHistory();
      if (mounted) setState(() => _history = []);
    } catch (_) {
      // 忽略
    }
  }
}
