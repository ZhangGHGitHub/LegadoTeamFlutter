// source_edit_screen.dart 的分域 part 文件（体检 §三.16 超长文件拆分，方法原样搬移）。
// extension _SourceEditLoad 承载：书源加载与字段填充。
// 同 library 内可访问 State 私有字段；生命周期（initState/dispose/build）留在主类。
part of 'source_edit_screen.dart';

// ConsumerState.ref 为 protected 成员，extension 分区无法继承其访问域；
// 本文件所有方法均运行于 State 自身（this），受保护访问语义安全。
// ignore_for_file: invalid_use_of_protected_member

extension _SourceEditLoad on _SourceEditScreenState {
  /// 首次打开编辑页自动弹出规则帮助（对标原版 ruleHelpVersionIsLast 标志）
  Future<void> _maybeShowFirstHelp() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getBool(_SourceEditScreenState._ruleHelpShownKey) ?? false) return;
      await prefs.setBool(_SourceEditScreenState._ruleHelpShownKey, true);
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
      BookSource? source = notifier.getSource(widget.sourceUrl!);
      // [P1-2 修复] 回填必须以**权威数据源**为准，内存列表可能是过期副本
      // （导入/备份恢复/发现页旧缓存都会留下旧对象）。设备缺陷：编辑页按过期
      // 副本回填 → 表单里 ruleSearch.name 已无 `@js:` 后缀 → 保存把库内真实
      // 规则覆盖掉 → 搜索报 `source is not defined`。
      // 因此优先现拉一次 `getBookSources()`（同时兜住「内存列表未加载」的
      // 直达入口），内存副本仅在现拉失败/未命中时兜底。
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
        debugPrint('SourceEdit 拉取权威书源失败（沿用内存副本）: $e');
      }
      if (!mounted) return;
      if (source != null) {
        _populateFields(source);
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(AppStrings.sourceNotFoundHint)),
        );
      }
    });
  }

  /// [P1-2 修复] 用权威数据源校正表单回填（仅当用户尚未编辑任何字段）
  ///
  /// 调用方直接传入 [BookSource]（发现页/阅读页入口）时，该对象可能来自
  /// 内存缓存或路由参数，已与库内不一致。规则字段一旦按过期值回填，
  /// 保存就会把库内真实规则（如 `@js:` 后缀）覆盖掉。
  ///
  /// 保守策略：只在用户**完全没动过**表单时校正，避免覆盖正在进行的输入。
  Future<void> _refreshFromAuthoritative(String url) async {
    if (url.isEmpty) return;
    try {
      final api = ref.read(bookApiProvider);
      final sources = await api.getBookSources();
      final fresh = sources.where((s) => s.bookSourceUrl == url).firstOrNull;
      if (!mounted || fresh == null) return;
      if (_hasUserEdits) return;
      // 内容一致时不必重填（避免无谓的 setState/光标跳动）
      final current = _originalSource;
      if (current != null &&
          jsonEncode(fresh.toJson()) == jsonEncode(current.toJson())) {
        return;
      }
      _populateFields(fresh);
      setState(() {});
    } catch (e) {
      debugPrint('SourceEdit 权威书源校正失败（沿用传入对象）: $e');
    }
  }

  void _populateFields(BookSource source) {
    final values = _sourceToValues(source);
    values.forEach((key, value) => _ctrl(key).text = value);
    // 保存原始书源：_buildSource 时透传表单未展示字段（updateTime 等），
    // 避免保存一次编辑即抹掉既有规则数据（「修改后生效且不丢数据」）
    _originalSource = source;
    // [P1-2] 记录回填基准：保存时据此区分「用户清空」与「用户没动过」
    _snapshotInitialValues();
    // 评审 C1：同步记录既有 variable，_buildSource 时透传不抹掉
    _preservedVariable = source.variable;
    _enabled = source.enabled;
    _enabledExplore = source.enabledExplore;
    _reviewEnabled = source.ruleReview?.enabled ?? false;
    _cookieJar = source.enabledCookieJar ?? false;
    _eventListener = source.eventListener;
    _customButton = source.customButton;
    _bookSourceType =
        source.bookSourceType.clamp(0, _SourceEditScreenState._typeLabels.length - 1);
    setState(() {});
  }
}
