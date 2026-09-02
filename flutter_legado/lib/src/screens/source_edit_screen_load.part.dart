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
        source.bookSourceType.clamp(0, _SourceEditScreenState._typeLabels.length - 1);
    setState(() {});
  }
}
